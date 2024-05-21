%%
%% Stores information on performed actions.
%%
-module(action_log).
-behavior(cowboy_handler).

-export([init/2, content_types_provided/2, to_json/2, allowed_methods/2,
         content_types_accepted/2,  forbidden/2, resource_exists/2,
	 previously_existed/2]).
-export([add_record/3, fetch_full_object_history/2,
	 validate_object_key/4, validate_post/3, handle_post/2]).

-include_lib("xmerl/include/xmerl.hrl").

-include("riak.hrl").
-include("entities.hrl").
-include("action_log.hrl").

-import(xmerl_xs, 
    [ xslapply/2, value_of/1, select/2, built_in_rules/2 ]).

%%
%% Adds action log record to XML document, stored in Riak CS
%%
-spec add_record(string(), string(), #riak_action_log_record{}) -> proplist().

add_record(BucketId, Prefix, Record0) ->
    Record1 = {record, [
	{action, [Record0#riak_action_log_record.action]},
	{details, [Record0#riak_action_log_record.details]},
	{user_name, [Record0#riak_action_log_record.user_name]},
	{tenant_name, [Record0#riak_action_log_record.tenant_name]},
	{timestamp, [Record0#riak_action_log_record.timestamp]}
	]},
    PrefixedActionLogFilename = utils:prefixed_object_key(
	Prefix, ?RIAK_ACTION_LOG_FILENAME),

    case riak_api:get_object(BucketId, PrefixedActionLogFilename) of
	{error, Reason} ->
	    lager:error("[action_log] get_object error ~p/~p: ~p",
			[BucketId, PrefixedActionLogFilename, Reason]),
	    not_found;
	not_found ->
	    %% Create .riak_action_log.xml
	    RootElement0 = #xmlElement{name=action_log, content=[Record1]},
	    XMLDocument0 = xmerl:export_simple([RootElement0], xmerl_xml),
	    Response = riak_api:put_object(BucketId, Prefix, ?RIAK_ACTION_LOG_FILENAME,
					   unicode:characters_to_binary(XMLDocument0)),
	    case Response of
		{error, Reason} -> lager:error("[action_log] Can't put object ~p/~p/~p: ~p",
					       [BucketId, Prefix, ?RIAK_ACTION_LOG_FILENAME, Reason]);
		_ -> ok
	    end;
	ExistingObject ->
	    XMLDocument1 = utils:to_list(proplists:get_value(content, ExistingObject)),
	    {RootElement1, _} = xmerl_scan:string(XMLDocument1),
	    #xmlElement{content=Content} = RootElement1,
	    NewContent = [Record1]++Content,
	    NewRootElement = RootElement1#xmlElement{content=NewContent},
	    XMLDocument2 = xmerl:export_simple([NewRootElement], xmerl_xml),

	    Response = riak_api:put_object(BucketId, Prefix, ?RIAK_ACTION_LOG_FILENAME,
		unicode:characters_to_binary(XMLDocument2)),
	    case Response of
		{error, Reason} -> lager:error("[action_log] Can't put object ~p/~p/~p: ~p",
					       [BucketId, Prefix, ?RIAK_ACTION_LOG_FILENAME, Reason]);
		_ -> ok
	    end
    end.

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
%% Helps to transform action log record from XML to JSON
%%
template(E = #xmlElement{name=action_log}) ->
    xslapply(fun template/1, E);
template(E = #xmlElement{name=record}) ->
    Details = lists:flatten(xslapply(fun template/1, select("details", E))),
    UserName = lists:flatten(xslapply(fun template/1, select("user_name", E))),
    TenantName = lists:flatten(xslapply(fun template/1, select("tenant_name", E))),
    [
      {action, erlang:list_to_binary(lists:flatten(xslapply(fun template/1, select("action", E))))},
      {details, unicode:characters_to_binary(Details)},
      {user_name, unicode:characters_to_binary(utils:unhex(erlang:list_to_binary(UserName)))},
      {tenant_name, unicode:characters_to_binary(utils:unhex(erlang:list_to_binary(TenantName)))},
      {timestamp, erlang:list_to_binary(lists:flatten(xslapply(fun template/1, select("timestamp", E))))}
    ];
template(E) -> built_in_rules(fun template/1, E).

%%
%% Returns pseudo-directory action log
%%
get_action_log(Req0, State, BucketId, Prefix) ->
    PrefixedActionLogFilename = utils:prefixed_object_key(
	Prefix, ?RIAK_ACTION_LOG_FILENAME),
    ExistingObject0 = riak_api:head_object(BucketId, PrefixedActionLogFilename),
    case ExistingObject0 of
	{error, Reason} ->
	    lager:error("[action_log] head_object failed ~p/~p: ~p",
			[BucketId, PrefixedActionLogFilename, Reason]),
	    {<<"[]">>, Req0, State};
	not_found -> {<<"[]">>, Req0, State};
	_ ->
	    case riak_api:get_object(BucketId, PrefixedActionLogFilename) of
		{error, Reason} ->
		    lager:error("[action_log] get_object failed ~p/~p: ~p",
				[BucketId, PrefixedActionLogFilename, Reason]),
		    {<<>>, Req0, State};
		not_found ->
		    {<<>>, Req0, State};
		ExistingObject1 ->
		    XMLContent0 = utils:to_list(proplists:get_value(content, ExistingObject1)),
		    {XMLContent1, _} = xmerl_scan:string(XMLContent0),

		    %% filter out "\n" characters and serialize records to JSON
		    Output = jsx:encode([R || R <- template(XMLContent1),
				        proplists:is_defined(action, R) =:= true]),
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
    RealPrefix = utils:prefixed_object_key(?RIAK_REAL_OBJECT_PREFIX, GUID++"/"),
    RiakResponse = riak_api:list_objects(BucketId, [{prefix, RealPrefix}, {marker, Marker0}]),
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
    case riak_api:head_object(BucketId, PrefixedObjectKey) of
	{error, Reason} ->
	    lager:error("[action_log] head_object failed ~p/~p: ~p",
			[BucketId, PrefixedObjectKey, Reason]),
	    js_handler:not_found(Req0);
	not_found -> js_handler:not_found(Req0);
	RiakResponse0 ->
	    GUID = proplists:get_value("x-amz-meta-guid", RiakResponse0),
	    ObjectList0 = [list_handler:parse_object_record(riak_api:head_object(BucketId, I), [])
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
        undefined -> get_action_log(Req0, State, BucketId, Prefix);
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
    ActionLogRecord0 = #riak_action_log_record{
	action="restored",
	user_name=User#user.name,
	tenant_name=User#user.tenant_name,
	timestamp=Timestamp
    },
    UnicodeObjectKey = unicode:characters_to_list(OrigName),
    Summary = lists:flatten([["Restored \""], [UnicodeObjectKey], ["\" to version from "], [PrevDate]]),
    ActionLogRecord1 = ActionLogRecord0#riak_action_log_record{details=Summary},
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
    case riak_api:head_object(BucketId, PrefixedObjectKey) of
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
	    case riak_api:put_object(BucketId, Prefix, ObjectKey1, <<>>, [{meta, Meta}]) of
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
			    {true, Req0, [{user, User},
				{bucket_id, BucketId},
				{prefix, Prefix}]}
		    end
	    end;
	false -> js_handler:forbidden(Req0, 7, stop)
    end.

previously_existed(Req0, _State) ->
    {false, Req0, []}.
