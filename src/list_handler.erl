%%
%% List handler allows the following requests
%%
%% GET
%%	Returns contetnts of index.etf
%%
%% PATCH
%%	Allows to change state of object:
%%		-- undelete
%%		-- lock / unlock
%%		-- set access token for file sharing
%%
%% POST
%%	Create directory
%%
-module(list_handler).
-behavior(cowboy_handler).

-export([init/2, content_types_provided/2, content_types_accepted/2,
    to_json/2, allowed_methods/2, forbidden/2, is_authorized/2,
    resource_exists/2, previously_existed/2, patch_resource/2,
    validate_post/2, create_pseudo_directory/2, handle_post/2,
    validate_prefix/2, parse_object_record/2, prefix_lowercase/1,
    is_locked_for_user/4]).

-export([validate_delete/2, delete_resource/2, delete_completed/2,
         delete_pseudo_directory/6, delete_objects/6]).

-include("riak.hrl").
-include("entities.hrl").
-include("general.hrl").
-include("action_log.hrl").
-include("log.hrl").

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

%%
%% Called first
%%
allowed_methods(Req, State) ->
    {[<<"GET">>, <<"PATCH">>, <<"POST">>, <<"DELETE">>], Req, State}.


content_types_provided(Req, State) ->
    {[
	{{<<"application">>, <<"json">>, '*'}, to_json}
    ], Req, State}.

content_types_accepted(Req, State) ->
    case cowboy_req:method(Req) of
	<<"PATCH">> ->
	    {[{{<<"application">>, <<"json">>, '*'}, patch_resource}], Req, State};
	<<"POST">> ->
	    {[{{<<"application">>, <<"json">>, '*'}, handle_post}], Req, State}
    end.

to_json(Req0, State) ->
    BucketId = proplists:get_value(bucket_id, State),
    Prefix0 = proplists:get_value(prefix, State),
    Groups =
	case proplists:get_value(user, State) of
	    undefined -> [];
	    User0 ->
		User1 = admin_users_handler:user_to_proplist(User0),
		proplists:get_value(groups, User1)
	end,
    ParsedQs = cowboy_req:parse_qs(Req0),
    ShowDeleted =
	case proplists:is_defined(<<"show-deleted">>, ParsedQs) of
	    true ->
		case proplists:get_value(<<"show-deleted">>, ParsedQs) of
		    <<"1">> -> true;
		    <<"true">> -> true;
		    _ -> false
		end;
	    false -> false
	end,
    T0 = utils:timestamp(),
    case riak_api:head_bucket(BucketId) of
	not_found ->
	    %% Bucket is valid, but it do not exist yet
	    riak_api:create_bucket(BucketId),
	    T1 = utils:timestamp(),
	    Req1 = cowboy_req:reply(200, #{
		<<"content-type">> => <<"application/json">>,
		<<"elapsed-time">> => io_lib:format("~.2f", [utils:to_float(T1-T0)/1000])
	    }, jsx:encode([{list, []}, {dirs, []}, {groups, Groups}]), Req0),
	    {stop, Req1, []};
	_ ->
	    Prefix1 = prefix_lowercase(Prefix0),
	    PrefixedIndexFilename = utils:prefixed_object_key(Prefix1, ?RIAK_INDEX_FILENAME),
	    case riak_api:get_object(BucketId, PrefixedIndexFilename) of
		{error, Reason} ->
		    lager:warning("[list_handler] get_object error ~p/~p: ~p",
				[BucketId, PrefixedIndexFilename, Reason]),
		    T1 = utils:timestamp(),
		    Req1 = cowboy_req:reply(200, #{
			<<"content-type">> => <<"application/json">>,
			<<"elapsed-time">> => io_lib:format("~.2f", [utils:to_float(T1-T0)/1000])
		    }, jsx:encode([{list, []}, {dirs, []}, {groups, Groups}]), Req0),
		    {stop, Req1, []};
		not_found -> {jsx:encode([{list, []}, {dirs, []}, {groups, Groups}]), Req0, []};
		RiakResponse ->
		    List0 = erlang:binary_to_term(proplists:get_value(content, RiakResponse)),
		    {Dirs, Objects} =
			case ShowDeleted of
			    false ->  %% filter out objects marked as deleted
				List1 = [I || I <- proplists:get_value(list, List0),
					 proplists:get_value(is_deleted, I) =:= false],
				Dirs0 = [I || I <- proplists:get_value(dirs, List0),
					 proplists:get_value(is_deleted, I) =:= false],
				{Dirs0, List1};
			    true -> {proplists:get_value(dirs, List0), proplists:get_value(list, List0)}
			end,
		    T1 = utils:timestamp(),
		    Req1 = cowboy_req:reply(200, #{
			<<"content-type">> => <<"application/json">>,
			<<"elapsed-time">> => io_lib:format("~.2f", [utils:to_float(T1-T0)/1000])
		    }, jsx:encode([{list, Objects}, {dirs, Dirs}, {groups, Groups}]), Req0),
		    {stop, Req1, []}
	    end
    end.

%%
%% Checks if provided token is correct.
%% Extracts token from request headers and looks it up in "security" bucket.
%% ( called after 'allowed_methods()' )
%%
is_authorized(Req0, _State) ->
    case utils:get_token(Req0) of
	undefined -> {true, Req0, undefined};
	Token -> login_handler:get_user_or_error(Req0, Token)
    end.

%%
%% Checks if user has access
%% ( called after 'is_authorized()' )
%%
forbidden(Req0, User) ->
    BucketId =
	case cowboy_req:binding(bucket_id, Req0) of
	    undefined -> undefined;
	    BV -> erlang:binary_to_list(BV)
	end,
    TenantId =
	case User of
	    undefined -> undefined;
	    _ -> User#user.tenant_id
	end,
    case utils:is_valid_bucket_id(BucketId, TenantId) of
	true ->
	    UserBelongsToGroup =
		case User of
		    undefined -> undefined;
		    _ -> lists:any(
			    fun(Group) -> utils:is_bucket_belongs_to_group(BucketId, TenantId, Group#group.id) end,
			    User#user.groups)
		end,
	    case UserBelongsToGroup orelse utils:is_bucket_belongs_to_tenant(BucketId, TenantId) of
		false ->
		    case utils:is_restricted_bucket_id(BucketId) of
			true -> {false, Req0, [{user, User}, {bucket_id, BucketId}]};
			false ->
			    PUser = admin_users_handler:user_to_proplist(User),
			    js_handler:forbidden(Req0, 37, proplists:get_value(groups, PUser), ok)
		    end;
		true -> {false, Req0, [{user, User}, {bucket_id, BucketId}]};
		undefined -> {false, Req0, [{bucket_id, BucketId}]}
	    end;
	false -> js_handler:forbidden(Req0, 7, stop)
    end.

%%
%% Validates request parameters
%% ( called after 'content_types_provided()' )
%%
resource_exists(Req0, State) ->
    ParsedQs = cowboy_req:parse_qs(Req0),
    Prefix0 = proplists:get_value(<<"prefix">>, ParsedQs),
    case utils:is_valid_hex_prefix(Prefix0) of
	false -> {false, Req0, []};
	true -> {true, Req0, State++[{prefix, Prefix0}]}
    end.

previously_existed(Req0, _State) ->
    {false, Req0, []}.

%%
%% Parses Metadata, overriding values from provided Options.
%%
%% Returns meta info for riak_api:put_object() call.
%%
parse_object_record(Metadata, Options) ->
    OptionMetaMap = [
	{orig_name, "x-amz-meta-orig-filename", "orig-filename"},
	{version, "x-amz-meta-version", "version"},
	{upload_time, "x-amz-meta-upload-time", "upload-time"},
	{bytes, "x-amz-meta-bytes", "bytes"},
	{guid, "x-amz-meta-guid", "guid"},
	{upload_id, "x-amz-meta-upload-id", "upload-id"},
	{copy_from_guid, "x-amz-meta-copy-from-guid", "copy-from-guid"},
	{copy_from_bucket_id, "x-amz-meta-copy-from-bucket-id", "copy-from-bucket-id"},
	{is_deleted, "x-amz-meta-is-deleted", "is-deleted"},
	{author_id, "x-amz-meta-author-id", "author-id"},
	{author_name, "x-amz-meta-author-name", "author-name"},
	{author_tel, "x-amz-meta-author-tel", "author-tel"},
	{is_locked, "x-amz-meta-is-locked", "is-locked"},
	{lock_user_id, "x-amz-meta-lock-user-id", "lock-user-id"},
	{lock_user_name, "x-amz-meta-lock-user-name", "lock-user-name"},
	{lock_user_tel, "x-amz-meta-lock-user-tel", "lock-user-tel"},
	{lock_modified_utc, "x-amz-meta-lock-modified-utc", "lock-modified-utc"},
	{md5, etag, "md5"},
	{width, "x-amz-meta-width", "width"},
	{height, "x-amz-meta-height", "height"}
    ],
    lists:map(
        fun(I) ->
	    OptionName = element(1, I),
	    MetaName = element(2, I),
	    OutputName = element(3, I),
	    Value =
		case proplists:is_defined(OptionName, Options) of
		    false ->
			case MetaName of
			    etag ->
				Etag = proplists:get_value(etag, Metadata, ""),
				string:strip(Etag, both, $");
			    _ -> proplists:get_value(MetaName, Metadata)
			end;
		    true ->
			case proplists:get_value(OptionName, Options) of
			    undefined -> proplists:get_value(MetaName, Metadata);
			    V -> V
			end
		end,
	    {OutputName, Value}
        end, OptionMetaMap).

%%
%% Request example:
%%
%% {
%%   "op": "lock",
%%   "objects": ["key1", "key2", ..],
%%   "prefix": "74657374/"
%% }
%%
validate_patch(Body, State) ->
    BucketId = proplists:get_value(bucket_id, State),
    case jsx:is_json(Body) of
	{error, badarg} -> {error, 21};
	false -> {error, 21};
	true ->
	    FieldValues = jsx:decode(Body),
	    Prefix0 = proplists:get_value(<<"prefix">>, FieldValues),
	    case validate_prefix(BucketId, Prefix0) of
		{error, Number} -> {error, Number};
		Prefix1 ->
		    ObjectsList0 = proplists:get_value(<<"objects">>, FieldValues),
		    ObjectsList1 =
			case ObjectsList0 of
			    undefined -> [];
			    _ -> [utils:to_list(N) || N <- ObjectsList0, byte_size(N) < 255]
			end,
		    case proplists:get_value(<<"op">>, FieldValues) of
			undefined -> {error, 41};
			<<"lock">> -> {Prefix1, ObjectsList1, lock};
			<<"unlock">> -> {Prefix1, ObjectsList1, unlock};
			<<"undelete">> -> {Prefix1, ObjectsList1, undelete};
			<<"access-token">> -> {Prefix1, ObjectsList1, access_token};
			_ -> {error, 41}
		    end
	    end
    end.

%%
%% PATCH request is used to mark objects as locked/unlocked/not deleted.
%%
patch_resource(Req0, State) ->
    case proplists:get_value(user, State) of
	undefined -> js_handler:unauthorized(Req0, 28);
	User ->
	    {ok, Body, Req1} = cowboy_req:read_body(Req0),
	    case validate_patch(Body, State) of
		{error, Number} -> js_handler:bad_request(Req1, Number);
		{Prefix, ObjectsList, Operation} ->
		    BucketId = proplists:get_value(bucket_id, State),
		    patch_operation(Req0, Operation, BucketId, Prefix, User, ObjectsList)
	    end
    end.

patch_operation(Req0, lock, BucketId, Prefix, User, ObjectsList) ->
    UpdatedOnes0 = [update_lock(User, BucketId, Prefix, K, true) || K <- ObjectsList],
    UpdatedOnes1 = [I || I <- UpdatedOnes0, I =/= not_found andalso I =/= error],
    %% prepare JSON response
    UpdatedOnes2 = lists:map(
	fun(I) ->
	    IsLocked =
		case proplists:get_value(is_locked, I) of
		    <<"true">> -> true;
		    _ -> false
		end,
	    lists:keyreplace(is_locked, 1, I, {is_locked, IsLocked})
	end, UpdatedOnes1),
    Req1 = cowboy_req:set_resp_body(jsx:encode(UpdatedOnes2), Req0),
    UpdatedKeys = [erlang:binary_to_list(proplists:get_value(object_key, I))
		   || I <- UpdatedOnes1],
    case indexing:update(BucketId, Prefix, [{modified_keys, UpdatedKeys}]) of
	lock ->
	    lager:warning("[list_handler] Can't update index during locking object, as index lock exists: ~p/~p",
		       [BucketId, Prefix]),
	    js_handler:too_many(Req1);
	_ ->
	    {true, Req1, []}
    end;
patch_operation(Req0, unlock, BucketId, Prefix, User, ObjectsList) ->
    UpdatedOnes0 = [update_lock(User, BucketId, Prefix, K, false) || K <- ObjectsList],
    UpdatedOnes1 = [I || I <- UpdatedOnes0, I =/= not_found andalso I =/= error],
    %% prepare JSON response
    UpdatedOnes2 = lists:map(
	fun(I) ->
	    IsLocked =
		case proplists:get_value(is_locked, I) of
		    <<"true">> -> true;
		    _ -> false
		end,
	    lists:keyreplace(is_locked, 1, I, {is_locked, IsLocked})
	end, UpdatedOnes1),
    Req1 = cowboy_req:set_resp_body(jsx:encode(UpdatedOnes2), Req0),
    UpdatedKeys = [erlang:binary_to_list(proplists:get_value(object_key, I))
		   || I <- UpdatedOnes1],
    case indexing:update(BucketId, Prefix, [{modified_keys, UpdatedKeys}]) of
	lock ->
	    lager:warning("[list_handler] Can't update index during unlocking object, as index lock exists",
		       [BucketId, Prefix]),
	    js_handler:too_many(Req1);
	_ -> {true, Req1, []}
    end;
patch_operation(Req0, undelete, BucketId, Prefix, _User, ObjectsList) ->
    ModifiedKeys0 = [undelete(BucketId, Prefix, K) || K <- ObjectsList],
    ModifiedKeys1 = [erlang:binary_to_list(proplists:get_value(object_key, I))
		     || I <- ModifiedKeys0, I =/= not_found],
    case indexing:update(BucketId, Prefix, [{modified_keys, ModifiedKeys1}]) of
	lock ->
	    lager:warning("[list_handler] Can't update index during undeleting object, as index lock exists: ~p/~p",
		       [BucketId, Prefix]),
	    js_handler:too_many(Req0);
	_ -> {true, Req0, []}
    end;
patch_operation(Req0, access_token, BucketId, Prefix, _User, ObjectsList) ->
    ModifiedKeys0 = [set_access_token(BucketId, Prefix, K) || K <- ObjectsList],
    ModifiedKeys1 = [erlang:binary_to_list(proplists:get_value(object_key, I))
		     || I <- ModifiedKeys0, I =/= not_found],
    case indexing:update(BucketId, Prefix, [{modified_keys, ModifiedKeys1}]) of
	lock ->
	    lager:warning("[list_handler] Can't update index during undeleting object, as index lock exists: ~p/~p",
		       [BucketId, Prefix]),
	    js_handler:too_many(Req0);
	_ -> {true, Req0, []}
    end.

set_access_token(_BucketId, Prefix, K) ->
    utils:prefixed_object_key(Prefix, K).

%% TODO: test this
undelete(BucketId, Prefix, ObjectKey) ->
    PrefixedObjectKey = utils:prefixed_object_key(Prefix, ObjectKey),
    case riak_api:head_object(BucketId, PrefixedObjectKey) of
	{error, Reason} ->
	    lager:error("[list_handler] head_object failed ~p/~p: ~p", [BucketId, PrefixedObjectKey, Reason]),
	    not_found;
	not_found -> not_found;
	Metadata0 ->
	    LockModifiedTime =  io_lib:format("~p", [erlang:round(utils:timestamp()/1000)]),
	    Meta = parse_object_record(Metadata0, [{lock_modified_utc, LockModifiedTime}]),
	    IsLocked = proplists:get_value("is-locked", Meta),
	    Response = riak_api:put_object(BucketId, Prefix, ObjectKey, <<>>, [{meta, Meta}]),
	    case Response of
		ok ->
		    [{object_key, ObjectKey},
		     {is_locked, IsLocked},
		     {lock_modified_utc, LockModifiedTime}];
		{error, Reason} ->
		    lager:error("[list_handler] Can't put object: ~p/~p/~p: ~p",
				[BucketId, Prefix, ObjectKey, Reason]),
		    error
	    end
    end.

%%
%% Update lock on object by replacing it with new metadata.
%%
update_lock(User, BucketId, Prefix, ObjectKey, IsLocked0) when erlang:is_boolean(IsLocked0) ->
    PrefixedObjectKey = utils:prefixed_object_key(Prefix, ObjectKey),
    case riak_api:head_object(BucketId, PrefixedObjectKey) of
	{error, Reason} ->
	    lager:error("[list_handler] head_object failed ~p/~p: ~p",
			[BucketId, PrefixedObjectKey, Reason]),
	    not_found;
	not_found -> not_found;
	Metadata0 ->
	    WasLocked =
		case proplists:get_value("x-amz-meta-is-locked", Metadata0) of
		    undefined -> undefined;
		    L -> erlang:list_to_atom(L)
		end,
	    {LockUserId0, LockUserId1} =
		case proplists:get_value("x-amz-meta-lock-user-id", Metadata0) of
		    undefined -> {undefined, undefined};
		    UID -> {UID, erlang:list_to_binary(UID)}
		end,
	    LockModifiedTime0 = io_lib:format("~p", [erlang:round(utils:timestamp()/1000)]),
	    Options =
		case IsLocked0 of
		    true ->
			[{lock_modified_utc, LockModifiedTime0},
			 {lock_user_id, User#user.id},
			 {lock_user_name, User#user.name},
			 {lock_user_tel, User#user.tel},
			 {is_locked, erlang:atom_to_list(IsLocked0)}];
		    false ->
			[{lock_modified_utc, undefined},
			 {lock_user_id, undefined},
			 {lock_user_name, undefined},
			 {lock_user_tel, undefined},
			 {is_locked, undefined}]
		end,
	    IsDeleted = utils:to_list(proplists:get_value("x-amz-meta-is-deleted", Metadata0)),
	    case (LockUserId0 =:= undefined orelse LockUserId0 =:= User#user.id)
		    andalso IsDeleted =/= "true" andalso WasLocked =/= IsLocked0 of
		true ->
		    Meta = parse_object_record(Metadata0, Options),
		    case riak_api:put_object(BucketId, Prefix, ObjectKey, <<>>,
					     [{meta, Meta}]) of
			ok ->
			    ?INFO("Lock state changes from ~p to ~p: ~s/~s",
				  [WasLocked, IsLocked0, BucketId, PrefixedObjectKey]),
			    %% add lock object, to improve speed of copy/move/rename
			    LockObjectKey = ObjectKey ++ ?RIAK_LOCK_SUFFIX,
			    case IsLocked0 of
				true ->
				    riak_api:put_object(BucketId, Prefix, LockObjectKey, <<>>, [{meta, Meta}]),
				    sqlite_server:lock_object(BucketId, Prefix, ObjectKey, true);
				false ->
				    PrefixedLockObjectKey = utils:prefixed_object_key(Prefix, LockObjectKey),
				    riak_api:delete_object(BucketId, PrefixedLockObjectKey),
				    sqlite_server:lock_object(BucketId, Prefix, ObjectKey, false)
			    end,
			    LockUserTel =
				case User#user.tel of
				    undefined -> null;
				    V -> utils:unhex(erlang:list_to_binary(V))
				end,
			    [{object_key, erlang:list_to_binary(ObjectKey)},
			     {is_locked, utils:to_binary(IsLocked0)},
			     {lock_user_id, erlang:list_to_binary(User#user.id)},
			     {lock_user_name, utils:unhex(erlang:list_to_binary(User#user.name))},
			     {lock_user_tel, LockUserTel},
			     {lock_modified_utc, erlang:list_to_binary(LockModifiedTime0)}];
			{error, Reason} ->
			    lager:error("[list_handler] Can't put object ~p/~p/~p: ~p",
					[BucketId, Prefix, ObjectKey, Reason]),
			    error
		    end;
		false ->
		    OldLockUserName =
			case proplists:get_value("x-amz-meta-lock-user-name", Metadata0) of
			    undefined -> null;
			    U -> utils:unhex(erlang:list_to_binary(U))
			end,
		    OldLockUserTel =
			case proplists:get_value("x-amz-meta-lock-user-tel", Metadata0) of
			    undefined -> null;
			    T -> utils:unhex(erlang:list_to_binary(T))
			end,
		    LockModifiedTime1 =
			case proplists:get_value("x-amz-meta-lock-modified-utc", Metadata0) of
			    undefined -> null;
			    LT -> erlang:list_to_integer(LT)
			end,
		    [{object_key, erlang:list_to_binary(ObjectKey)},
		     {is_locked, utils:to_binary(WasLocked)},
		     {lock_user_id, LockUserId1},
		     {lock_user_name, OldLockUserName},
		     {lock_user_tel, OldLockUserTel},
		     {lock_modified_utc, LockModifiedTime1}]
	    end
    end.

%%
%% Check whether object with provided BucketId/Prefix/ObjectKey can be modifled 
%% by user with UserId.
%%
is_locked_for_user(BucketId, Prefix, ObjectKey, UserId)
	when erlang:is_list(BucketId) andalso 
	    erlang:is_list(Prefix) orelse Prefix =:= undefined andalso erlang:is_list(ObjectKey) 
	    andalso erlang:is_list(UserId) ->

    %% Check if object is deleted
    PrefixedObjectKey = utils:prefixed_object_key(Prefix, ObjectKey),
    case riak_api:head_object(BucketId, PrefixedObjectKey) of
	{error, Reason1} ->
	    lager:error("[list_handler] head_object failed ~p/~p: ~p",
			[BucketId, PrefixedObjectKey, Reason1]),
	    {error, Reason1};
	not_found -> {error, not_found};
	    ObjMeta ->
		case proplists:get_value("x-amz-meta-is-deleted", ObjMeta) of
		    "true" -> {false, ObjMeta};
		    _ ->
			PrefixedLockKey = utils:prefixed_object_key(Prefix, ObjectKey ++ ?RIAK_LOCK_SUFFIX),
			case riak_api:head_object(BucketId, PrefixedLockKey) of
			    {error, Reason0} ->
				lager:error("[list_handler] head_object failed ~p/~p: ~p",
					    [BucketId, PrefixedLockKey, Reason0]),
				{error, Reason0};
			    not_found -> {false, ObjMeta};  %% Not locked
			    LockMeta ->
				LockUserId = proplists:get_value("x-amz-meta-lock-user-id", LockMeta),
				CanWrite = LockUserId =/= undefined andalso UserId =/= LockUserId,
				{CanWrite, ObjMeta}
			end
		end
    end.


%%
%% Receives binary hex prefix value, returns lowercase hex string.
%% Appends "/" at the end if absent.
%%
-spec prefix_lowercase(binary()|undefined) -> list()|undefined.

prefix_lowercase(<<>>) -> undefined;
prefix_lowercase(undefined) -> undefined;
prefix_lowercase(Prefix0) when erlang:is_binary(Prefix0) ->
   Prefix1 = string:to_lower(lists:flatten(erlang:binary_to_list(Prefix0))),
   case utils:ends_with(Prefix0, <<"/">>) of
       true -> Prefix1;
       false -> Prefix1++"/"
   end.

%%
%% Validates prefix from POST request.
%%
%% Checks the following.
%%
%% - Prefix is a valid hex encoded value
%% - It do not start with RIAK_REAL_OBJECT_PREFIX
%% - It exists
%%
-spec validate_prefix(undefined|null|list(), undefined|list()) -> list()|{error, integer}.

validate_prefix(undefined, _Prefix) -> undefined;
validate_prefix(null, _Prefix) -> undefined;
validate_prefix(_BucketId, undefined) -> undefined;
validate_prefix(_BucketId, null) -> undefined;
validate_prefix(_BucketId, <<>>) -> undefined;
validate_prefix(BucketId, Prefix0) when erlang:is_list(BucketId),
	erlang:is_binary(Prefix0) orelse Prefix0 =:= undefined ->
    case validate_prefix(Prefix0) of
	{error, Number} -> {error, Number};
	undefined -> undefined;
	Prefix1 ->
	    %% Check if prefix exists
	    PrefixedIndexFilename = utils:prefixed_object_key(Prefix1, ?RIAK_INDEX_FILENAME),
	    case riak_api:head_object(BucketId, PrefixedIndexFilename) of
		{error, _} -> {error, 5};
		not_found -> {error, 11};
		_ -> Prefix1
	    end
    end.
validate_prefix(Prefix0) ->
    case utils:is_valid_hex_prefix(Prefix0) of
	true ->
	    Prefix1 = prefix_lowercase(Prefix0),
	    case Prefix1 of
		undefined -> undefined;
		_ ->
		    case utils:is_hidden_prefix(Prefix1) of
			true -> {error, 36};
			false -> Prefix1
		    end
	    end;
	false -> {error, 11}
    end.

validate_directory_name(_BucketId, _Prefix, null) -> {error, 12};
validate_directory_name(_BucketId, null, _DirectoryName0) -> {error, 36};
validate_directory_name(_BucketId, _Prefix, undefined) -> {error, 12};
validate_directory_name(BucketId, Prefix0, DirectoryName0)
	when erlang:is_list(BucketId),
	     erlang:is_binary(Prefix0) orelse Prefix0 =:= undefined,
	     erlang:is_binary(DirectoryName0) ->
    case utils:is_valid_object_key(DirectoryName0) of
	false -> {error, 12};
	true ->
	    case validate_prefix(BucketId, Prefix0) of
		{error, Number} -> {error, Number};
		Prefix1 ->
		    case utils:starts_with(DirectoryName0, erlang:list_to_binary(?RIAK_REAL_OBJECT_PREFIX))
			    andalso Prefix0 =:= undefined of
			true -> {error, 10};
			false -> Prefix1
		    end
	    end
    end.

%%
%% Validates create directory request.
%% It checks if directory name and prefix are correct.
%%
validate_post(Body, BucketId) ->
    case jsx:is_json(Body) of
	{error, badarg} -> {error, 21};
	false -> {error, 21};
	true ->
	    FieldValues = jsx:decode(Body),
	    Prefix0 = proplists:get_value(<<"prefix">>, FieldValues),
	    DirectoryName0 = proplists:get_value(<<"directory_name">>, FieldValues),
	    case validate_directory_name(BucketId, Prefix0, DirectoryName0) of
		{error, Number} -> {error, Number};
		Prefix1 ->
		    IndexContent = indexing:get_index(BucketId, Prefix1),
		    case indexing:directory_or_object_exists(BucketId, Prefix1, DirectoryName0, IndexContent) of
			{directory, _DirName} -> {error, 10};
			{object, _OrigName} -> {error, 29};
			false ->
			    PrefixedDirectoryName = utils:prefixed_object_key(Prefix1, utils:hex(DirectoryName0)),
			    {PrefixedDirectoryName, Prefix1, DirectoryName0}
		    end
	    end
    end.

%%
%% Encodes directory name as hex string 
%%
%% Example: "something" is uploaded as 736f6d657468696e67/.riak_index.etf
%%
-spec create_pseudo_directory(any(), proplist()) -> any().

create_pseudo_directory(Req0, State) when erlang:is_list(State) ->
    BucketId = proplists:get_value(bucket_id, State),
    PrefixedDirectoryName = proplists:get_value(prefixed_directory_name, State),
    DirectoryName0 = proplists:get_value(directory_name, State),
    DirectoryName1 = unicode:characters_to_list(DirectoryName0),
    Prefix = proplists:get_value(prefix, State),

    case indexing:update(BucketId, PrefixedDirectoryName++"/") of
	lock ->
	    lager:warning("[list_handler] Can't update index during create pseudo dir, as index lock exists: ~p/~p",
		       [BucketId, PrefixedDirectoryName++"/"]),
	    js_handler:too_many(Req0);
       _ ->
	    case indexing:update(BucketId, Prefix) of
		lock ->
		    lager:warning("[list_handler] Can't update index during locking object as index lock exists: ~p/~p",
			       [BucketId, Prefix]),
		    js_handler:too_many(Req0);
               _ ->
                    User = proplists:get_value(user, State),
		    sqlite_server:create_pseudo_directory(BucketId, Prefix, DirectoryName0, User),
                    ActionLogRecord0 = #riak_action_log_record{
                       action="mkdir",
                       user_name=User#user.name,
                       tenant_name=User#user.tenant_name,
                       timestamp=io_lib:format("~p", [erlang:round(utils:timestamp()/1000)])
                    },
                    Summary0 = lists:flatten([["Created directory \""], DirectoryName1 ++ ["/\"."]]),
                    ActionLogRecord1 = ActionLogRecord0#riak_action_log_record{details=Summary0},
                    action_log:add_record(BucketId, Prefix, ActionLogRecord1),
                    {true, Req0, []}
	    end
    end.

%%
%% Creates pseudo directory.
%%
handle_post(Req0, State0) ->
    BucketId = proplists:get_value(bucket_id, State0),
    case riak_api:head_bucket(BucketId) of
    	not_found -> riak_api:create_bucket(BucketId);
	_ -> ok
    end,
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case validate_post(Body, BucketId) of
	{error, Number} -> js_handler:bad_request(Req1, Number);
	{PrefixedDirectoryName, Prefix, DirectoryName} ->
	    case proplists:get_value(user, State0) of
		undefined -> js_handler:unauthorized(Req0, 28);
		User ->
		    case User#user.staff =:= false of
			true -> js_handler:unauthorized(Req0, 37);
			false ->
			    create_pseudo_directory(Req1, [
				{prefixed_directory_name, PrefixedDirectoryName},
				{prefix, Prefix},
				{directory_name, DirectoryName},
				{user, User},
				{bucket_id, BucketId}])
		    end
	    end
    end.

%%
%% Checks if valid bucket id and JSON request provided.
%%
basic_delete_validations(Req0, State) ->
    BucketId = proplists:get_value(bucket_id, State),
    case riak_api:head_bucket(BucketId) of
	not_found -> {error, 7};
	_ ->
	    {ok, Body, Req1} = cowboy_req:read_body(Req0),
	    case jsx:is_json(Body) of
		{error, badarg} -> {error, 21};
		false -> {error, 21};
		true ->
		    FieldValues = jsx:decode(Body),
		    Prefix0 = proplists:get_value(<<"prefix">>, FieldValues),
		    ObjectKeys = [I || I <- proplists:get_value(<<"object_keys">>, FieldValues, []), I =/= null],
		    case validate_prefix(BucketId, Prefix0) of
			{error, Number} -> {error, Number};
			Prefix1 -> {Req1, BucketId, Prefix1, ObjectKeys}
		    end
	    end
    end.

%%
%% Checks if list of objects or pseudo-directories provided
%%
validate_delete(Req0, State) ->
    case proplists:get_value(user, State) of
	undefined -> js_handler:unauthorized(Req0, 28);
	_ ->
	    case basic_delete_validations(Req0, State) of
		{error, Number} -> {error, Number};
		{Req1, BucketId, Prefix, ObjectKeys0} ->
		    List0 = indexing:get_index(BucketId, Prefix),
		    %% Extract pseudo-directories from provided object keys
		    PseudoDirectories = lists:filter(
			fun(I) ->
			    case utils:ends_with(I, <<"/">>) of
				true ->
				    try utils:unhex(I) of
					Name -> indexing:pseudo_directory_exists(List0, Name) =/= false
				    catch error:badarg -> false end;
				false -> false
			    end
			end, ObjectKeys0),
		    ObjectKeys1 = lists:filter(
			fun(I) ->
			    case indexing:get_object_record(List0, I) of
				[] -> false;
				_ -> utils:is_hidden_object([{key, erlang:binary_to_list(I)}]) =:= false
			    end
			end, ObjectKeys0),
		    case length(PseudoDirectories) =:= 0 andalso length(ObjectKeys1) =:= 0 of
			true -> {error, 34};
			false -> {Req1, BucketId, Prefix, PseudoDirectories, ObjectKeys1}
		    end
	    end
    end.

delete_pseudo_directory(_BucketId, "", "/", _User, _ActionLogRecord, _Timestamp) -> {dir_name, "/"};
delete_pseudo_directory(BucketId, Prefix, HexDirName, User, ActionLogRecord0, Timestamp) ->
    %%     - mark directory as deleted
    %%     - mark all nested objects as deleted
    %%     - leave record in action log
    DstDirectoryName0 = utils:unhex(HexDirName),
    DstDirectoryName1 = unicode:characters_to_list(DstDirectoryName0),

    case string:str(DstDirectoryName1, "-deleted-") of
	0 ->
	    %% "-deleted-" string was not found
	    case indexing:update(BucketId, Prefix, [{to_delete, [{HexDirName, Timestamp}]}]) of
		lock ->
		    lager:warning("[list_handler] Can't update index during deleting pseudo-dir ~p/~p",
			       [BucketId, Prefix]),
		    lock;
		_ ->
		    PrefixedObjectKey = utils:prefixed_object_key(Prefix, erlang:binary_to_list(HexDirName)),
		    DstDirectoryName2 = lists:concat([DstDirectoryName1, "-deleted-", Timestamp]),
		    Result = rename_handler:rename_pseudo_directory(BucketId, Prefix, PrefixedObjectKey,
			unicode:characters_to_binary(DstDirectoryName2), ActionLogRecord0),
		    case Result of
			lock -> lock;
			{accepted, _} -> undefined; %% Rename is not complete, as Riak CS was busy.
			{error, _} -> undefined; %% Client should retry attempt to delete the directory
			{dir_name, _} ->
			    sqlite_server:delete_pseudo_directory(BucketId, Prefix,
				DstDirectoryName0, User#user.id),
			    HexDirName
		    end
	    end;
	_ ->
	    %% "-deleted-" substring was found in directory name. Directory is marked as deleted already.
	    %% No need to add another tag. rename_pseudo_directory() marks pseudo-directory as "uncommited".
	    Summary0 = lists:flatten([["Deleted directory \""], DstDirectoryName1 ++ ["/\"."]]),
	    ActionLogRecord1 = ActionLogRecord0#riak_action_log_record{details=Summary0},
	    action_log:add_record(BucketId, Prefix, ActionLogRecord1),
	    HexDirName
    end.

%    %% Just delete files
%    PrefixedObjectKey = utils:prefixed_object_key(Prefix, ObjectKey1),
%    List0 = riak_api:recursively_list_pseudo_dir(BucketId, PrefixedObjectKey),
%    [riak_api:delete_object(BucketId, Key) || Key <- List0],
%    Summary0 = lists:flatten([["Deleted directory \""], DstDirectoryName0 ++ ["/\"."]]),
%    ActionLogRecord1 = ActionLogRecord0#riak_action_log_record{details=Summary0},
%    action_log:add_record(BucketId, Prefix, ActionLogRecord1),
%    {dir_name, ObjectKey0}.


delete_objects(_BucketId, _Prefix, [], _ActionLogRecord0, _Timestamp, _UserId) -> ok;
delete_objects(BucketId, Prefix, ObjectKeys0, ActionLogRecord0, Timestamp, UserId) ->
    ObjectKeys1 = lists:filtermap(
	fun(K) ->
	    Key = erlang:binary_to_list(K),
	    PrefixedLockKey = utils:prefixed_object_key(Prefix, Key ++ ?RIAK_LOCK_SUFFIX),
	    %% Skip locked objects
	    case riak_api:head_object(BucketId, PrefixedLockKey) of
		{error, Reason} ->
		    lager:error("[list_handler] head_object failed ~p/~p: ~p",
				[BucketId, PrefixedLockKey, Reason]),
		    {true, {K, Timestamp}};
		not_found -> {true, {K, Timestamp}};
		LockMeta ->
		    LockUserId = proplists:get_value("x-amz-meta-lock-user-id", LockMeta),
		    case LockUserId =:= UserId of
			true -> {true, {K, Timestamp}};
			false -> false
		    end
	    end
	end, ObjectKeys0),
    %% Mark object as deleted
    case indexing:update(BucketId, Prefix, [{to_delete, ObjectKeys1}]) of
	lock ->
	    lager:warning("[list_handler] Can't update index during deleting object: ~p/~p",
		       [BucketId, Prefix]),
	    lock;
	_ ->
	    %% Update SQLite db
	    [sqlite_server:delete_object(BucketId, Prefix, erlang:binary_to_list(element(1, K)))
	     || K <- ObjectKeys1],

	    %% Leave record in action log and update object records with is_deleted flag
	    OrigNames = lists:map(
		fun(I) ->
		    ObjectKey = element(1, I),
		    PrefixedObjectKey = utils:prefixed_object_key(Prefix, erlang:binary_to_list(ObjectKey)),
		    case riak_api:head_object(BucketId, PrefixedObjectKey) of
			{error, Reason} ->
			    lager:error("[list_handler] head_object error ~p/~p: ~p",
					[BucketId, PrefixedObjectKey, Reason]),
			    [];
			not_found -> [];
			Metadata0 ->
			    Meta = parse_object_record(Metadata0, [{is_deleted, "true"}]),
			    case riak_api:put_object(BucketId, Prefix, erlang:binary_to_list(ObjectKey), <<>>,
						     [{meta, Meta}]) of
				ok ->
				    UnicodeObjectName0 = proplists:get_value("orig-filename", Meta),
				    UnicodeObjectName1 = utils:unhex(erlang:list_to_binary(UnicodeObjectName0)),
				    ["\"", unicode:characters_to_list(UnicodeObjectName1), "\""];
				{error, Reason} ->
				    lager:error("[list_handler] Can't put object ~p/~p/~p: ~p",
						[BucketId, Prefix, erlang:binary_to_list(ObjectKey), Reason]),
				    []
			    end
		    end
		end, ObjectKeys1),
	    case length(ObjectKeys1) of
		0 -> [];
		_ ->
		    Summary0 = lists:flatten([["Deleted \""], OrigNames, ["\""]]),
		    ActionLogRecord1 = ActionLogRecord0#riak_action_log_record{details=Summary0},
		    action_log:add_record(BucketId, Prefix, ActionLogRecord1),
		    [element(1, I) || I <- ObjectKeys1]
	    end
    end.


delete_resource(Req0, State) ->
    case validate_delete(Req0, State) of
	{error, Number} -> js_handler:bad_request(Req0, Number);
	{Req1, BucketId, Prefix, PseudoDirectories, ObjectKeys1} ->
	    Timestamp = utils:timestamp(),
	    User = proplists:get_value(user, State),
	    ActionLogRecord0 = #riak_action_log_record{
		action="delete",
		user_name=User#user.name,
		tenant_name=User#user.tenant_name,
		timestamp=io_lib:format("~p", [erlang:round(Timestamp/1000)])
	    },
	    %% Set "uncommitted" flag only if ther's a lot of delete
	    case length(PseudoDirectories) > 0 of
		true ->
		    case indexing:update(BucketId, Prefix, [{uncommitted, true}]) of
			lock ->
			    lager:warning("[list_handler] Can't update index during deleting object, as index lock exists: ~p/~p",
				       [BucketId, Prefix]),
			    js_handler:too_many(Req1);
			_ ->
			    PseudoDirectoryResults = [delete_pseudo_directory(
				BucketId, Prefix, P, User, ActionLogRecord0, Timestamp) || P <- PseudoDirectories],
			    DeleteResult0 = delete_objects(BucketId, Prefix, ObjectKeys1,
							   ActionLogRecord0, Timestamp, User#user.id),
			    case DeleteResult0 of
				lock -> js_handler:too_many(Req0);
				_ ->
				    Output = [I || I <- PseudoDirectoryResults, I =/= undefined andalso I =/= lock],
				    {true, Req0, [{delete_result, Output}]}
			    end
		    end;
		false ->
		    case delete_objects(BucketId, Prefix, ObjectKeys1,
					ActionLogRecord0, Timestamp, User#user.id) of
			lock -> js_handler:too_many(Req1);
			DeleteResult1 -> {true, Req1, [{delete_result, DeleteResult1}]}
		    end
	    end
    end.

delete_completed(Req0, State) ->
    case proplists:get_value(errors, State) of
	undefined ->
	    DeleteResult = proplists:get_value(delete_result, State),
	    Req1 = cowboy_req:set_resp_body(jsx:encode(DeleteResult), Req0),
	    {true, Req1, []};
	Errors ->
	    Req2 = cowboy_req:reply(202, #{
		<<"content-type">> => <<"application/json">>
	    }, jsx:encode(Errors), Req0),
	    {true, Req2, []}
    end.
