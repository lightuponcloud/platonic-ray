%%
%% Version handler returns info on provided bucket DVV ( Dotted version Vector )
%%
%% HEAD application/json
%%	Returns version of DB in JSON format.
%%
%% GET application/octet-stream
%%	Allows to download SQLite DB
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
    ParsedQs = cowboy_req:parse_qs(Req0),
    BucketId =
	case cowboy_req:binding(bucket_id, Req0) of
	    undefined -> undefined;
	    BV -> erlang:binary_to_list(BV)
	end,
    PresentedSignature =
	case proplists:get_value(<<"signature">>, ParsedQs) of
	    undefined -> undefined;
	    Signature -> unicode:characters_to_list(Signature)
	end,
    case download_handler:has_access(Req0, BucketId, undefined, undefined, PresentedSignature) of
	{error, Number} ->
	    Req1 = cowboy_req:reply(403, #{
		<<"content-type">> => <<"application/json">>
	    }, jsx:encode([{error, Number}]), Req0),
	    {ok, Req1, []};
	{_BucketId, _Prefix, _ObjectKey, User} ->
	    Method = cowboy_req:method(Req0),
	    response(Req0, Method, BucketId, User)
    end.

%%
%% HEAD HTTP request returns DVV in JSON format
%%
%% GET request returns SQLite DB itself.
%%
%% POST request uploads a new version of SQLite DB.
%%
response(Req0, <<"HEAD">>, BucketId, User) ->
    case s3_api:head_object(BucketId, ?DB_VERSION_KEY) of
	{error, Reason} ->
	    lager:error("[version_handler] head_object failed ~p/~p: ~p", [BucketId, ?DB_VERSION_KEY, Reason]),
	    first_version(Req0, User#user.id);
	not_found -> first_version(Req0, User#user.id);
	Meta ->
	    DbMeta = list_handler:parse_object_record(Meta, []),
	    Version = proplists:get_value("version", DbMeta),
	    Req1 = cowboy_req:reply(200, #{
		<<"md5">> => proplists:get_value("md5", DbMeta),
		<<"DVV">> => utils:to_binary(Version),
		<<"content-type">> => <<"application/json">>
	    }, <<>>, Req0),
	    {ok, Req1, []}
    end;

response(Req0, <<"GET">>, BucketId, _User) ->
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

response(Req0, _Method, _BucketId, _User) ->
    js_handler:bad_request_ok(Req0, 17).

%%
%% Restore previous version of file
%%
response(Req0, <<"POST">>, BucketId, Prefix, User, Body) ->
    T0 = erlang:round(utils:timestamp()/1000),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case validate_post(Body, BucketId, Prefix) of
	{error, Number} -> js_handler:bad_request(Req1, Number);
	{Prefix, ObjectKey0, Version, Meta} ->
	    ObjectKey1 = erlang:binary_to_list(ObjectKey0),
	    case s3_api:put_object(BucketId, Prefix, ObjectKey1, <<>>, [{meta, Meta}]) of
		ok ->
		    %% Update pseudo-directory index for faster listing.
		    case indexing:update(BucketId, Prefix, [{modified_keys, [ObjectKey1]}]) of
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
				[ObjectKey1],
				[{status_code, 200},
				 {request_id, null},
				 {time_to_response_ns, utils:to_float(T1-T0)/1000},
				 {user_id, User#user.id},
				 {actor, user},
				 {environment, null},
				 {compliance_metadata, [{orig_name, OrigName}, {summary, Summary}]}]
			    ),
			    {true, Req0, []}
		    end;
		{error, Reason} ->
		    lager:error("[version_handler] Can't put object ~p/~p/~p: ~p",
				[BucketId, Prefix, ObjectKey1, Reason]),
		    lager:warning("[version_handler] Can't update index: ~p", [Reason]),
		    js_handler:too_many(Req1)
	    end
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
			    Meta = list_handler:parse_object_record(Metadata1, [
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


%%
%% Retrieves list of objects from Riak CS (all pages).
%%
fetch_full_object_history(BucketId, GUID)
	when erlang:is_list(BucketId), erlang:is_list(GUID) ->
    fetch_full_object_history(BucketId, GUID, [], undefined).

fetch_full_object_history(BucketId, GUID, ObjectList0, Marker0)
	when erlang:is_list(BucketId), erlang:is_list(ObjectList0), erlang:is_list(GUID) ->
    RealPrefix = utils:prefixed_object_key(?REAL_OBJECT_PREFIX, GUID++"/"),
    RiakResponse = s3_api:list_objects(BucketId, [{prefix, RealPrefix}, {marker, Marker0}]),
    case RiakResponse of
	not_found -> [];  %% bucket not found
	_ ->
	    ObjectList1 = [proplists:get_value(key, I) || I <- proplists:get_value(contents, RiakResponse)],
	    Marker1 = proplists:get_value(next_marker, RiakResponse),
	    case Marker1 of
		undefined -> ObjectList0 ++ ObjectList1;
		[] -> ObjectList0 ++ ObjectList1;
		NextMarker ->
		    NextPart = fetch_full_object_history(BucketId, GUID, ObjectList0 ++ ObjectList1, NextMarker),
		    ObjectList0 ++ NextPart
	    end
    end.
