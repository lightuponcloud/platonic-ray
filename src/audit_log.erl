%%
%% This server caches audit log records and updates contents of audit log.
%%
-module(audit_log).
-behaviour(gen_server).

%% API
-export([start_link/0, log_operation/6]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-include("log.hrl").
-include("storage.hrl").
-include("entities.hrl").

%% In order to prevent memory pressure from very active tenants and to reduce load on object storage for quiet ones,
%% we flush logs to S3 every 2 minutes OR 30 seconds if worker is busy
-define(INTERNAL_LOG_FLUSH_INTERVAL_SHORT, 30000).  % 30 seconds in ms ( this is retry timeout )
-define(INTERNAL_LOG_FLUSH_INTERVAL_LONG, 120000).  % 2 minutes in ms
-define(INTERNAL_LOG_FLUSH_THRESHOLD_COUNT, 1000).  % Maximum number of logs before forced flush

%%
%% log_queue -- List of log records for audit log.
%%
-record(state, {log_queue = [], update_timer = undefined, flushing = false}).


-spec log_operation(
	BucketId :: string(),
	Prefix :: string(),
	OperationName :: atom(),
	Status :: list(),
	ObjectKeys :: list(),
	Context :: list()) -> ok.
log_operation(BucketId, Prefix, OperationName, Status, ObjectKeys, Context)
	when erlang:is_list(BucketId) andalso erlang:is_list(Prefix) orelse Prefix =:= undefined andalso
	erlang:is_atom(OperationName) andalso erlang:is_list(Status) andalso 
	erlang:is_list(ObjectKeys) ->
    Timestamp = calendar:now_to_universal_time(os:timestamp()),
    gen_server:cast(?MODULE, {log, BucketId, Prefix, OperationName, Status, ObjectKeys, Context, Timestamp}).


%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    {ok, Tref0} = timer:send_after(?INTERNAL_LOG_FLUSH_INTERVAL_LONG, flush_audit_log),
    {ok, #state{update_timer = Tref0, log_queue = [], flushing = false}}.


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
    Reply = ok,
    {reply, Reply, State}.

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
handle_cast({log, BucketId, Prefix, OperationName, Status, ObjectKeys, Context, Timestamp},
            #state{log_queue = LogQueue0, update_timer = Tref0} = State0) ->
    %% Adds log records to queue
    LogQueue1 =
        case proplists:is_defined(BucketId, LogQueue0) of
            false ->
                %% Add new bucket to queue
                BQ0 = [{BucketId, [{Prefix, OperationName, Status, ObjectKeys, Context, Timestamp}]}],
                LogQueue0 ++ BQ0;
            true ->
                %% Add to existing bucket in queue
                lists:map(
                    fun(I) ->
                        case element(1, I) of
                            BucketId ->
                                BQ1 = element(2, I),
                                {BucketId, BQ1 ++ [{Prefix, OperationName, Status, ObjectKeys, Context, Timestamp}]};
                            _ -> I
                        end
                    end, LogQueue0)
        end,

    QueueSize = lists:foldl(
        fun({_BucketId, BucketEntries}, Acc) ->
            Acc + length(BucketEntries)
        end, 0, LogQueue1),

    %% Determine if we need to flush immediately due to threshold
    case QueueSize >= ?INTERNAL_LOG_FLUSH_THRESHOLD_COUNT of
	true ->
	    %% Cancel existing timer
	    timer:cancel(Tref0),

	    %% Start a new long timer
	    {ok, Tref1} = timer:send_after(?INTERNAL_LOG_FLUSH_INTERVAL_LONG, flush_audit_log),

	    %% Flush logs immediately:
	    erlang:send_after(0, self(), flush_audit_log),

	    State1 = State0#state{log_queue = LogQueue1, update_timer = Tref1},
	    {noreply, State1};
	false ->
	    %% Just update the queue
	    {noreply, State0#state{log_queue = LogQueue1}}
    end.

handle_info(flush_audit_log, #state{flushing = true} = State) ->
    %% Already flushing, reschedule check to avoid concurrent flushes
    {ok, Tref} = timer:send_after(?INTERNAL_LOG_FLUSH_INTERVAL_SHORT, flush_audit_log),
    {noreply, State#state{update_timer = Tref}};

handle_info(flush_audit_log, #state{log_queue = LogQueue, flushing = false} = State) ->

    QueueSize = lists:foldl(
        fun({_BucketId, BucketEntries}, Acc) ->
            Acc + length(BucketEntries)
        end, 0, LogQueue),
    case QueueSize of
	0 ->
	    %% Nothing to do, schedule next check
	    {ok, Tref1} = timer:send_after(?INTERNAL_LOG_FLUSH_INTERVAL_LONG, flush_audit_log),
	    {noreply, State#state{update_timer = Tref1}};
	_ ->
            %% Start flushing in a separate process to avoid blocking
	    self() ! {start_async_flush},
	    {ok, Tref1} = timer:send_after(?INTERNAL_LOG_FLUSH_INTERVAL_LONG, flush_audit_log),
	    {noreply, State#state{update_timer = Tref1, flushing = true}}
    end;

handle_info({start_async_flush}, #state{log_queue = LogQueue} = State) ->
    %% Spawn process to handle the flush
    spawn_link(fun() ->
	%% Process flush outside the gen_server process
	%% Process each bucket's logs, but only if the bucket queue is not empty
	lists:foreach(
	    fun({BucketId, BucketEntries}) ->
		case BucketEntries of
		    [] -> ok;
		    _ ->
			%% Group entries by prefix/directory for efficient writing
			EntriesByPrefix = lists:foldl(
			    fun({Prefix, OperationName, Status, ObjectKeys, Context, Timestamp}, Acc) ->
				PrefixEntries = maps:get(Prefix, Acc, []),
				maps:put(Prefix,
				    PrefixEntries ++ [{OperationName, Status, ObjectKeys, Context, Timestamp}],
				    Acc)
			    end, #{}, BucketEntries),
			%% Write each group to appropriate S3 path
			maps:foreach(
			    fun(Prefix, Entries) ->
				log_operation(BucketId, Prefix, Entries)
			    end, EntriesByPrefix)
		end
	    end, LogQueue),
	%% Signal completion
	self() ! {flush_completed, LogQueue}
    end),

    %% Immediately clear the queue for new additions
    {noreply, State#state{log_queue = []}};

handle_info({flush_completed, _FlushedQueue}, State) ->
    %% Flush operation finished
    {noreply, State#state{flushing = false}}.


log_operation(BucketId, Prefix, Entries) ->
    Version = utils:get_server_version(middleware),
    ManifestPath = utils:to_binary(io_lib:format("~s.json", [EventId])),
    JSONEntries = lists:map(
	fun({OperationName, Status, ObjectKeys, Context, Timestamp}) ->
	    EventId = crypto_utils:uuid4(),
	    IncludedObjectKeys =
		case length(ObjectKeys) < 100 of
		    true -> ObjectKeys;  %% Include keys directly if reasonable
		    false -> null        %% Otherwise omit
		end,
	    DateTime = utils:to_binary(iso_8601_basic_time(Timestamp)),
	    Entry = [
		{event_id, EventId},
		{version, utils:to_binary(Version)},
		{timestamp, DateTime},
		{severity, <<"info">>},
		{facility, <<"user">>},
		{message, utils:to_binary(io_lib:format("~s on ~B objects", [OperationName, length(ObjectKeys)]))},
		{operation_name, utils:to_binary(OperationName)},
		{operation, [
		    {status, Status},
		    {status_code, proplists:get_value(status_code, Context, 200)},
		    {request_id, proplists:get_value(request_id, Context, null)},
		    {time_to_response_ns, proplists:get_value(time_to_response_ns, Context, null)}
		]},
		{object_keys, IncludedObjectKeys},
		{object_count, length(ObjectKeys)},
		{user_id, proplists:get_value(user_id, Context, null)},
		{actor, proplists:get_value(actor, Context, null)},
		{environment, proplists:get_value(environment, Context, null)},
		{compliance_metadata, proplists:get_value(compliance_metadata, Context, null)},
	    ],
	    ManifestPath =
		%% Create detailed manifest if object count is large
		case length(ObjectKeys) >= 100 of
		    true ->
			Path = utils:to_binary(io_lib:format("~s.json", [EventId])),
			Manifest = [
			    {operation_id, EventId},
			    {operation_name, OperationName},
			    {timestamp, DateTime},
			    {object_keys, ObjectKeys}
			],
			ManifestJSON = jsx:encode(Manifest),
			Options = [{meta, [{"md5", crypto_utils:md5(ManifestJSON)}]}],
			Response0 = s3_api:put_object(?SECURITY_BUCKET_NAME, ?AUDIT_LOG_PREFIX ++ "/manifests",
			    io_lib:format("~s.json", [EventId]), ManifestJSON, Options),
			case Response0 of
			    {error, Reason0} -> lager:error("[audit_log] Can't save manifest ~p/~p/~p: ~p",
							    [?SECURITY_BUCKET_NAME, ?AUDIT_LOG_PREFIX ++ "/manifests",
							     io_lib:format("~s.json", [EventId]), Reason0]);
			    _ -> ok
			end;
		    false -> null
		end,
	    <<(jsx:encode(Entry ++ [{manifest_path, ManifestPath}]))/binary, "\n">>
	end, Entries),

	Output = iolist_to_binary(JSONEntries),

	Bits = string:tokens(BucketId, "-"),
	BucketTenantId = string:to_lower(lists:nth(2, Bits)),
	LogPath0 = io_lib:format("~s/buckets/tenant-~s", [?AUDIT_LOG_PREFIX, BucketTenantId]),
	LogPath1 = io_lib:format("~s/~4.10.0B/~2.10.0B/~2.10.0B.jsonl",
	    [utils:prefixed_object_key(LogPath0, Prefix), Year, Month, Day]),
	%% Append to existing log if exists
	case s3_api:head_object(?SECURITY_BUCKET_NAME, LogPath1) of
	    {error, Reason1} ->
		lager:error("[audit_log] head_object error ~p/~p: ~p", [?SECURITY_BUCKET_NAME, LogPath1, Reason1]);
	    not_found ->
		%% Create a new log object
		Response1 = s3_api:put_object(?SECURITY_BUCKET_NAME, LogPath1,
		    io_lib:format("~s.json", [EventId]), Output, [{meta, [{"md5", crypto_utils:md5(Output)}]}]),
		case Response1 of
		    {error, Reason2} -> lager:error("[audit_log] Can't put object ~p/~p: ~p",
						    [?SECURITY_BUCKET_NAME, LogPath1, Reason2]);
		    _ -> ok
		end
	    _ ->
		%% Append to existing object
		case s3_api:get_object(?SECURITY_BUCKET_NAME, LogPath1) of
		    {error, Reason3} ->
			lager:error("[audit_log] get_object error ~p/~p: ~p", [?SECURITY_BUCKET_NAME, LogPath1, Reason3]);
		    not_found ->
			lager:error("[audit_log] get_object ~p/~p: not_found", [?SECURITY_BUCKET_NAME, LogPath1]);
		    Response2 ->
			CurrentContent = proplists:get_value(content, Response2),
			NewContent = <<CurrentContent/binary, "\n", Output/binary>>,
			Response3 = s3_api:put_object(?SECURITY_BUCKET_NAME, LogPath1,
						      [{meta, [{"md5", crypto_utils:md5(NewContent)}]}]),
			case Response3 of
			    {error, Reason4} -> lager:error("[audit_log] Can't put object ~p/~p: ~p",
							    [?SECURITY_BUCKET_NAME, LogPath1, Reason4]);
			    _ -> ok
			end
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
terminate(_Reason, #state{update_timer = Timer} = _State) ->
    case Timer of
	undefined -> ok;
	_ ->
	    erlang:cancel_timer(Timer),
	    ok
    end.


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
