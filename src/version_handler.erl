%%
%% Version handler
%%
%% HEAD application/json
%%	Returns info on provided bucket DVV ( Dotted version Vector ) in JSON format.
%%
%% GET application/octet-stream
%%	Allows to download SQLite DB, used for synchronization.
%%
%% POST
%%	Allows to restore previous version of file.
%%
-module(version_handler).
-behavior(cowboy_handler).

-export([init/2, receive_streamed_body/3]).

-include("storage.hrl").
-include("entities.hrl").
-include("general.hrl").
-include("log.hrl").


%%
%% Receives stream from httpc and passes it to cowboy
%%
receive_streamed_body(Req0, RequestId0, Pid0) ->
    httpc:stream_next(Pid0),
    receive
	{http, {RequestId0, stream, BinBodyPart}} ->
	    cowboy_req:stream_body(BinBodyPart, nofin, Req0),
	    receive_streamed_body(Req0, RequestId0, Pid0);
	{http, {RequestId0, stream_end, _Headers0}} ->
	    cowboy_req:stream_body(<<>>, fin, Req0);
	{http, Msg} ->
	    ?ERROR("[version_handler] error receiving stream body: ~p", [Msg]),
	    cowboy_req:stream_body(<<>>, fin, Req0)
    end.


%%
%% Downloads .luc SQLite DB from S3 and returns it to client.
%%
stream_db(Req0, BucketId0, Bytes, StartByte0) ->
    BucketId1 = utils:to_binary(BucketId0),
    OrigName = << BucketId1/binary, <<".luc">>/binary>>,
    ContentDisposition = << <<"attachment;filename=\"">>/binary, OrigName/binary, <<"\"">>/binary >>,
    StartByte1 = erlang:integer_to_binary(StartByte0),
    Headers0 = #{
	<<"content-type">> => << "application/octet-stream" >>,
	<<"content-disposition">> => ContentDisposition,
	<<"content-length">> => erlang:integer_to_binary(Bytes),
	<<"range">> => << "bytes=", StartByte1/binary, "-" >>
    },
    Req1 = cowboy_req:stream_reply(200, Headers0, Req0),
    case s3_api:get_object(BucketId0, ?DB_VERSION_KEY, stream) of
	not_found ->
	    %% The bucket could have disappeared between checks (unlikely)
	    Req2 = cowboy_req:set_resp_body(<<>>, Req1),
	    {ok, Req2, []};
	{ok, RequestId} ->
	    receive
	    {http, {RequestId, stream_start, _Headers, Pid}} ->
		receive_streamed_body(Req1, RequestId, Pid);
		{http, Msg} -> ?ERROR("[version_handler] error starting stream: ~p", [Msg])
	    end,
	    {ok, Req1, []}
    end.


%%
%% Return empty new DB
%%
first_version(Req0, UserId) ->
    Timestamp = erlang:round(utils:timestamp()/1000),
    Version0 = indexing:increment_version(undefined, Timestamp, UserId),
    Version1 = base64:encode(jsx:encode(Version0)),
    Req1 = cowboy_req:reply(200, #{
	<<"DVV">> => Version1,
	<<"content-type">> => <<"application/json">>
    }, <<>>, Req0),
    {ok, Req1, []}.


init(Req0, _Opts) ->
    cowboy_req:cast({set_options, #{idle_timeout => infinity}}, Req0),
    T0 = erlang:round(utils:timestamp()/1000),
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
    Method = cowboy_req:method(Req0),
    case utils:get_token(Req0) of
	undefined -> js_handler:unauthorized(Req0, 28, stop);
	Token ->
	    case login_handler:check_token(Token) of
		not_found -> js_handler:unauthorized(Req0, 28);
		expired -> js_handler:unauthorized(Req0, 28);
		User ->
		    case cowboy_req:method(Req0) of
			<<"POST">> ->
			    {ok, Body, Req1} = cowboy_req:read_body(Req0),
			    case validate_post(Body, BucketId0, Prefix0) of
				{error, Number} -> js_handler:bad_request(Req1, Number);
				{Prefix1, ObjectKey, Version, Meta} ->
				    response(Req1, <<"POST">>, BucketId0, Prefix1, ObjectKey, User, Meta, Version, T0)
			    end;
			Method -> response(Req0, Method, BucketId0, User, T0)
		    end
	    end
    end.


%% HEAD HTTP request returns DVV in JSON format
response(Req0, <<"HEAD">>, BucketId, User, T0) ->
    case s3_api:head_object(BucketId, ?DB_VERSION_KEY) of
	{error, Reason} ->
	    lager:error("[version_handler] head_object failed ~p/~p: ~p", [BucketId, ?DB_VERSION_KEY, Reason]),
	    first_version(Req0, User#user.id);
	not_found -> first_version(Req0, User#user.id);
	Meta ->
	    DbMeta = object_handler:parse_object_record(Meta, []),
	    Version = proplists:get_value("version", DbMeta),
	    T1 = erlang:round(utils:timestamp()/1000),
	    Req1 = cowboy_req:reply(200, #{
		<<"md5">> => proplists:get_value("md5", DbMeta),
		<<"DVV">> => utils:to_binary(Version),
		<<"content-type">> => <<"application/json">>,
		<<"elapsed-time">> => io_lib:format("~.2f", [utils:to_float(T1-T0)/1000])
	    }, <<>>, Req0),
	    {ok, Req1, []}
    end;

%% GET request returns SQLite DB itself.
response(Req0, <<"GET">>, BucketId, _User, _T0) ->
    case s3_api:head_object(BucketId, ?DB_VERSION_KEY) of
	{error, Reason} ->
	    lager:error("[version_handler] get_object failed ~p/~p: ~p", [BucketId, ?DB_VERSION_KEY, Reason]),
	    Req1 = cowboy_req:set_resp_body(<<>>, Req0),
	    {ok, Req1, []};
	not_found ->
	    Req1 = cowboy_req:set_resp_body(<<>>, Req0),
	    {ok, Req1, []};
	Meta ->
	    Bytes =
		case proplists:get_value("x-amz-meta-bytes", Meta) of
		    undefined -> 0;  %% It might be undefined in case of corrupted metadata
		    B -> utils:to_integer(B)
		end,
	    case download_handler:validate_range(cowboy_req:header(<<"range">>, Req0), Bytes) of
		undefined -> stream_db(Req0, BucketId, Bytes, 0);
		{error, Number} -> js_handler:bad_request_ok(Req0, Number);
		{StartByte, _EndByte} -> stream_db(Req0, BucketId, Bytes, StartByte)
	    end
    end;

response(Req0, _Method, _BucketId, _User, _T0) ->
    js_handler:bad_request_ok(Req0, 17).

%% Restore previous version of file
response(Req0, <<"POST">>, BucketId, Prefix, ObjectKey, User, Meta, Version, T0) ->
    case s3_api:put_object(BucketId, Prefix, ObjectKey, <<>>, [{meta, Meta}]) of
	ok ->
	    %% Update pseudo-directory index for faster listing.
	    case indexing:update(BucketId, Prefix, [{modified_keys, [ObjectKey]}]) of
		lock ->
		    lager:warning("[version_handler] Can't update index: lock exists"),
		    js_handler:too_many(Req0);
		_ ->
		    OrigName = utils:unhex(erlang:list_to_binary(proplists:get_value("orig-filename", Meta))),
		    [VVTimestamp] = dvvset:values(Version),
		    PrevDate = utils:format_timestamp(utils:to_integer(VVTimestamp)),
		    T1 = erlang:round(utils:timestamp()/1000),
		    Summary = <<"Restored \"", OrigName/binary, "\" to version from ", (utils:to_binary(PrevDate))/binary >>,
		    audit_log:log_operation(
			BucketId,
			Prefix,
			restored,
			200,
			[utils:to_binary(ObjectKey)],
			[{status_code, 200},
			 {request_id, null},
			 {time_to_response_ns, utils:to_float(T1-T0)/1000},
			 {user_id, User#user.id},
			 {actor, user},
			 {environment, null},
			 {compliance_metadata, [{orig_name, OrigName}, {summary, Summary}]}]
		    ),
		    T1 = erlang:round(utils:timestamp()/1000),
		    Req1 = cowboy_req:reply(200, #{
			<<"content-type">> => <<"application/json">>,
			<<"elapsed-time">> => io_lib:format("~.2f", [utils:to_float(T1-T0)/1000])
		    }, <<>>, Req0),
		    {ok, Req1, []}
	    end;
	{error, Reason} ->
	    lager:error("[version_handler] Can't put object ~p/~p/~p: ~p",
			[BucketId, Prefix, ObjectKey, Reason]),
	    lager:warning("[version_handler] Can't update index: ~p", [Reason]),
	    js_handler:too_many(Req0)
    end.

validate_post(Body, BucketId, Prefix) ->
    case jsx:is_json(Body) of
	{error, badarg} -> {error, 21};
	false -> {error, 21};
	true ->
	    FieldValues = jsx:decode(Body),
	    ObkectKey = proplists:get_value(<<"object_key">>, FieldValues),
	    Version = proplists:get_value(<<"version">>, FieldValues),
	    case upload_handler:validate_version(Version) of
		{error, Number0} -> {error, Number0};
		DVV ->
		    case validate_object_key(BucketId, Prefix, ObkectKey, DVV) of
			{error, Number} -> {error, Number};
			{Prefix, ObjectKey, Meta} -> {Prefix, ObjectKey, Version, Meta}
		    end
	    end
    end.

%%
%% Check if object exists by provided prefix and object key.
%% Also chek if real object exist for specified date.
%%
validate_object_key(_BucketId, _Prefix, undefined, _Version) -> {error, 17};
validate_object_key(_BucketId, _Prefix, null, _Version) -> {error, 17};
validate_object_key(_BucketId, _Prefix, <<>>, _Version) -> {error, 17};
validate_object_key(_BucketId, _Prefix, _ObjectKey, undefined) -> {error, 17};
validate_object_key(_BucketId, _Prefix, _ObjectKey, null) -> {error, 17};
validate_object_key(_BucketId, _Prefix, _ObjectKey, <<>>) -> {error, 17};
validate_object_key(BucketId, Prefix, ObjectKey, Version)
	when erlang:is_list(BucketId), erlang:is_list(Prefix) orelse Prefix =:= undefined,
	     erlang:is_binary(ObjectKey), erlang:is_list(Version) ->
    PrefixedObjectKey = utils:prefixed_object_key(Prefix, erlang:binary_to_list(ObjectKey)),
    case s3_api:head_object(BucketId, PrefixedObjectKey) of
	{error, Reason} ->
	    lager:error("[version_handler] head_object failed ~p/~p: ~p",
			[BucketId, PrefixedObjectKey, Reason]),
	    {error, 5};
	not_found -> {error, 17};
	Metadata0 ->
	    IsLocked = utils:to_list(proplists:get_value("x-amz-meta-is-locked", Metadata0)),
	    case IsLocked of
		"true" -> {error, 43};
		_ ->
		    GUID0 = proplists:get_value("x-amz-meta-guid", Metadata0),
		    %% Old GUID, old bucket id and upload id are needed for 
		    %% determining URI of the original object, before it was copied
		    OldGUID = proplists:get_value("x-amz-meta-copy-from-guid", Metadata0),
		    GUID1 =
			case OldGUID =/= undefined andalso OldGUID =/= GUID0 of
			    true -> OldGUID;
			    false -> GUID0
			end,
		    %% Check if casual version exists.
		    VersionExists =
			case indexing:get_object_index(BucketId, GUID1) of
			    [] -> false;
			    List0 ->
				DVVs = lists:map(
				    fun(I) ->
					Attrs = element(2, I),
					proplists:get_value(dot, Attrs)
				    end, List0),
				lists:member(Version, DVVs)
			end,
		    case VersionExists of
			false -> {error, 44};
			Metadata1 ->
			    OrigName = proplists:get_value("x-amz-meta-orig-filename", Metadata0),
			    Bytes = proplists:get_value("x-amz-meta-bytes", Metadata0),
			    Md5 = proplists:get_value(etag, Metadata0),
			    Meta = object_handler:parse_object_record(Metadata1, [
				{orig_name, OrigName},
				{bytes, Bytes},
				{is_deleted, "false"},
				{is_locked, "false"},
				{lock_user_id, undefined},
				{lock_user_name, undefined},
				{lock_user_tel, undefined},
				{lock_modified_utc, undefined},
				{md5, Md5}]),
			    {Prefix, ObjectKey, Meta}
		    end
	    end
    end.
