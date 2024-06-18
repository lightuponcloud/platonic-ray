-module(sharing).

-export([add_sharing_token/3]).

-include("storage.hrl").

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
%% Adds sharing token for pseudo-directory.
%% Later that token will be compared with user-provided token, to decide whether to grant access or not.
%%
add_sharing_token(BucketId, Prefix0, User) ->
    Timestamp = erlang:round(utils:timestamp()/1000),

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
	    List1 = List0 ++ [{shared_by, admin_users_handler:user_to_proplist(User)}, {created_utc, Timestamp}, {token, Token}],

	    Response = s3_api:put_object(BucketId, Prefix0, ?SHARING_OPTIONS_FILENAME, term_to_binary(List1), []),
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
		    add_sharing_token(BucketId, Prefix0, User);
		false -> lock
	    end
    end.
