%%
%% Sharing objects and pseudo-directories is implemented by generating tokens
%% for pseudo-directories and for objects.
%%
-module(sharing_handler).
-behavior(cowboy_handler).

-export([add_sharing_token/4, init/2, content_types_provided/2,
    content_types_accepted/2, resource_exists/2, previously_existed/2,
    validate_object_key/2, validate_object_keys/2, validate_post/2,
    handle_post/2, sharing_record/3,
    delete_resource/2, delete_completed/2,
    to_json/2, allowed_methods/2, forbidden/2, is_authorized/2
]).

-include("storage.hrl").
-include("entities.hrl").
-include("log.hrl").


init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

%%
%% Called first
%%
allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>, <<"DELETE">>], Req, State}.


content_types_provided(Req, State) ->
    {[
	{{<<"application">>, <<"json">>, '*'}, to_json}
    ], Req, State}.


content_types_accepted(Req, State) ->
    case cowboy_req:method(Req) of
	<<"POST">> ->
	    {[{{<<"application">>, <<"json">>, '*'}, handle_post}], Req, State}
    end.


to_json(Req0, State) ->
    BucketId = proplists:get_value(bucket_id, State),
    ParsedQs = cowboy_req:parse_qs(Req0),
    Prefix0 = proplists:get_value(<<"prefix">>, ParsedQs),
    Prefix1 = list_handler:validate_prefix(BucketId, Prefix0),
    BucketExists =
	case s3_api:head_bucket(BucketId) of
	    not_found -> {error, 37};
	    _ -> ok
	end,
    T0 = utils:timestamp(),
    case lists:keyfind(error, 1, [BucketExists, Prefix1]) of
	{error, _Number} ->
	    T1 = utils:timestamp(),
	    Req1 = cowboy_req:reply(200, #{
		<<"content-type">> => <<"application/json">>,
		<<"elapsed-time">> => io_lib:format("~.2f", [utils:to_float(T1-T0)/1000])
	    }, jsx:encode([]), Req0),
	    {stop, Req1, []};
	false ->
	    PrefixedOptionsFilename = utils:prefixed_object_key(Prefix1, ?SHARING_OPTIONS_FILENAME),
	    case s3_api:get_object(BucketId, PrefixedOptionsFilename) of
		{error, Reason} ->
		    lager:warning("[sharing] get_object error ~p/~p: ~p",
				[BucketId, PrefixedOptionsFilename, Reason]),
		    T1 = utils:timestamp(),
		    Req1 = cowboy_req:reply(200, #{
			<<"content-type">> => <<"application/json">>,
			<<"elapsed-time">> => io_lib:format("~.2f", [utils:to_float(T1-T0)/1000])
		    }, jsx:encode([]), Req0),
		    {stop, Req1, []};
		not_found -> {jsx:encode([]), Req0, []};
		RiakResponse ->
		    List0 = erlang:binary_to_term(proplists:get_value(content, RiakResponse)),
		    List1 = lists:map(
			fun(I) ->
			    [{shared_by, proplists:get_value(shared_by, I)},
			     {created_utc, proplists:get_value(created_utc, I)},
			     {object_key, erlang:list_to_binary(proplists:get_value(object_key, I))},
			     {token, erlang:list_to_binary(proplists:get_value(token, I))}]
			end, List0),
		    T1 = utils:timestamp(),
		    Req1 = cowboy_req:reply(200, #{
			<<"content-type">> => <<"application/json">>,
			<<"elapsed-time">> => io_lib:format("~.2f", [utils:to_float(T1-T0)/1000])
		    }, jsx:encode(List1), Req0),
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
    {true, Req0, State}.

previously_existed(Req0, _State) ->
    {false, Req0, []}.

%%
%% Checks if object exists.
%%
-spec validate_object_key(string(), string()) -> tuple()|{error, integer()}.

validate_object_key(_Prefix, null) -> {error, 15};
validate_object_key(_Prefix, <<>>) -> {error, 15};
validate_object_key(Prefix, ObjectKey0) when erlang:is_binary(ObjectKey0) ->
    validate_object_key(Prefix, erlang:binary_to_list(ObjectKey0));
validate_object_key(Prefix, ObjectKey0)
	when erlang:is_list(Prefix) orelse Prefix =:= undefined, erlang:is_list(ObjectKey0) ->
    case utils:ends_with(ObjectKey0, <<"/">>) of
	true ->
	    %% Check if valid hex prefix provided
	    try utils:unhex(ObjectKey0) of
		_Value -> ok
	    catch error:badarg ->
		{error, 14}
	    end;
	false -> ObjectKey0
    end;
validate_object_key(_Prefix, _ObjectKey) -> {error, 15}.

%%
%% Checks if every key in object_keys exists and ther'a no duplicates
%%
validate_object_keys(_Prefix, null) -> {error, 15};
validate_object_keys(_Prefix, undefined) -> {error, 15};
validate_object_keys(_Prefix, <<>>) -> {error, 15};
validate_object_keys(_Prefix, []) -> {error, 15};
validate_object_keys(Prefix, ObjectKeys0)
	when erlang:is_list(ObjectKeys0), erlang:is_list(Prefix) orelse Prefix =:= undefined ->
    ObjectKeys1 = [validate_object_key(Prefix, I) || I <- ObjectKeys0],
    Error = lists:keyfind(error, 1, ObjectKeys1),
    case Error of
	{error, Number} -> {error, Number};
	_ ->
	    case utils:has_duplicates(ObjectKeys1) of
		true -> {error, 31};
		false -> ObjectKeys1
	    end
    end.

%%
%% Validates sharing request.
%% It checks if objects / pseudo-directory exists.
%%
validate_post(BucketId, Body) ->
    case jsx:is_json(Body) of
	{error, badarg} -> {error, 21};
	false -> {error, 21};
	true ->
	    FieldValues = jsx:decode(Body),
	    Prefix0 = proplists:get_value(<<"prefix">>, FieldValues),
	    case list_handler:validate_prefix(BucketId, Prefix0) of
		{error, Number0} -> {error, Number0};
		Prefix1 ->
		    ObjectKeys0 = proplists:get_value(<<"object_keys">>, FieldValues),
		    ObjectKeys1 = validate_object_keys(Prefix1, ObjectKeys0),
		    case ObjectKeys1 of
			{error, Number1} -> {error, Number1};
			_ -> {Prefix1, ObjectKeys1}
		    end
	    end
    end.

%%
%% Creates sharing token.
%%
handle_post(Req0, State0) ->
    T0 = utils:timestamp(),
    BucketId = proplists:get_value(bucket_id, State0),
    User = proplists:get_value(user, State0),
    case s3_api:head_bucket(BucketId) of
    	not_found -> s3_api:create_bucket(BucketId);
	_ -> ok
    end,
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case validate_post(BucketId, Body) of
	{error, Number} -> js_handler:bad_request(Req1, Number);
	{Prefix, ObjectKeys0} ->
	    Token = add_sharing_token(BucketId, Prefix, ObjectKeys0, User),
	    ObjectKeys1 = [erlang:list_to_binary(I) || I <- ObjectKeys0],
	    T1 = utils:timestamp(),
	    Req2 = cowboy_req:reply(200, #{
		<<"content-type">> => <<"application/json">>,
		<<"elapsed-time">> => io_lib:format("~.2f", [utils:to_float(T1-T0)/1000])
	    }, jsx:encode([{token, erlang:list_to_binary(Token)}, {object_keys, ObjectKeys1}]), Req1),
	    {stop, Req2, []}
    end.

%%
%% Returns contents of existing index.
%%
-spec get_options(string(), string()) -> list().

get_options(BucketId, Prefix0)
	when erlang:is_list(BucketId) andalso erlang:is_list(Prefix0) orelse Prefix0 =:= undefined ->
    PrefixedFilename = utils:prefixed_object_key(Prefix0, ?SHARING_OPTIONS_FILENAME),
    case s3_api:get_object(BucketId, PrefixedFilename) of
	{error, Reason} ->
	    lager:error("[sharing] get_object error ~p/~p: ~p",
			[BucketId, PrefixedFilename, Reason]),
	    [];
	not_found -> [];
	C -> erlang:binary_to_term(proplists:get_value(content, C))
    end.

%%
%% Check if sharing item in list
%%
item_in_list([], _UserId, _ObjectKey) -> false;
item_in_list(List0, UserId, ObjectKey0) ->
    lists:any(lists:map(
	fun(I) ->
	    SharedBy = proplists:get_value(shared_by, I),
	    ObjectKey1 = proplists:get_value(object_key, I),
	    proplists:get_value(id, SharedBy) =:= UserId andalso ObjectKey0 =:= ObjectKey1
	end, List0)).

%%
%% Adds objects to the list of shared objects, if they do not exist in list.
%%
sharing_record(List0, User, ObjectKey) ->
    Timestamp = erlang:round(utils:timestamp()/1000),
    Token = erlang:binary_to_list(crypto_utils:uuid4()),
    case item_in_list(List0, User#user.id, ObjectKey) of
	true -> List0;
	false -> List0 ++ [
	    {shared_by, admin_users_handler:user_to_proplist(User)},
	    {created_utc, Timestamp},
	    {object_key, ObjectKey},
	    {token, Token}]
    end.

%%
%% Adds tokens for ``ObjectKeys`` or ``Prefix``. In case ``ObjectyKeys`` is empty list,
%% token is generated for ``Prefix``.
%% Later that token will be compared with user-provided token, to decide whether to grant access
%% to object / pseudo-directory or not.
%%
add_sharing_token(BucketId, Prefix0, ObjectKeys, User) ->
    UserId = User#user.id,
    PrefixedLockFilename = utils:prefixed_object_key(Prefix0, ?LOCK_SHARING_OPTIONS_FILENAME),
    case s3_api:head_object(BucketId, PrefixedLockFilename) of
	{error, Reason0} ->
	    lager:error("[sharing] head_object failed ~p/~p: ~p",
			[BucketId, PrefixedLockFilename, Reason0]),
	    throw("head_object failed");
	not_found ->
	    %% Create lock file instantly
	    LockMeta = [{"modified-utc", erlang:round(utils:timestamp()/1000)}],
	    LockOptions = [{meta, LockMeta}],

	    Response = s3_api:put_object(BucketId, Prefix0, ?LOCK_SHARING_OPTIONS_FILENAME, <<>>, LockOptions),
	    case Response of
		{error, Reason1} -> lager:error("[sharing] Can't put object ~p/~p/~p: ~p",
						[BucketId, Prefix0, ?LOCK_SHARING_OPTIONS_FILENAME, Reason1]);
		_ -> ok
	    end,
	    %% Retrieve existing index object first
	    List0 = get_options(BucketId, Prefix0),
	    Token = erlang:binary_to_list(crypto_utils:uuid4()),
	    List1 =
		case ObjectKeys of
		    [] ->
			%% Add pseudo-directory to list, if it do not exist
			case item_in_list(List0, UserId, undefined) of
			    true -> List0;
			    false -> List0 ++ [
				{shared_by, admin_users_handler:user_to_proplist(User)},
				{created_utc, erlang:round(utils:timestamp()/1000)},
				{object_key, undefined},
				{token, Token}]
			end;
		    _ ->
			%% Add objects if they do not exist in list
			List0 ++ lists:filtermap(
			    fun(I) ->
				case item_in_list(List0, UserId, I) of
				    true -> false;
				    false -> {true, [
					{shared_by, admin_users_handler:user_to_proplist(User)},
					{created_utc, erlang:round(utils:timestamp()/1000)},
					{object_key, I},
					{token, Token}]}
				end
			    end, ObjectKeys)
		end,
	    Response = s3_api:put_object(BucketId, Prefix0, ?SHARING_OPTIONS_FILENAME, term_to_binary(List1)),
	    case Response of
		{error, Reason2} -> lager:error("[sharing] Can't put object ~p/~p/~p: ~p",
					       [BucketId, Prefix0, ?SHARING_OPTIONS_FILENAME, Reason2]);
		_ -> ok
	    end,
	    %% Remove lock
	    s3_api:delete_object(BucketId, PrefixedLockFilename),
	    Token;
	LockMeta ->
	    %% Check for stale index
	    DeltaSeconds =
		case proplists:get_value("x-amz-meta-modified-utc", LockMeta) of
		    undefined -> 0;
		    T -> erlang:round(utils:timestamp()/1000) - utils:to_integer(T)
		end,
	    case DeltaSeconds > ?LOCK_INDEX_COOLOFF_TIME of
		true ->
		    s3_api:delete_object(BucketId, PrefixedLockFilename),
		    add_sharing_token(BucketId, Prefix0, ObjectKeys, User);
		false -> lock
	    end
    end.

%%
%% Checks if valid bucket id and JSON request provided.
%%
basic_delete_validations(Req0, State) ->
    BucketId = proplists:get_value(bucket_id, State),
    case s3_api:head_bucket(BucketId) of
	not_found -> {error, 7};
	_ ->
	    {ok, Body, Req1} = cowboy_req:read_body(Req0),
	    case jsx:is_json(Body) of
		{error, badarg} -> {error, 21};
		false -> {error, 21};
		true ->
		    FieldValues = jsx:decode(Body),
		    Prefix0 = proplists:get_value(<<"prefix">>, FieldValues),
		    Tokens = [erlang:binary_to_list(I)
			      || I <- proplists:get_value(<<"tokens">>, FieldValues, []),
			      I =/= null],
		    case list_handler:validate_prefix(BucketId, Prefix0) of
			{error, Number} -> {error, Number};
			Prefix1 -> {Req1, BucketId, Prefix1, Tokens}
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
		{Req1, BucketId, Prefix, Tokens0} ->
		    %% Check duplicates
		    Tokens1 = sets:to_list(sets:from_list(Tokens0)),
		    case length(Tokens1) =:= length(Tokens0) of
			true -> {Req1, BucketId, Prefix, Tokens1};  %% No duplicates
			false -> {error, 31}
		    end
	    end
    end.

delete_tokens(BucketId, Prefix0, Tokens) ->
    PrefixedLockFilename = utils:prefixed_object_key(Prefix0, ?LOCK_SHARING_OPTIONS_FILENAME),
    case s3_api:head_object(BucketId, PrefixedLockFilename) of
	{error, Reason0} ->
	    lager:error("[sharing] head_object failed ~p/~p: ~p", [BucketId, PrefixedLockFilename, Reason0]),
	    throw("head_object failed");
	not_found ->
	    %% Create lock file instantly
	    LockMeta = [{"modified-utc", erlang:round(utils:timestamp()/1000)}],
	    LockOptions = [{meta, LockMeta}],
	    Response = s3_api:put_object(BucketId, Prefix0, ?LOCK_SHARING_OPTIONS_FILENAME, <<>>, LockOptions),
	    case Response of
		{error, Reason1} -> lager:error("[sharing] Can't put object ~p/~p/~p: ~p",
						[BucketId, Prefix0, ?LOCK_SHARING_OPTIONS_FILENAME, Reason1]);
		_ -> ok
	    end,
	    %% Retrieve existing index object first
	    List0 = get_options(BucketId, Prefix0),
	    %% Remove tokens from list of tokens
	    List1 = lists:filtermap(
		fun(I) ->
		    Token0 = proplists:get_value(token, I),
		    case lists:member(Token0, Tokens) of
			true -> false;
			false -> {true, I}
		    end
		end, List0),
	    Response = s3_api:put_object(BucketId, Prefix0, ?SHARING_OPTIONS_FILENAME, term_to_binary(List1)),
	    case Response of
		{error, Reason2} -> lager:error("[sharing] Can't put object ~p/~p/~p: ~p",
						[BucketId, Prefix0, ?SHARING_OPTIONS_FILENAME, Reason2]);
		_ -> ok
	    end,
	    %% Remove lock
	    s3_api:delete_object(BucketId, PrefixedLockFilename),
	    ok;
    LockMeta ->
	%% Check for stale index
	DeltaSeconds =
	    case proplists:get_value("x-amz-meta-modified-utc", LockMeta) of
		undefined -> 0;
		T -> erlang:round(utils:timestamp()/1000) - utils:to_integer(T)
	    end,
	case DeltaSeconds > ?LOCK_INDEX_COOLOFF_TIME of
	    true ->
		s3_api:delete_object(BucketId, PrefixedLockFilename),
		delete_tokens(BucketId, Prefix0, Tokens);
	    false -> lock
	end
    end.

%%
%% Revokes sharing tokens
%%
delete_resource(Req0, State) ->
    case proplists:get_value(user, State) of
	undefined -> js_handler:unauthorized(Req0, 28);
	_ ->
	    case validate_delete(Req0, State) of
		{error, Number} ->
		    {true, Req0, [{errors, [Number]}]};
		{Req1, BucketId, Prefix, Tokens} ->
		    delete_tokens(BucketId, Prefix, Tokens),
		    {true, Req1, [{delete_result, ok}]}
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
