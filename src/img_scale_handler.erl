%%
%% Accepts HTTP requests and scales requested images.
%%
-module(img_scale_handler).
-behavior(cowboy_handler).

-export([init/2, content_types_provided/2, content_types_accepted/2,
    acc_multipart/2, handle_post/2, to_scale/2, allowed_methods/2, to_json/2,
    is_authorized/2, forbidden/2, resource_exists/2, previously_existed/2]).

-include("general.hrl").
-include("riak.hrl").
-include("entities.hrl").
-include("media.hrl").

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

content_types_provided(Req, State) ->
    {[
	{{<<"image">>, <<"jpeg">>, '*'}, to_scale},
	{{<<"application">>, <<"json">>, []}, to_json}
    ], Req, State}.

%%
%% Returns callback 'handle_post()'
%% ( called after 'resource_exists()' )
%%
content_types_accepted(Req, State) ->
    {[{{<<"multipart">>, <<"form-data">>, '*'}, handle_post}], Req, State}.

%%
%% Called first
%%
allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>], Req, State}.

to_json(Req0, State) ->
    {<<>>, Req0, State}.


to_scale(Req0, State) ->
    BucketId = proplists:get_value(bucket_id, State),
    ParsedQs = cowboy_req:parse_qs(Req0),
    Prefix = list_handler:validate_prefix(BucketId, proplists:get_value(<<"prefix">>, ParsedQs)),
    ObjectKey0 =
	case proplists:get_value(<<"object_key">>, ParsedQs) of
	    undefined -> {error, 8};
	    ObjectKey1 -> unicode:characters_to_list(ObjectKey1)
	end,
    Width =
	case proplists:get_value(<<"w">>, ParsedQs) of
	    undefined -> ?DEFAULT_IMAGE_WIDTH;
	    W -> try utils:to_number(W) catch error:badarg -> ?DEFAULT_IMAGE_WIDTH end
	end,
    Height =
	case proplists:get_value(<<"h">>, ParsedQs) of
	    undefined -> ?DEFAULT_IMAGE_WIDTH;
	    H -> try utils:to_number(H) catch error:badarg -> ?DEFAULT_IMAGE_WIDTH end
	end,
    %% The following flag can be used to turn off image cropping
    CropFlag =
	case proplists:get_value(<<"crop">>, ParsedQs) of
	    <<"0">> -> false;
	    _ -> true
	end,
    case lists:keyfind(error, 1, [Prefix, ObjectKey0]) of
	{error, Number} -> js_handler:bad_request(Req0, Number);
	false ->
	    PrefixedObjectKey = utils:prefixed_object_key(Prefix, ObjectKey0),
	    T0 = utils:timestamp(),
	    case riak_api:head_object(BucketId, PrefixedObjectKey) of
		{error, Reason} ->
		    lager:error("[img_scale_handler] head_object failed ~p/~p: ~p",
				[BucketId, PrefixedObjectKey, Reason]),
		    {<<>>, Req0, []};
		not_found -> {<<>>, Req0, []};
		Metadata0 ->
		    ObjExt = filename:extension(light_ets:to_lower(ObjectKey0)),
		    IsVideo = lists:member(ObjExt, ?VIDEO_EXTENSIONS),
		    case IsVideo of
			true -> scale_response(Req0, BucketId, Metadata0, Width, Height, CropFlag, true, T0);
			false ->
			    TotalBytes =
				case proplists:get_value("x-amz-meta-bytes", Metadata0) of
				    undefined -> undefined;
				    V -> utils:to_integer(V)
				end,
			    case TotalBytes =:= undefined orelse TotalBytes > ?MAXIMUM_IMAGE_SIZE_BYTES of
				true ->
				    %% In case image object size is bigger than the limit, return empty response.
				    {<<>>, Req0, []};
				false ->
				    scale_response(Req0, BucketId, Metadata0, Width, Height, CropFlag, IsVideo, T0)
			    end
		    end
	    end
    end.

%%
%% Receives stream from httpc and passes it to cowboy
%%
receive_streamed_body(RequestId0, Pid0, BucketId, NextObjectKeys0, Acc) ->
    httpc:stream_next(Pid0),
    receive
	{http, {RequestId0, stream, BinBodyPart}} ->
	    case (byte_size(Acc) + byte_size(BinBodyPart)) >= ?MAXIMUM_IMAGE_SIZE_BYTES of
		true ->
		    httpc:cancel_request(RequestId0),
		    << Acc/binary, BinBodyPart/binary >>;
		false ->
		    receive_streamed_body(RequestId0, Pid0, BucketId, NextObjectKeys0,
					  << Acc/binary, BinBodyPart/binary >>)
	    end;
	{http, {RequestId0, stream_end, _Headers0}} ->
	    case NextObjectKeys0 of
		[] -> Acc;
		[CurrentObjectKey|NextObjectKeys1] ->
		    %% stream next chunk
		    case riak_api:get_object(BucketId, CurrentObjectKey, stream) of
			not_found ->
			    lager:error("[img_scale_handler] part not found: ~p/~p", [BucketId, CurrentObjectKey]),
			    <<>>;
			{ok, RequestId1} ->
			    receive
				{http, {RequestId1, stream_start, _Headers1, Pid1}} ->
				    receive_streamed_body(RequestId1, Pid1, BucketId, NextObjectKeys1, Acc);
				{http, Msg} -> lager:error("[img_scale_handler] stream error: ~p", [Msg])
			    end
		    end
	    end;
	{http, Msg} ->
	    lager:error("[img_scale_handler] cant receive stream body: ~p", [Msg]),
	    <<>>
    end.

%%
%% Download image from object storage to pepare preview
%% Assumption: image cannot be bigger than MAXIMUM_IMAGE_SIZE_BYTES.
%%
get_binary_data(BucketId, Prefix, StartByte, EndByte) ->
    MaxKeys = ?FILE_MAXIMUM_SIZE div ?FILE_UPLOAD_CHUNK_SIZE,
    PartNumStart = (StartByte div ?FILE_UPLOAD_CHUNK_SIZE) + 1,
    PartNumEnd = (EndByte div ?FILE_UPLOAD_CHUNK_SIZE) + 1,
    case riak_api:list_objects(BucketId, [{max_keys, MaxKeys}, {prefix, Prefix ++ "/"}]) of
	not_found -> <<>>;
	RiakResponse0 ->
	    Contents = proplists:get_value(contents, RiakResponse0),
	    %% We take into account 'range' header, by taking all parts from specified one
	    List0 = lists:filtermap(
		fun(K) ->
		    ObjectKey1 = proplists:get_value(key, K),
		    Tokens = lists:last(string:tokens(ObjectKey1, "/")),
		    [N,_] = string:tokens(Tokens, "_"),
		    case utils:to_integer(N) of
			I when I >= PartNumStart, I =< PartNumEnd -> {true, ObjectKey1};
			_ -> false
		    end
		end, Contents),
	    List1 = lists:sort(
		fun(K1, K2) ->
		    T1 = lists:last(string:tokens(K1, "/")),
		    [N1,_] = string:tokens(T1, "_"),
		    T2 = lists:last(string:tokens(K2, "/")),
		    [N2,_] = string:tokens(T2, "_"),
		    utils:to_integer(N1) < utils:to_integer(N2)
		end, List0),
	    case List1 of
		 [] -> <<>>;
		 [PrefixedObjectKey | NextKeys] ->
		    case riak_api:get_object(BucketId, PrefixedObjectKey, stream) of
			not_found -> <<>>;
			{ok, RequestId} ->
			    receive
				{http, {RequestId, stream_start, _Headers, Pid}} ->
				    receive_streamed_body(RequestId, Pid, BucketId, NextKeys, <<>>);
				{http, Msg} ->
				    lager:error("[img_scale_handler] error starting stream: ~p", [Msg]),
				    <<>>
			    end
		    end
	    end
    end.

serve_img(Req0, _BucketId, _Prefix, _CachedKey, _Width, _Height, _CropFlag, <<>>, T0) ->
    T1 = utils:timestamp(),
    Req1 = cowboy_req:stream_reply(200, #{
	<<"elapsed-time">> => io_lib:format("~.2f", [utils:to_float(T1-T0)/1000])
    }, Req0),
    cowboy_req:stream_body(<<>>, fin, Req1),
    {stop, Req1, []};

serve_img(Req0, BucketId, Prefix, CachedKey, Width, Height, CropFlag, BinaryData, T0) ->
    Watermark =
	case riak_api:head_object(BucketId, ?WATERMARK_OBJECT_KEY) of
	    {error, Reason1} ->
		lager:error("[img_scale_handler] head_object failed ~p/~p: ~p",
			    [BucketId, ?WATERMARK_OBJECT_KEY, Reason1]),
		[];
	    not_found -> [];
	    WatermarkResponse ->
		WatermarkGUID = proplists:get_value("x-amz-meta-guid", WatermarkResponse),
		WatermarkUploadId = proplists:get_value("x-amz-meta-upload-id", WatermarkResponse),
		case riak_api:get_object(BucketId, WatermarkGUID, WatermarkUploadId) of
		    not_found -> [];
		    {error, _} -> [];
		    WatermarkBinaryData -> [{watermark, WatermarkBinaryData}]
		end
	end,
    Reply0 = img:scale([
	{from, BinaryData},
	{to, jpeg},
	{crop, CropFlag},
	{scale_width, Width},
	{scale_height, Height}
    ] ++ Watermark),
    case Reply0 of
	{error, Reason2} -> js_handler:bad_request(Req0, Reason2);
	_ ->
	    Options = [{acl, public_read}],
	    Response = riak_api:put_object(BucketId, utils:dirname(Prefix), CachedKey, Reply0, Options),
	    case Response of
		{error, Reason3} ->
		    lager:error("[img_scale_handler] Can't put object ~p/~p/~p: ~p",
				[BucketId, utils:dirname(Prefix), CachedKey, Reason3]);
		_ -> ok
	    end,
	    T1 = utils:timestamp(),
	    Req1 = cowboy_req:stream_reply(200, #{
		<<"elapsed-time">> => io_lib:format("~.2f", [utils:to_float(T1-T0)/1000])
	    }, Req0),
	    cowboy_req:stream_body(Reply0, fin, Req1),
	    {stop, Req1, []}
    end.

%%
%% Returns thumbnail as binary.
%%
%% Cached video thumbnails are stored as
%% ~object/file-GUID/thumbnail
%%
scale_response(Req0, BucketId, Metadata, Width, Height, CropFlag, true, T0) ->
    {RealBucketId, _RealGUID, RealUploadId, RealPrefix0} = utils:real_prefix(BucketId, Metadata),
    CachedKey = RealUploadId ++ "_" ++ erlang:integer_to_list(Width) ++ "x" ++ erlang:integer_to_list(Height),
    PrefixedThumbnail = utils:prefixed_object_key(RealPrefix0, ?RIAK_THUMBNAIL_KEY),
    BinaryData =
	case riak_api:get_object(BucketId, PrefixedThumbnail) of
	    {error, _} -> <<>>;
	    not_found -> <<>>;
	    ThumbnailBinary -> proplists:get_value(content, ThumbnailBinary)
	end,
    serve_img(Req0, RealBucketId, RealPrefix0, CachedKey, Width, Height, CropFlag, BinaryData, T0);

%%
%% Cached images are stored as
%% ~object/file-GUID/upload-GUID_WxH.ext, where W and H are width and height
%%
scale_response(Req0, BucketId, Metadata, Width, Height, CropFlag, false, T0) ->
    {RealBucketId, RealGUID, RealUploadId, RealPrefix0} = utils:real_prefix(BucketId, Metadata),
    PrefixedGUID1 = utils:prefixed_object_key(?RIAK_REAL_OBJECT_PREFIX, RealGUID),
    CachedKey = RealUploadId ++ "_" ++ erlang:integer_to_list(Width) ++ "x" ++ erlang:integer_to_list(Height),
    PrefixedCachedKey = utils:prefixed_object_key(PrefixedGUID1, CachedKey),

    %% First check if cached image exists already.
    case riak_api:get_object(RealBucketId, PrefixedCachedKey) of
	{error, Reason} ->
            %% Miss
	    lager:error("[img_scale_handler] get_object failed ~p/~p: ~p",
			[RealBucketId, PrefixedCachedKey, Reason]),
	    BinaryData0 = get_binary_data(RealBucketId, RealPrefix0, 0, ?MAXIMUM_IMAGE_SIZE_BYTES),
	    serve_img(Req0, RealBucketId, RealPrefix0, CachedKey, Width, Height, CropFlag, BinaryData0, T0);
	not_found ->
            %% Miss
	    BinaryData1 = get_binary_data(RealBucketId, RealPrefix0, 0, ?MAXIMUM_IMAGE_SIZE_BYTES),
	    serve_img(Req0, RealBucketId, RealPrefix0, CachedKey, Width, Height, CropFlag, BinaryData1, T0);
	RiakResponse ->
            %% Return cached image
	    BinaryData = proplists:get_value(content, RiakResponse),
	    T1 = utils:timestamp(),
	    Req1 = cowboy_req:stream_reply(200, #{
		<<"elapsed-time">> => io_lib:format("~.2f", [utils:to_float(T1-T0)/1000])
	    }, Req0),
	    cowboy_req:stream_body(BinaryData, fin, Req1),
	    {stop, Req1, []}
    end.

%%
%% Parse POST fields.
%%
%% md5 -- checksum of thumbnail
%% prefix -- hex-encoded directory name
%% object_key -- the file to attach thumbnail for
%% files[] -- binary blob
%%
acc_multipart(Req0, Acc) ->
    case cowboy_req:read_part(Req0) of
	{ok, Headers0, Req1} ->
	    {ok, Body, Req2} = upload_handler:stream_body(Req1, <<>>),
		Headers1 = maps:to_list(Headers0),
		{_, DispositionBin} = lists:keyfind(<<"content-disposition">>, 1, Headers1),
		{<<"form-data">>, Params} = cow_multipart:parse_content_disposition(DispositionBin),
		FieldName0 =
		    case lists:keyfind(<<"name">>, 1, Params) of
			false -> undefined;
			{_, FN} -> FN
		    end,
		FieldName1 =
		    case FieldName0 of
			<<"md5">> -> md5;        %% chunk md5
			<<"prefix">> -> prefix;
			<<"object_key">> -> object_key;
			<<"files[]">> -> blob;
			<<"width">> -> width;
			<<"height">> -> height;
			_ -> undefined
		    end,
		case FieldName1 of
		    blob ->
			acc_multipart(Req2, [{blob, Body}|Acc]);
		    undefined -> acc_multipart(Req2, Acc);
		    _ -> acc_multipart(Req2, [{FieldName1, Body}|Acc])
		end;
	{done, Req} -> {lists:reverse(Acc), Req}
    end.

%%
%% Validates provided parameters and calls 'upload_to_riak()'
%%
handle_post(Req0, State) ->
    case cowboy_req:method(Req0) of
	<<"POST">> ->
	    {FieldValues, Req1} = acc_multipart(Req0, []),
	    BucketId = proplists:get_value(bucket_id, State),
	    Prefix0 = list_handler:validate_prefix(BucketId, proplists:get_value(prefix, FieldValues)),
	    ObjectKey0 = proplists:get_value(object_key, FieldValues),
	    {Metadata0, ObjectKey1} =
		case ObjectKey0 of
		    undefined -> {error, 9};
		    _ ->
			PrefixedObjectKey = utils:prefixed_object_key(Prefix0, erlang:binary_to_list(ObjectKey0)),
			case riak_api:head_object(BucketId, PrefixedObjectKey) of
			    {error, _} -> {error, 9};
			    not_found -> {error, 9};
			    Metadata1 -> {Metadata1, ObjectKey0}
			end
		end,
	    Blob = proplists:get_value(blob, FieldValues),
	    BlobSize = byte_size(Blob),
	    DataSizeOk =
		case BlobSize > ?MAXIMUM_IMAGE_SIZE_BYTES of
		    true -> {error, 1};
		    _ -> true
		end,
	    Md5 =
		case proplists:get_value(md5, FieldValues) of
		    undefined -> utils:hex(erlang:md5(Blob));
		    RequestMD5 ->
			CalculatedMd5 = erlang:list_to_binary(utils:hex(erlang:md5(Blob))),
			case upload_handler:validate_md5(RequestMD5) of
			    {error, Error} -> {error, Error};
			    CalculatedMd5 -> CalculatedMd5;
			    _ -> {error, 40}
			end
		end,
	    Width0 = upload_handler:validate_integer_field(proplists:get_value(width, FieldValues)),
	    Height0 = upload_handler:validate_integer_field(proplists:get_value(height, FieldValues)),
	    %% Both width and height of image must be specified
	    {Width1, Height1} =
		case lists:all(fun(I) -> I =/= undefined end, [Width0, Height0]) of
		    true -> {Width0, Height0};
		    false -> {undefined, undefined}
		end,
	    case lists:keyfind(error, 1, [Prefix0, ObjectKey1, Md5, DataSizeOk, Width0, Height0]) of
		{error, Number} -> js_handler:bad_request(Req1, Number);
		false ->
		    {RealBucketId, _RealGUID, _RealUploadId, RealPrefix} = utils:real_prefix(BucketId, Metadata0),
		    Meta = [{"width", Width1}, {"height", Height1}, {"md5", Md5}],
		    Options = [{acl, public_read}, {meta, Meta}, {md5, Md5}],
		    case riak_api:put_object(RealBucketId, RealPrefix, ?RIAK_THUMBNAIL_KEY, Blob, Options) of
			ok ->
			    Req2 = cowboy_req:reply(200, #{
				<<"content-type">> => <<"application/json">>
			    }, jsx:encode([{md5, Md5}]), Req0),
			    {stop, Req2, []};
			{error, Reason} ->
			    lager:error("[img_scale_handler] Can't put object ~p/~p/~p: ~p",
					[RealBucketId, RealPrefix, ObjectKey0, Reason]),
			    js_handler:too_many(Req0)
		    end
	    end;
	_ -> js_handler:bad_request(Req0, 2)
    end.


%%
%% Checks if provided token is correct ( Token is optional here ).
%% ( called after 'allowed_methods()' )
%%
is_authorized(Req0, _State) ->
    BucketId =
	case cowboy_req:binding(bucket_id, Req0) of
	    undefined -> undefined;
	    BV -> erlang:binary_to_list(BV)
	end,
    %% Extracts token from request headers and looks it up in "security" bucket
    case utils:get_token(Req0) of
	undefined ->
	    %% Check session id
	    Settings = #general_settings{},
	    SessionCookieName = Settings#general_settings.session_cookie_name,
	    #{SessionCookieName := SessionID0} = cowboy_req:match_cookies([{SessionCookieName, [], undefined}], Req0),
	    case login_handler:check_session_id(SessionID0) of
		false ->
		    case utils:is_public_bucket_id(BucketId) of
			true ->
			    case utils:is_valid_bucket_id(BucketId, undefined) of
				true -> {true, Req0, [{bucket_id, BucketId}]};
				false -> js_handler:unauthorized(Req0, 27)
			    end;
			false -> js_handler:unauthorized(Req0, 28)
		    end;
		{error, Number} -> js_handler:unauthorized(Req0, Number);
		User ->
		    case utils:is_valid_bucket_id(BucketId, User#user.tenant_id) of
			true -> {true, Req0, [{bucket_id, BucketId}, {user, User}]};
			false -> js_handler:unauthorized(Req0, 27)
		    end
	    end;
	Token ->
	    case login_handler:check_token(Token) of
		not_found -> js_handler:unauthorized(Req0, 28);
		expired -> js_handler:unauthorized(Req0, 28);
		User ->
		    case utils:is_valid_bucket_id(BucketId, User#user.tenant_id) of
			true -> {true, Req0, [{bucket_id, BucketId}, {user, User}]};
			false -> js_handler:unauthorized(Req0, 27)
		    end
	    end
    end.

%%
%% Checks if provided token ( or access token ) is valid.
%% ( called after 'allowed_methods()' )
%%
forbidden(Req0, State) ->
    User = proplists:get_value(user, State),
    TenantId =
	case User of
	    undefined -> undefined;
	    _ -> User#user.tenant_id
	end,
    BucketId = proplists:get_value(bucket_id, State),
    IsRestricted = utils:is_restricted_bucket_id(BucketId),
    IsPublic = utils:is_public_bucket_id(BucketId),
    UserBelongsToGroup =
	case User =:= undefined orelse IsRestricted orelse IsPublic of
	    true -> undefined;
	    false -> lists:any(
		fun(Group) -> utils:is_bucket_belongs_to_group(BucketId, TenantId, Group#group.id) end,
		User#user.groups)
	end,
    case UserBelongsToGroup of
	false ->
	    PUser = admin_users_handler:user_to_proplist(User),
	    js_handler:forbidden(Req0, 37, proplists:get_value(groups, PUser), stop);
	_ -> {false, Req0, [{bucket_id, BucketId}, {user, User}]}
    end.

%%
%% Validates request parameters
%% ( called after 'content_types_provided()' )
%%
resource_exists(Req0, State) ->
    {true, Req0, State}.

previously_existed(Req0, _State) ->
    {false, Req0, []}.
