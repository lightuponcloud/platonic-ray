%%
%% Allows downloading objects from Riak CS, after authentication.
%%
-module(download_handler).

-export([init/2, validate_range/2, has_access/5, get_object_metadata/3]).

-include_lib("common_lib/include/log.hrl").
-include_lib("common_lib/include/storage.hrl").
-include_lib("common_lib/include/entities.hrl").
-include_lib("common_lib/include/general.hrl").

%%
%% Check if visitor has the right to download object.
%% If authenticated, check if user has access to provided bucket name, then check if object exists.
%% Returns object's real path.
%%
get_object_metadata(_BucketId, _Prefix, undefined) -> not_found;
get_object_metadata(BucketId, Prefix, ObjectKey) ->
    %% Check if object exist
    PrefixedObjectKey = utils:prefixed_object_key(Prefix, ObjectKey),
    case s3_api:head_object(BucketId, PrefixedObjectKey) of
	not_found -> not_found;
	{error, Reason} ->
	    ?ERROR("[download_handler] head_object ~p/~p: ~p", [BucketId, PrefixedObjectKey, Reason]),
	    not_found;
	Metadata ->
	    case proplists:get_value("x-amz-meta-is-deleted", Metadata) of
		"true" -> not_found;
		_ ->
		    case proplists:get_value("x-amz-meta-guid", Metadata) of
			undefined -> not_found;
			_ ->
			    {OldBucketId, _, _, RealPrefix} = utils:real_prefix(BucketId, Metadata),
			    ContentType = proplists:get_value(content_type, Metadata),
			    Bytes = proplists:get_value("x-amz-meta-bytes", Metadata),
			    Version = proplists:get_value("x-amz-meta-version", Metadata),
			    OrigName0 = erlang:list_to_binary(proplists:get_value("x-amz-meta-orig-filename", Metadata)),
			    OrigName1 = utils:unhex(OrigName0),
			    {OldBucketId, RealPrefix, ContentType, OrigName1, erlang:list_to_binary(Bytes), Version}
		    end
	    end
    end.

%%
%% Checks if client has access to the system.
%%
%% It uses authorization token HTTP header, if provided.
%% Otherwise it checks session cookie.
%%
check_privileges(Req0, BucketId, Prefix, ObjectKey, BucketTenant, PresentedSignature)
	when erlang:is_list(BucketId) andalso erlang:is_list(Prefix) orelse Prefix =:= undefined
	    andalso erlang:is_list(ObjectKey) orelse ObjectKey =:= undefined
	    andalso erlang:is_list(PresentedSignature) orelse PresentedSignature =:= undefined ->
    %% Extracts token from request headers and looks it up in "security" bucket
    case utils:get_token(Req0) of
	undefined ->
	    %% If signature provided, no need to hit DB to check session, therefore this check goes first
	    TenantAPIKey = BucketTenant#tenant.api_key,
	    PrefixedObjectKey = utils:prefixed_object_key(Prefix, ObjectKey),
	    BucketPrefixedObjectKey = utils:prefixed_object_key(BucketId, PrefixedObjectKey),
	    Method = cowboy_req:method(Req0),
	    CalculatedSignature = crypto_utils:calculate_url_signature(Method, BucketPrefixedObjectKey, "", TenantAPIKey),
	    case PresentedSignature == CalculatedSignature of
		true -> true;
		false ->
		    %% Check browser's session cookie value
		    Settings = #general_settings{},
		    SessionCookieName = Settings#general_settings.session_cookie_name,
		    #{SessionCookieName := SessionID0} = cowboy_req:match_cookies([{SessionCookieName, [], undefined}], Req0),
		    case login_handler:check_session_id(SessionID0) of
			{error, Code} -> {config_error, Code};
			false -> {error, 28};
			User ->
			    %% Checks if user has access to bucket
			    UserBelongsToGroup = lists:any(
				fun(Group) ->
				    utils:is_bucket_belongs_to_group(BucketId, User#user.tenant_id, Group#group.id)
				end, User#user.groups),
			    BucketBelongsToUserTenant = utils:is_bucket_belongs_to_tenant(BucketId, User#user.tenant_id),
			UserBelongsToGroup =:= true orelse BucketBelongsToUserTenant =:= true
		    end
	    end;
	Token ->
	    case login_handler:check_token(Token) of
		not_found -> {error, 28};
		expired -> {error, 38};
		User -> User
	    end
    end.

%%
%% Client has access if
%% - bucket looks valid
%% - tenant exists and enabled
%% - Client has API token OR cookie OR signature of object ( that is signed with Tenant's API Key )
%%
has_access(Req0, BucketId, Prefix, ObjectKey, PresentedSignature)
	when erlang:is_list(BucketId) andalso erlang:is_list(Prefix) orelse Prefix =:= undefined andalso
	    erlang:is_list(ObjectKey) orelse ObjectKey =:= undefined andalso
	    erlang:is_list(PresentedSignature) orelse PresentedSignature =:= undefined ->
    case utils:is_valid_bucket_id(BucketId, undefined) of
	false -> {error, 37};
	true ->
	    case utils:is_valid_hex_prefix(Prefix) of
		false -> {error, 36};
		true ->
		    Bits = string:tokens(BucketId, "-"),
		    TenantId = string:to_lower(lists:nth(2, Bits)),
		    case admin_tenants_handler:get_tenant(TenantId) of
			not_found -> {error, 37};
			Tenant ->
			    case check_privileges(Req0, BucketId, Prefix, ObjectKey, Tenant, PresentedSignature) of
				{error, Number} -> {error, Number};
				{config_error, Code} -> {error, Code};
				false -> {error, 37};
				true ->
				    User = ?ANONYMOUS_USER,
				    HexTenantId = utils:hex(erlang:list_to_binary(TenantId)),
				    {BucketId, Prefix, ObjectKey, User#user{tenant_id = TenantId, tenant_name = HexTenantId}};
				User -> {BucketId, Prefix, ObjectKey, User}
			    end
		    end
	    end
    end.

%%
%% Checks if Range request header is valid.
%%
validate_range(undefined, _TotalBytes) -> undefined;
validate_range(Value, TotalBytes) ->
    try cow_http_hd:parse_range(Value) of
	{bytes, [{StartByte, EndByte}]} ->
	    case StartByte =/= undefined andalso EndByte =/= undefined of
		true -> validate_range(StartByte, EndByte, TotalBytes);
		false -> {StartByte, EndByte}
	    end;
	{bytes, _} -> {error, 23}
    catch
	error:_ -> {error, 23}
    end.

validate_range(undefined, _EndByte, _TotalBytes) -> {error, 23};
validate_range(StartByte, undefined, TotalBytes) -> {StartByte, TotalBytes};
validate_range(StartByte, EndByte, _TotalBytes) when StartByte > EndByte -> {error, 23};
validate_range(StartByte, EndByte, _TotalBytes) -> {StartByte, EndByte}.


%%
%% Receives stream from httpc and passes it to cowboy
%%
receive_streamed_body(Req0, RequestId0, Pid0, BucketId, NextObjectKeys0) ->
    httpc:stream_next(Pid0),
    receive
	{http, {RequestId0, stream, BinBodyPart}} ->
	    ok = cowboy_req:stream_body(BinBodyPart, nofin, Req0),
	    receive_streamed_body(Req0, RequestId0, Pid0, BucketId, NextObjectKeys0);
	{http, {RequestId0, stream_end, _Headers0}} ->
	    case NextObjectKeys0 of
		[] -> cowboy_req:stream_body(<<>>, fin, Req0);
		[CurrentObjectKey|NextObjectKeys1] ->
		    %% stream next chunk
		    case s3_api:get_object(BucketId, CurrentObjectKey, stream) of
			not_found ->
			    ?ERROR("[download_handler] error: part not found: ~p/~p", [BucketId, CurrentObjectKey]),
			    cowboy_req:stream_body(<<>>, fin, Req0);
			{ok, RequestId1} ->
			    receive
				{http, {RequestId1, stream_start, _Headers1, Pid1}} ->
				    receive_streamed_body(Req0, RequestId1, Pid1, BucketId, NextObjectKeys1);
				{http, Msg} -> ?ERROR("[download_handler] stream error: ~p", [Msg])
			    end
		    end
	    end;
	{http, Msg} ->
	    ?ERROR("[download_handler] error receiving stream body: ~p", [Msg]),
	    cowboy_req:stream_body(<<>>, fin, Req0)
    end.

%%
%% Lists objects in 'real' prefix ( "~object/" ), sorts them and streams them to client.
%%
stream_chunks(Req0, BucketId, RealPrefix, ContentType, OrigName, Bytes, StartByte, EndByte, OrigBucketId, OrigPrefix, User, T0) ->
    MaxKeys = ?FILE_MAXIMUM_SIZE div ?FILE_UPLOAD_CHUNK_SIZE,
    PartNumStart = (StartByte div ?FILE_UPLOAD_CHUNK_SIZE) + 1,
    PartNumEnd =
	case EndByte of
	    infinity ->
		EB = utils:to_integer(Bytes),
		(EB div ?FILE_UPLOAD_CHUNK_SIZE) + 1;
	    _ -> (EndByte div ?FILE_UPLOAD_CHUNK_SIZE) + 1
	end,
    case s3_api:list_objects(BucketId, [{max_keys, MaxKeys}, {prefix, RealPrefix ++ "/"}]) of
	not_found ->
	    Req1 = cowboy_req:reply(404, #{
		<<"content-type">> => <<"text/html">>
	    }, <<"404: Not found">>, Req0),
	    {ok, Req1, []};
	RiakResponse0 ->
	    Contents = proplists:get_value(contents, RiakResponse0),
	    %% We take into account 'range' header, by taking all parts from specified one
	    List0 = lists:filtermap(
		fun(K) ->
		    ObjectKey = proplists:get_value(key, K),
		    case utils:ends_with(ObjectKey, erlang:list_to_binary(?THUMBNAIL_KEY)) of
			true -> false;
			false ->
			    Tokens = lists:last(string:tokens(ObjectKey, "/")),
			    [N,_] = string:tokens(Tokens, "_"),
			    case utils:to_integer(N) of
				I when I >= PartNumStart, I =< PartNumEnd -> {true, ObjectKey};
				_ -> false
			    end
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
	    T1 = utils:timestamp(),
	    case List1 of
		 [] ->
		    Req2 = cowboy_req:reply(404, #{
			<<"content-type">> => <<"text/html">>,
			<<"elapsed-time">> => io_lib:format("~.2f", [utils:to_float(T1-T0)/1000])
		    }, <<"404: Not found">>, Req0),
		    {ok, Req2, []};
		 [PrefixedObjectKey | NextKeys] ->
		    ContentDisposition = << <<"attachment;filename=\"">>/binary, OrigName/binary, <<"\"">>/binary >>,
		    PartStartByte =
			case PartNumStart of
			    1 -> erlang:integer_to_binary(StartByte);
			    _ -> erlang:integer_to_binary(StartByte rem ?FILE_UPLOAD_CHUNK_SIZE)
			end,
		    Headers0 = #{
			<<"content-type">> => ContentType,
			<<"content-disposition">> => ContentDisposition,
			<<"content-length">> => Bytes,
			<<"range">> => << "bytes=", PartStartByte/binary, "-" >>,
			<<"start-time">> => io_lib:format("~.2f", [utils:to_float(T0)/1000])
		    },
		    Req3 = cowboy_req:stream_reply(200, Headers0, Req0),
		    case s3_api:get_object(BucketId, PrefixedObjectKey, stream) of
			not_found ->
			    Req4 = cowboy_req:reply(404, #{
				<<"content-type">> => <<"text/html">>,
				<<"elapsed-time">> => io_lib:format("~.2f", [utils:to_float(T1-T0)/1000])
			    }, <<"404: Not found">>, Req0),
			    {ok, Req4, []};
			{ok, RequestId} ->
			    receive
				{http, {RequestId, stream_start, _Headers, Pid}} ->
				    receive_streamed_body(Req3, RequestId, Pid, BucketId, NextKeys);
				{http, Msg} -> ?ERROR("[download_handler] error starting stream: ~p", [Msg])
			    end,
			    %% Add log record with time it took to download ZIP
			    ?INFO("[download_handler] download finished in ~p", [
				  io_lib:format("~.2f", [utils:to_float(T1-T0)/1000])]),

			    audit_log:log_operation(
				OrigBucketId,
				OrigPrefix,
				download,
				200,
				[OrigName],
				[{status_code, 200},
				 {request_id, null},
				 {time_to_response, utils:to_float(T1-T0)/1000},
				 {user_id, User#user.id},
				 {user_name, utils:unhex(erlang:list_to_binary(User#user.name))},
				 {actor, user},
				 {environment, null},
				 {compliance_metadata, [{orig_name, OrigName}]}]
			    ),
			    {ok, Req3, []}
		    end
	    end
    end.

response(Req0, <<"HEAD">>, BucketId, Prefix, ObjectKey, _User, T0) ->
    case get_object_metadata(BucketId, Prefix, ObjectKey) of
	not_found ->
	    Req1 = cowboy_req:reply(404, #{
		<<"content-type">> => <<"application/json">>,
		<<"start-time">> => io_lib:format("~.2f", [utils:to_float(T0)/1000])
	    }, Req0),
	    {ok, Req1, []};
	{_OldBucketId, _RealPrefix, ContentType, OrigName, Bytes, Version} ->
	    Req1 = cowboy_req:reply(200, #{
		<<"name">> => OrigName,
		<<"DVV">> => utils:to_binary(Version),
		<<"content-type">> => ContentType,
		<<"size">> => Bytes
	    }, <<>>, Req0),
	    {ok, Req1, []}
    end;

response(Req0, <<"GET">>, BucketId, Prefix, ObjectKey, User, T0) ->
    case get_object_metadata(BucketId, Prefix, ObjectKey) of
	not_found ->
	    Req1 = cowboy_req:reply(404, #{
		<<"content-type">> => <<"application/json">>,
		<<"start-time">> => io_lib:format("~.2f", [utils:to_float(T0)/1000])
	    }, Req0),
	    {ok, Req1, []};
	{OldBucketId, RealPrefix, ContentType, OrigName, Bytes, _Version} ->
	    case validate_range(cowboy_req:header(<<"range">>, Req0), Bytes) of
		undefined ->
		    EndByte = utils:to_integer(Bytes),
		    stream_chunks(Req0, OldBucketId, RealPrefix, ContentType, OrigName, Bytes, 0, EndByte, BucketId, Prefix, User, T0);
		{error, Number} -> js_handler:bad_request(Req0, Number);
		{StartByte, EndByte} ->
		    stream_chunks(Req0, OldBucketId, RealPrefix, ContentType, OrigName, Bytes, StartByte, EndByte, BucketId, Prefix, User, T0)
	    end
    end.


init(Req0, _Opts) ->
    T0 = utils:timestamp(), %% measure time of request
    cowboy_req:cast({set_options, #{idle_timeout => infinity}}, Req0),

    PathInfo = cowboy_req:path_info(Req0),
    BucketId0 =
	case lists:nth(1, PathInfo) of
	    undefined -> undefined;
	    <<>> -> undefined;
	    BV -> erlang:binary_to_list(BV)
	end,
    Prefix0 =
	case length(PathInfo) < 2 of
	    true -> undefined;
	    false ->
		%% prefix should go just after bucket id
		erlang:binary_to_list(utils:join_binary_with_separator(lists:nthtail(1, PathInfo), <<"/">>))
	end,
    ParsedQs = cowboy_req:parse_qs(Req0),
    ObjectKey0 =
	case proplists:get_value(<<"object_key">>, ParsedQs) of
	    undefined -> undefined;
	    null -> undefined;
	    <<>> -> undefined;
	    K -> unicode:characters_to_list(K)
	end,
    PresentedSignature =
	case proplists:get_value(<<"signature">>, ParsedQs) of
	    undefined -> undefined;
	    Signature -> unicode:characters_to_list(Signature)
	end,
    Method = cowboy_req:method(Req0),
    case has_access(Req0, BucketId0, Prefix0, ObjectKey0, PresentedSignature) of
	{error, Number} ->
	    Req1 = cowboy_req:reply(403, #{
		<<"content-type">> => <<"application/json">>,
		<<"start-time">> => io_lib:format("~.2f", [utils:to_float(T0)/1000])
	    }, jsx:encode([{error, Number}]), Req0),
	    {ok, Req1, []};
	{BucketId1, Prefix1, ObjectKey1, User} ->
	    response(Req0, Method, BucketId1, Prefix1, ObjectKey1, User, T0)
    end.
