%%
%% Allows to download objects from Riak CS, after authentication.
%%
-module(download_handler).

-export([init/2, validate_range/2]).

-include("general.hrl").
-include("storage.hrl").
-include("entities.hrl").
-include("log.hrl").

%%
%% Check if visitor has the right to download object.
%% If authenticated, check if user has access to provided bucket name,
%% then check if object exists.
%% Returns object's real path.
%%
validate_request(BucketId, undefined, PrefixedObjectKey) ->
    case utils:is_valid_bucket_id(BucketId, undefined) of
	true ->
	    case s3_api:head_object(BucketId, PrefixedObjectKey) of
		not_found -> not_found;
		{error, Reason} ->
		    lager:error("[download_handler] head_object ~p/~p: ~p",
				[BucketId, PrefixedObjectKey, Reason]),
		    not_found;
		Metadata -> validate_request(BucketId, Metadata)
	    end;
	false -> {error, 37}
    end;
validate_request(BucketId, User, PrefixedObjectKey) ->
    case utils:is_valid_bucket_id(BucketId, User#user.tenant_id) of
	true ->
	    UserBelongsToGroup =
		lists:any(
		    fun(Group) ->
			utils:is_bucket_belongs_to_group(BucketId, User#user.tenant_id, Group#group.id)
		    end, User#user.groups),
	    case UserBelongsToGroup orelse utils:is_bucket_belongs_to_tenant(BucketId, User#user.tenant_id) of
		false -> {error, 37};
		true ->
		    case s3_api:head_object(BucketId, PrefixedObjectKey) of
			{error, Reason} ->
			    lager:error("[download_handler] head_object ~p/~p: ~p",
					[BucketId, PrefixedObjectKey, Reason]),
			    not_found;
			not_found -> not_found;
			Metadata -> validate_request(BucketId, Metadata)
		    end
	    end;
	false -> {error, 7}
    end.
validate_request(BucketId, Metadata0) ->
    case proplists:get_value("x-amz-meta-is-deleted", Metadata0) of
	"true" -> not_found;
	_ ->
	    case proplists:get_value("x-amz-meta-guid", Metadata0) of
		undefined -> not_found;
		_ ->
		    {OldBucketId, _, _, RealPrefix} = utils:real_prefix(BucketId, Metadata0),
		    ContentType = proplists:get_value(content_type, Metadata0),
		    Bytes = proplists:get_value("x-amz-meta-bytes", Metadata0),
		    OrigName0 = erlang:list_to_binary(proplists:get_value("x-amz-meta-orig-filename", Metadata0)),
		    OrigName1 = utils:unhex(OrigName0),
		    {OldBucketId, RealPrefix, ContentType, OrigName1, erlang:list_to_binary(Bytes)}
	    end
    end.

%%
%% Checks if client has access to the system.
%%
%% It uses authorization token HTTP header, if provided.
%% Otherwise it checks session cookie.
%%
check_privileges(Req0) ->
    %% Extracts token from request headers and looks it up in "security" bucket
    case utils:get_token(Req0) of
	undefined ->
	    %% Check browser's session cookie value
	    Settings = #general_settings{},
	    SessionCookieName = Settings#general_settings.session_cookie_name,
	    #{SessionCookieName := SessionID0} = cowboy_req:match_cookies([{SessionCookieName, [], undefined}], Req0),
	    case login_handler:check_session_id(SessionID0) of
		false -> {error, 28};
		{error, Code} -> {config_error, Code};
		User -> User
	    end;
	Token ->
	    case login_handler:check_token(Token) of
		not_found -> {error, 28};
		expired -> {error, 38};
		User -> User
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
	    cowboy_req:stream_body(BinBodyPart, nofin, Req0),
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
stream_chunks(Req0, BucketId, RealPrefix, ContentType, OrigName, Bytes, StartByte, EndByte) ->
    MaxKeys = ?FILE_MAXIMUM_SIZE div ?FILE_UPLOAD_CHUNK_SIZE,
    PartNumStart = (StartByte div ?FILE_UPLOAD_CHUNK_SIZE) + 1,
    PartNumEnd =
	case EndByte of
	    infinity ->
		EB = utils:to_integer(Bytes),
		(EB div ?FILE_UPLOAD_CHUNK_SIZE) + 1;
	    _ -> (EndByte div ?FILE_UPLOAD_CHUNK_SIZE) + 1
	end,
    T0 = utils:timestamp(), %% measure time of request
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
	    case List1 of
		 [] ->
		    Req2 = cowboy_req:reply(404, #{
			<<"content-type">> => <<"text/html">>
		    }, <<"404: Not found">>, Req0),
		    {ok, Req2, []};
		 [PrefixedObjectKey | NextKeys] ->
		    ContentDisposition = << <<"attachment;filename=\"">>/binary, OrigName/binary, <<"\"">>/binary >>,
		    PartStartByte =
			case PartNumStart of
			    1 -> erlang:integer_to_binary(StartByte);
			    _ -> erlang:integer_to_binary(StartByte rem ?FILE_UPLOAD_CHUNK_SIZE)
			end,
		    T1 = utils:timestamp(),
		    Headers0 = #{
			<<"content-type">> => ContentType,
			<<"content-disposition">> => ContentDisposition,
			<<"content-length">> => Bytes,
			<<"range">> => << "bytes=", PartStartByte/binary, "-" >>,
			<<"elapsed-time">> => io_lib:format("~.2f", [utils:to_float(T1-T0)/1000])
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
			    {ok, Req3, []}
		    end
	    end
    end.


init(Req0, _Opts) ->
    T0 = utils:timestamp(), %% measure time of request
    cowboy_req:cast({set_options, #{idle_timeout => infinity}}, Req0),
    PathInfo = cowboy_req:path_info(Req0),
    BucketId =
	case lists:nth(1, PathInfo) of
	    undefined -> undefined;
	    <<>> -> undefined;
	    BV -> erlang:binary_to_list(BV)
	end,
    case check_privileges(Req0) of
	{error, Number} ->
	    T1 = utils:timestamp(),
	    Req1 = cowboy_req:reply(403, #{
		<<"content-type">> => <<"application/json">>,
		<<"elapsed-time">> => io_lib:format("~.2f", [utils:to_float(T1-T0)/1000])
	    }, jsx:encode([{error, Number}]), Req0),
	    {ok, Req1, []};
	{config_error, Code} ->
	    T1 = utils:timestamp(),
	    Req1 = cowboy_req:reply(500, #{
		<<"content-type">> => <<"application/json">>,
		<<"elapsed-time">> => io_lib:format("~.2f", [utils:to_float(T1-T0)/1000])
	    }, jsx:encode([{error, erlang:list_to_binary(Code)}]), Req0),
	    {ok, Req1, []};
	User ->
	    Path0 = lists:nthtail(1, PathInfo),
	    Path1 = erlang:list_to_binary(utils:join_list_with_separator(Path0, <<"/">>, [])),
	    PrefixedObjectKey = erlang:binary_to_list(Path1),
	    case validate_request(BucketId, User, PrefixedObjectKey) of
		not_found ->
		    T1 = utils:timestamp(),
		    Req1 = cowboy_req:reply(404, #{
			<<"content-type">> => <<"application/json">>,
			<<"elapsed-time">> => io_lib:format("~.2f", [utils:to_float(T1-T0)/1000])
		    }, Req0),
		    {ok, Req1, []};
		{error, Number} ->
		    T1 = utils:timestamp(),
		    Req1 = cowboy_req:reply(400, #{
			<<"content-type">> => <<"application/json">>,
			<<"elapsed-time">> => io_lib:format("~.2f", [utils:to_float(T1-T0)/1000])
		    }, jsx:encode([{error, Number}]), Req0),
		    {ok, Req1, []};
		{OldBucketId, RealPrefix, ContentType, OrigName, Bytes} ->
		    case validate_range(cowboy_req:header(<<"range">>, Req0), Bytes) of
			undefined ->
			    EndByte = utils:to_integer(Bytes),
			    stream_chunks(Req0, OldBucketId, RealPrefix, ContentType, OrigName, Bytes, 0, EndByte);
			{error, Number} -> js_handler:bad_request(Req0, Number);
			{StartByte, EndByte} ->
			    stream_chunks(Req0, OldBucketId, RealPrefix, ContentType, OrigName, Bytes, StartByte, EndByte)
		    end
	    end
    end.
