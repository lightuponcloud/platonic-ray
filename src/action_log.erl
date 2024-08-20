%%
%% Stores information on performed actions.
%%
-module(action_log).
-behavior(cowboy_handler).

-export([init/2, content_types_provided/2, to_json/2, allowed_methods/2,
         content_types_accepted/2,  forbidden/2, resource_exists/2,
	 previously_existed/2]).
-export([fetch_full_object_history/2,
	 validate_object_key/4, validate_post/3, handle_post/2]).

-include_lib("xmerl/include/xmerl.hrl").

-include("storage.hrl").
-include("entities.hrl").
-include("action_log.hrl").

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

%%
%% Called first
%%
allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>], Req, State}.


content_types_provided(Req, State) ->
    {[
	{{<<"application">>, <<"json">>, '*'}, to_json}
    ], Req, State}.

content_types_accepted(Req, State) ->
    case cowboy_req:method(Req) of
	<<"POST">> ->
	    {[{{<<"application">>, <<"json">>, '*'}, handle_post}], Req, State}
    end.

%%
%% Receives stream from httpc and passes it to cowboy
%%
receive_streamed_body(RequestId0, Pid0, TempFn) ->
    httpc:stream_next(Pid0),
    receive
	{http, {RequestId0, stream, BinBodyPart}} ->
	    file:write_file(TempFn, BinBodyPart, [append]),
	    receive_streamed_body(RequestId0, Pid0, TempFn);
	{http, {RequestId0, stream_end, _Headers0}} -> ok;
	{http, Msg} ->
	    lager:error("[action_log] error receiving stream body: ~p", [Msg]),
	    ok
    end.

%%
%% Downloads action log SQLite DB from S3, saves it to temporary location and performs SQL query.
%%
sql_query(BucketId, Prefix, ObjectKey, TempFn, DbName) ->
    PrefixedActionLogFilename = utils:prefixed_object_key(Prefix, ?ACTION_LOG_FILENAME),
    case s3_api:get_object(BucketId, PrefixedActionLogFilename, stream) of
	not_found -> {error, 17};
	{ok, RequestId} ->
	    receive
	    {http, {RequestId, stream_start, _Headers, Pid0}} ->
		receive_streamed_body(RequestId, Pid0, TempFn);
		{http, Msg} ->
		    lager:error("[action_log] Can't download Sqlite DB. Bucket: ~p, Prefix: ~p. Error: ~p",
				[BucketId, Prefix, Msg])
	    end,
	    SQL = sql_lib:get_action_log_records_for_object(ObjectKey),
	    case sqlite3:sql_exec(DbName, SQL) of
		{error, _, Reason} ->
		    lager:error("[action_log] Failed to select actions from SQLite DB: ~p", [Reason]),
		    {error, 5};
		[{columns, _}, {rows, Rows}] ->
		    lists:map(
			fun(I) ->
			    IsDir =
				case element(4, I) of
				    1 -> true;
				    _ -> false
				end,
			    [
				{key, element(1, I)},
				{orig_name, element(2, I)},
				{guid, element(3, I)},
				{is_dir, IsDir},
				{action, element(5, I)},
				{details, element(6, I)},
				{user_id, element(7, I)},
				{user_name, element(8, I)},
				{tenant_name, element(9, I)},
				{timestamp, element(10, I)},
				{duration, element(11, I)},
				{version, element(12, I)}
			    ]
			end, Rows)
	    end
    end.

%%
%% Returns pseudo-directory action log
%%
get_action_log(Req0, State, BucketId, Prefix, ObjectKey) ->
    PrefixedActionLogFilename = utils:prefixed_object_key(Prefix, ?ACTION_LOG_FILENAME),
    ExistingObject0 = s3_api:head_object(BucketId, PrefixedActionLogFilename),
    case ExistingObject0 of
	{error, Reason} ->
	    lager:error("[action_log] head_object failed ~p/~p: ~p",
			[BucketId, PrefixedActionLogFilename, Reason]),
	    {<<"[]">>, Req0, State};
	not_found -> {<<"[]">>, Req0, State};
	_ ->
	    TempFn = utils:get_temp_path(middleware),
	    DbName = erlang:list_to_atom(crypto_utils:random_string()),
	    {ok, _Pid} = sqlite3:open(DbName, [{file, TempFn}]),
	    case sql_query(BucketId, Prefix, ObjectKey, TempFn, DbName) of
		{error, Number} ->
		    file:delete(TempFn),
		    js_handler:bad_request(Req0, Number);
		Result ->
		    file:delete(TempFn),
		    Output = jsx:encode(Result),
		    {Output, Req0, State}
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

%%
%% Returns the list of available versions of object.
%%
get_object_changelog(Req0, State, BucketId, Prefix, ObjectKey) ->
    PrefixedObjectKey = utils:prefixed_object_key(Prefix, ObjectKey),
    case s3_api:head_object(BucketId, PrefixedObjectKey) of
	{error, Reason} ->
	    lager:error("[action_log] head_object failed ~p/~p: ~p",
			[BucketId, PrefixedObjectKey, Reason]),
	    js_handler:not_found(Req0);
	not_found -> js_handler:not_found(Req0);
	RiakResponse0 ->
	    GUID = proplists:get_value("x-amz-meta-guid", RiakResponse0),
	    ObjectList0 = [list_handler:parse_object_record(s3_api:head_object(BucketId, I), [])
			   || I <- fetch_full_object_history(BucketId, GUID),
			   utils:is_hidden_object(I) =:= false],
	    ObjectList1 = lists:map(
		fun(I) ->
		    AuthorId = utils:to_binary(proplists:get_value("author-id", I)),
		    AuthorName = utils:unhex(utils:to_binary(proplists:get_value("author-name", I))),
		    AuthorTel =
			case proplists:get_value("author-tel", I) of
			    undefined -> null;
			    Tel -> utils:unhex(erlang:list_to_binary(Tel))
			end,
		    [{author_id, AuthorId},
		     {author_name, AuthorName},
		     {author_tel, AuthorTel},
		     {last_modified_utc, erlang:list_to_binary(proplists:get_value("modified-utc", I))}]
		end, ObjectList0),
	    Output = jsx:encode(ObjectList1),
	    {Output, Req0, State}
    end.

%%
%% Returns list of actions in pseudo-directory. If object_key specified, returns object history.
%%
to_json(Req0, State) ->
    BucketId = proplists:get_value(bucket_id, State),
    Prefix = proplists:get_value(prefix, State),

    ParsedQs = cowboy_req:parse_qs(Req0),
    case proplists:get_value(<<"object_key">>, ParsedQs) of
	undefined -> get_action_log(Req0, State, BucketId, Prefix, undefined);
	ObjectKey0 ->
	    ObjectKey1 = unicode:characters_to_list(ObjectKey0),
	    get_object_changelog(Req0, State, BucketId, Prefix, ObjectKey1)
    end.


%%
%% Adds record to pseudo-directory's history.
%% ( used in function for restoring object versions ).
%%
log_restore_action(State) ->
    User = proplists:get_value(user, State),
    BucketId = proplists:get_value(bucket_id, State),
    Prefix = proplists:get_value(prefix, State),
    OrigName = proplists:get_value(orig_name, State),
    PrevDate = proplists:get_value(prev_date, State),
    Timestamp = io_lib:format("~p", [erlang:round(utils:timestamp()/1000)]),
    ActionLogRecord0 = #action_log_record{
	action="restored",
	user_name=User#user.name,
	tenant_name=User#user.tenant_name,
	timestamp=Timestamp
    },
    UnicodeObjectKey = unicode:characters_to_list(OrigName),
    Summary = lists:flatten([["Restored \""], [UnicodeObjectKey], ["\" to version from "], [PrevDate]]),
    ActionLogRecord1 = ActionLogRecord0#action_log_record{details=Summary},
    action_log:add_record(BucketId, Prefix, ActionLogRecord1).

%%
%% Returns true if a casual version exists.
%%
version_exists(BucketId, GUID, Version) when erlang:is_list(Version) ->
    case indexing:get_object_index(BucketId, GUID) of
	[] -> false;
	List0 ->
	    DVVs = lists:map(
		fun(I) ->
		    Attrs = element(2, I),
		    proplists:get_value(dot, Attrs)
		end, List0),
	    lists:member(Version, DVVs)
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
	    lager:error("[action_log] head_object failed ~p/~p: ~p",
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
		    case version_exists(BucketId, GUID1, Version) of
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
%% Restore previous version of file
%%
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
%% Restores previous version of object
%%
handle_post(Req0, State0) ->
    BucketId = proplists:get_value(bucket_id, State0),
    Prefix = proplists:get_value(prefix, State0),
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
			    lager:warning("[action_log] Can't update index: lock exists"),
			    js_handler:too_many(Req0);
			_ ->
			    OrigName = utils:unhex(erlang:list_to_binary(proplists:get_value("orig-filename", Meta))),
			    [VVTimestamp] = dvvset:values(Version),
			    PrevDate = utils:format_timestamp(utils:to_integer(VVTimestamp)),
			    State1 = [{orig_name, OrigName},
				      {prev_date, utils:format_timestamp(PrevDate)}],
			    log_restore_action(State0 ++ State1),
			    {true, Req0, []}
		    end;
		{error, Reason} ->
		    lager:error("[action_log] Can't put object ~p/~p/~p: ~p",
				[BucketId, Prefix, ObjectKey1, Reason]),
		    lager:warning("[action_log] Can't update index: ~p", [Reason]),
		    js_handler:too_many(Req1)
	    end
    end.

%%
%% Checks if provided token is correct.
%% ( called after 'allowed_methods()' )
%%
forbidden(Req0, _State) ->
    case utils:get_token(Req0) of
	undefined -> js_handler:forbidden(Req0, 28, stop);
	Token ->
	    %% Extracts token from request headers and looks it up in "security" bucket
	    case login_handler:check_token(Token) of
		not_found -> js_handler:forbidden(Req0, 28, stop);
		expired -> js_handler:forbidden(Req0, 38, stop);
		User -> {false, Req0, [{user, User}]}
	    end
    end.

%%
%% Validates request parameters
%% ( called after 'content_types_provided()' )
%%
resource_exists(Req0, State) ->
    BucketId = erlang:binary_to_list(cowboy_req:binding(bucket_id, Req0)),
    User = proplists:get_value(user, State),
    case utils:is_valid_bucket_id(BucketId, User#user.tenant_id) of
	true ->
	    UserBelongsToGroup =
		lists:any(
		    fun(Group) ->
			utils:is_bucket_belongs_to_group(BucketId, User#user.tenant_id, Group#group.id)
		    end, User#user.groups),
	    case UserBelongsToGroup orelse utils:is_bucket_belongs_to_tenant(BucketId, User#user.tenant_id) of
		false ->{false, Req0, []};
		true ->
		    ParsedQs = cowboy_req:parse_qs(Req0),
		    case list_handler:validate_prefix(BucketId, proplists:get_value(<<"prefix">>, ParsedQs)) of
			{error, Number} ->
			    Req1 = cowboy_req:set_resp_body(jsx:encode([{error, Number}]), Req0),
			    {false, Req1, []};
			Prefix ->
			    {true, Req0, [{user, User}, {bucket_id, BucketId}, {prefix, Prefix}]}
		    end
	    end;
	false -> js_handler:forbidden(Req0, 7, stop)
    end.

previously_existed(Req0, _State) ->
    {false, Req0, []}.
