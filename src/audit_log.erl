%%
%% Caches audit log records in memory and periodically flushes them to S3 storage.
%% It supports rate-limited logging per bucket and provides resilience by retrying failed flushes.
%% The server triggers flushes either periodically or based on queue size thresholds 
%% Log records include rich metadata and, when large, are supplemented with manifest files stored separately in S3.
%%
-module(audit_log).
-behaviour(gen_server).

%% API
-export([start_link/0, log_operation/6, compress_data/1, decompress_data/1]).

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

%% Rate limiting parameters (per bucket)
-define(LOG_RECORDS_PER_SECOND, 100).  % 100 logs per second per bucket
-define(BUCKET_CAPACITY, 1000).   % Max tokens in bucket

%%
%% State record
%% - failed_queue: Stores entries that failed to flush for retry
%% - flush_ref: Reference to monitor the async flush process
%% - rate_limits: Map of {BucketId, {Tokens, LastRefill}} for rate limiting
%%
-record(state, {
    update_timer = undefined,
    flushing = false,
    flush_ref = undefined,
    failed_queue = [],
    rate_limits = #{}
}).

-spec log_operation(
        BucketId :: string(),
        Prefix :: string(),
        OperationName :: atom(),
        Status :: list(),
        ObjectKeys :: list(),
        Context :: list()) -> ok | {error, rate_limit_exceeded}.
log_operation(BucketId, Prefix, OperationName, Status, ObjectKeys, Context)
        when erlang:is_list(BucketId) andalso (erlang:is_list(Prefix) orelse Prefix =:= undefined) andalso
             erlang:is_atom(OperationName) andalso (erlang:is_list(Status) orelse erlang:is_integer(Status)) andalso
             erlang:is_list(ObjectKeys) ->
    Timestamp = calendar:now_to_universal_time(os:timestamp()),
    gen_server:cast(?MODULE, {log, BucketId, Prefix, OperationName, Status, ObjectKeys, Context, Timestamp}).

%%
%% Function for compressing and decompressing single file.
%%
compress_data(Data) ->
    Z = zlib:open(),
    zlib:deflateInit(Z, default, deflated, 31, 8, default),  %% 31 -- Gzip header
    Compressed = zlib:deflate(Z, Data, finish),
    zlib:deflateEnd(Z),
    zlib:close(Z),
    iolist_to_binary(Compressed).

decompress_data(CompressedData) ->
    Z = zlib:open(),
    zlib:inflateInit(Z, 31),
    Decompressed = zlib:inflate(Z, CompressedData),
    zlib:inflateEnd(Z),
    zlib:close(Z),
    iolist_to_binary(Decompressed).

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
    {ok, Tref} = timer:send_interval(?INTERNAL_LOG_FLUSH_INTERVAL_LONG, flush_audit_log),
    {ok, #state{
        update_timer = Tref,
        flushing = false,
        flush_ref = undefined,
        failed_queue = [],
        rate_limits = #{}
    }}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {noreply, State} |
%%                                   {stop, Reason, Reply, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({log, BucketId, Prefix, OperationName, Status, ObjectKeys, Context, Timestamp},
            #state{flushing = Flushing, rate_limits = RateLimits} = State) ->
    %% Rate limiting: Check if the bucket can log
    case check_rate_limit(BucketId, RateLimits) of
        {ok, NewRateLimits} ->
            %% Log to light_ets
            light_ets:log_operation(
                audit_log,
                {BucketId, Prefix, OperationName, Status, ObjectKeys, Context, Timestamp}
            ),
            %% Check queue size and trigger flush if needed
            QueueSize = light_ets:get_queue_size(audit_log),
            case QueueSize >= ?INTERNAL_LOG_FLUSH_THRESHOLD_COUNT of
                true when not Flushing ->
                    %% Trigger immediate flush
                    self() ! flush_audit_log,
                    {noreply, State#state{rate_limits = NewRateLimits}};
                true ->
                    %% Flush in progress, schedule retry with short interval
                    erlang:send_after(?INTERNAL_LOG_FLUSH_INTERVAL_SHORT, self(), flush_audit_log),
                    {noreply, State#state{rate_limits = NewRateLimits}};
                false ->
                    {noreply, State#state{rate_limits = NewRateLimits}}
            end;
        {error, rate_limit_exceeded} ->
            lager:warning("[audit_log] Rate limit exceeded for bucket ~p", [BucketId]),
            {noreply, State}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling info messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(flush_audit_log, #state{flushing = true} = State) ->
    %% Already flushing, rely on short-interval retry or next periodic flush
    {noreply, State};

handle_info(flush_audit_log, #state{flushing = false, failed_queue = FailedQueue} = State) ->
    QueueSize = light_ets:get_queue_size(audit_log),
    case QueueSize > 0 orelse FailedQueue =/= [] of
        true ->
            %% Start async flush with monitoring
            Parent = self(),
            {_Pid, Ref} = erlang:spawn_monitor(fun() ->
                Result = flush_to_s3(FailedQueue),
                Parent ! {flush_completed, self(), Result}
            end),
            {noreply, State#state{flushing = true, flush_ref = Ref}};
        false ->
            {noreply, State}
    end;

handle_info({flush_completed, _Pid, Result}, #state{flush_ref = Ref} = State) ->
    %% Handle flush completion
    erlang:demonitor(Ref, [flush]),
    case Result of
        {ok, FailedEntries} ->
            {noreply, State#state{flushing = false, flush_ref = undefined, failed_queue = FailedEntries}};
        {error, FailedEntries} ->
            lager:error("[audit_log] Flush failed, preserving ~p entries", [length(FailedEntries)]),
            {noreply, State#state{
                flushing = false,
                flush_ref = undefined,
                failed_queue = FailedEntries ++ State#state.failed_queue
            }}
    end;

handle_info({'DOWN', Ref, process, _Pid, Reason}, #state{flush_ref = Ref} = State) ->
    %% Flush process crashed
    lager:error("[audit_log] Flush process crashed: ~p", [Reason]),
    {noreply, State#state{flushing = false, flush_ref = undefined}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, #state{update_timer = Timer} = _State) ->
    case Timer of
        undefined -> ok;
        _ -> timer:cancel(Timer)
    end,
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

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% Flush logs to S3
flush_to_s3(FailedQueue) ->
    %% Retrieve logs from light_ets
    LogQueue = case ets:lookup(log_queue, audit_log) of
        [] -> [];
        [{audit_log, Entries}] ->
            %% Clear the ETS table
            ets:insert(log_queue, {audit_log, []}),
            [{BucketId, Entries} || {_, {BucketId, _Prefix, _Op, _Status, _Keys, _Context, _Ts}} = _Entry <- Entries]
    end,
    AllEntries = FailedQueue ++ LogQueue,
    case AllEntries of
        [] -> {ok, []};
        _ ->
            try
                Failed = lists:foldl(
                    fun({BucketId, BucketEntries}, Acc) ->
                        case BucketEntries of
                            [] -> Acc;
                            _ ->
                                %% Group entries by prefix
                                EntriesByPrefix = lists:foldl(
                                    fun({_, Prefix, OperationName, Status, ObjectKeys, Context, Timestamp}, Map) ->
                                        PrefixEntries = maps:get(Prefix, Map, []),
                                        maps:put(Prefix,
                                                 PrefixEntries ++ [{OperationName, Status, ObjectKeys, Context, Timestamp}],
                                                 Map)
                                    end, #{}, BucketEntries),
                                %% Process each prefix
                                maps:fold(
                                    fun(Prefix, Entries, Acc2) ->
                                        case log_to_s3(BucketId, Prefix, Entries) of
                                            ok -> Acc2;
                                            {error, _} -> [{BucketId, Entries} | Acc2]
                                        end
                                    end, Acc, EntriesByPrefix)
                        end
                    end, [], AllEntries),
                {ok, Failed}
            catch
                Class:Reason ->
                    lager:error("[audit_log] Flush failed: ~p:~p", [Class, Reason]),
                    {error, AllEntries}
            end
    end.


%% Write log entries to S3
log_to_s3(BucketId, Prefix, Entries) ->
    Version = utils:get_server_version(middleware),
    EventId = crypto_utils:uuid4(),
    %% Batch encode entries as a single JSON array
    JSONEntries = [
        begin
            IncludedObjectKeys = case length(ObjectKeys) < 100 of
                true -> ObjectKeys;
                false -> null
            end,
            DateTime = utils:to_binary(crypto_utils:iso_8601_basic_time(Timestamp)),
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
                {compliance_metadata, proplists:get_value(compliance_metadata, Context, null)}
            ],
            ManifestPath = case length(ObjectKeys) >= 100 of
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
                    case s3_api:retry_s3_operation(
                        fun() ->
                            s3_api:put_object(?SECURITY_BUCKET_NAME, ?AUDIT_LOG_PREFIX ++ "/manifests",
                                              io_lib:format("~s.json", [EventId]), ManifestJSON, Options)
                        end,
                        ?S3_RETRY_COUNT,
                        ?S3_BASE_DELAY_MS
                    ) of
                        {error, Reason} ->
                            lager:error("[audit_log] Can't save manifest ~p/~p/~p: ~p",
                                        [?SECURITY_BUCKET_NAME, ?AUDIT_LOG_PREFIX ++ "/manifests",
                                         io_lib:format("~s.json", [EventId]), Reason]),
                            null;
                        _ -> Path
                    end;
                false -> null
            end,
            Entry ++ [{manifest_path, ManifestPath}]
        end || {OperationName, Status, ObjectKeys, Context, Timestamp} <- Entries
    ],
    Output = iolist_to_binary([jsx:encode(JSONEntries), "\n"]),
    {{Year, Month, Day}, {_H, _M, _S}} = calendar:now_to_universal_time(os:timestamp()),
    Bits = string:tokens(BucketId, "-"),
    TenantId = string:to_lower(lists:nth(2, Bits)),
    LogPath = io_lib:format("~s/~s/buckets/~s/~4.10.0B/~2.10.0B/~2.10.0B_~s.jsonl.gz",
	[?AUDIT_LOG_PREFIX, TenantId, utils:prefixed_object_key(BucketId, Prefix), Year, Month, Day, EventId]),

    CompressedOutput = compress_data(Output),
    %% Write new object
    Response = s3_api:retry_s3_operation(
        fun() ->
            s3_api:put_object(
                ?SECURITY_BUCKET_NAME,
                LogPath,
                CompressedOutput,
                [{meta, [{"md5", crypto_utils:md5(Output)}]}]
            )
        end,
        ?S3_RETRY_COUNT,
        ?S3_BASE_DELAY_MS
    ),
    case Response of
        {error, Reason} ->
            lager:error("[audit_log] Can't put object ~p/~p: ~p", [?SECURITY_BUCKET_NAME, LogPath, Reason]),
            {error, Reason};
        _ -> ok
    end.

%% Rate limiting using token bucket algorithm
check_rate_limit(BucketId, RateLimits) ->
    Now = erlang:monotonic_time(second),
    case maps:get(BucketId, RateLimits, undefined) of
        undefined ->
            %% Initialize bucket with full tokens
            NewRateLimits = maps:put(BucketId, {?BUCKET_CAPACITY, Now}, RateLimits),
            {ok, NewRateLimits};
        {Tokens, LastRefill} ->
            %% Refill tokens based on elapsed time
            Elapsed = Now - LastRefill,
            NewTokens = min(?BUCKET_CAPACITY, Tokens + Elapsed * ?LOG_RECORDS_PER_SECOND),
            case NewTokens >= 1 of
                true ->
                    %% Consume one token
                    NewRateLimits = maps:put(BucketId, {NewTokens - 1, Now}, RateLimits),
                    {ok, NewRateLimits};
                false ->
                    {error, rate_limit_exceeded}
            end
    end.
