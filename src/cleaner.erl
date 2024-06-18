%%
%% Removes the following by schedule
%%
%% - old CSRF tokens
%% - old authentication tokens
%% - deleted objects (TODO)
%%
-module(cleaner).

-behavior(gen_server).

-export([start_link/0, get_tokens_list/3]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-include("storage.hrl").

-define(TOKENS_CLEANUP_INTERVAL, 15000).
-define(CSRF_TOKENS_CLEANUP_INTERVAL, 30000).

-record(state, {timers = []}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


init([]) ->
    {ok, {interval, Tref0}} = timer:send_interval(?TOKENS_CLEANUP_INTERVAL, tokens_cleanup),
    {ok, {interval, Tref1}} = timer:send_interval(?CSRF_TOKENS_CLEANUP_INTERVAL, csrf_tokens_cleanup),
    {ok, #state{timers=[Tref0, Tref1]}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages. This message is received by gen_server:cast() call
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Request, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages. Called by send_after() call.
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------

handle_info(tokens_cleanup, State) ->
    Tokens = get_tokens_list(?TOKEN_PREFIX, [], undefined),
    lists:foreach(
	fun(PrefixedToken) ->
	    case check_token(PrefixedToken) of
		expired -> s3_api:delete_object(?SECURITY_BUCKET_NAME, PrefixedToken);
		_ -> ok
	    end
	end, Tokens),
    {noreply, State};

handle_info(csrf_tokens_cleanup, State) ->
    Tokens = get_tokens_list(?CSRF_TOKEN_PREFIX, [], undefined),
    lists:foreach(
	fun(PrefixedToken) ->
	    UUID = filename:basename(PrefixedToken),
	    case login_handler:check_csrf_token(erlang:list_to_binary(UUID)) of
		expired -> s3_api:delete_object(?SECURITY_BUCKET_NAME, PrefixedToken);
		_ -> ok
	    end
	end, Tokens),
    {noreply, State};

handle_info(deleted_files_cleanup, State) ->
    %List0 = s3_api:recursively_list_pseudo_dir(BucketId, undefined),
    %IndexName1 = erlang:list_to_binary(?INDEX_FILENAME),
    {noreply, State};


handle_info(_Info, State) ->
    {noreply, State}.


get_tokens_list(Prefix, TokensList0, Marker0) ->
    RiakResponse = s3_api:list_objects(?SECURITY_BUCKET_NAME, [{prefix, Prefix}, {marker, Marker0}]),
    case RiakResponse of
	not_found -> [];  %% bucket not found
	_ ->
	    Contents = proplists:get_value(contents, RiakResponse),
	    Marker1 = proplists:get_value(next_marker, RiakResponse),
	    TokensList1 = [proplists:get_value(key, R) || R <- Contents],
	    case Marker1 of
		undefined -> TokensList0 ++ TokensList1;
		[] -> TokensList0 ++ TokensList1;
		NextMarker -> get_tokens_list(Prefix, TokensList0 ++ TokensList1, NextMarker)
	    end
    end.


check_token(PrefixedToken) when erlang:is_list(PrefixedToken) ->
    case s3_api:get_object(?SECURITY_BUCKET_NAME, PrefixedToken) of
	{error, _Reason} -> not_found;
	not_found -> not_found;
	TokenObject ->
	    %% Check for error in response first
	    XMLDocument0 = utils:to_list(proplists:get_value(content, TokenObject)),
	    {RootElement0, _} = xmerl_scan:string(XMLDocument0),
	    case string:str(XMLDocument0, "<Error><Code>") of
		0 ->
		    ExpirationTime0 = erlcloud_xml:get_text("/auth/token/expires", RootElement0),
		    ExpirationTime1 = utils:to_integer(ExpirationTime0),
		    case utils:timestamp() - ExpirationTime1 < 0 of
			false -> expired;
			true -> ok
		    end;
		_ -> ok
	    end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, #state{timers = Timers} = _State) ->
    %% Cancel timers
    lists:all(
	fun(Timer) ->
	    erlang:cancel_timer(Timer)
	end, Timers),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
