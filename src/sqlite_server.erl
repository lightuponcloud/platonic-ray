%%
%% This server updates contents of sqlite databases.
%%
%% - DB with action log, which stores history of actions.
%%   It is stored in separate file for speed of read / write.
%%
%% - DB containing tree of filesystem on client side.
%%   Server and client databases can be compared by client app using that DB.
%%
-module(sqlite_server).

-behaviour(gen_server).

%% API
-export([start_link/0, create_pseudo_directory/4, delete_pseudo_directory/4,
	 lock_object/4, add_object/3, delete_object/3, rename_object/5,
	 rename_pseudo_directory/4, task_create_pseudo_directory/4,
	 task_exec_sql/2, add_action_log_record/3, exec_sql/3]).

-export([integrity_check/2]).

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

-define(INTERNAL_DB_UPDATE_INTERVAL, 1000).  %% 1 second -- db updated every 1 second, if there were changes

%%
%% sync_sql_queue -- List of queued SQL statements for storing in sync DB.
%% log_sql_queue -- List of SQL queries for action log DB.
%%
-record(state, {sync_sql_queue = [], log_sql_queue = [], update_db_timer = []}).


-spec(create_pseudo_directory(BucketId :: string(), Prefix :: string(),
			      Name :: string(), User :: #user{}) -> ok).
create_pseudo_directory(BucketId, Prefix, Name, User)
	when erlang:is_list(BucketId) andalso erlang:is_list(Prefix) orelse Prefix =:= undefined
	    andalso erlang:is_binary(Name) ->
    gen_server:cast(?MODULE, {add_task, BucketId, ?MODULE, task_create_pseudo_directory, [Prefix, Name, User]}).

-spec(rename_pseudo_directory(BucketId :: string(), Prefix :: string(),
			      SrcKey :: string(), DstName :: binary()) -> ok).
rename_pseudo_directory(BucketId, Prefix, SrcKey, DstName)
	when erlang:is_list(BucketId) andalso erlang:is_list(Prefix) orelse Prefix =:= undefined
	    andalso erlang:is_list(SrcKey) andalso erlang:is_binary(DstName) ->
    gen_server:cast(?MODULE, {add_task, BucketId, sql_lib, rename_pseudo_directory, [Prefix, SrcKey, DstName]}).

%%
%% Mark directory as deleted in SQLite db
%%
-spec(delete_pseudo_directory(BucketId :: string(), Prefix :: string(),
			      Name :: binary(), UserId :: string() ) -> ok).
delete_pseudo_directory(BucketId, Prefix, Name, UserId)
	when erlang:is_list(BucketId) andalso erlang:is_list(Prefix) orelse Prefix =:= undefined
	    andalso erlang:is_binary(Name) andalso erlang:is_list(UserId) ->
    gen_server:cast(?MODULE, {add_task, BucketId, sql_lib, delete_pseudo_directory, [Prefix, Name]}).

-spec(add_object(BucketId :: string(), Prefix :: string(), Obj :: #object{}) -> ok).
add_object(BucketId, Prefix, Obj) when erlang:is_list(BucketId) andalso
	    erlang:is_list(Prefix) orelse Prefix =:= undefined ->
    gen_server:cast(?MODULE, {add_task, BucketId, sql_lib, add_object, [Prefix, Obj]}).


-spec(rename_object(BucketId :: string(), Prefix :: string(), SrcKey :: string(),
		    DstKey :: string(), DstName :: binary()) -> ok).
rename_object(BucketId, Prefix, SrcKey, DstKey, DstName) when erlang:is_list(BucketId) andalso
	    erlang:is_list(Prefix) orelse Prefix =:= undefined andalso erlang:is_list(SrcKey)
	    andalso erlang:is_list(DstKey) andalso erlang:is_binary(DstName) ->
    gen_server:cast(?MODULE, {add_task, BucketId, sql_lib, rename_object,
		    [Prefix, SrcKey, DstKey, DstName]}).


-spec(lock_object(BucketId :: string(), Prefix :: string(), Key :: string(), Value :: boolean()) -> ok).
lock_object(BucketId, Prefix, Key, Value) ->
    gen_server:cast(?MODULE, {add_task, BucketId, sql_lib, lock_object, [Prefix, Key, Value]}).


-spec(delete_object(BucketId :: string(), Prefix :: string(), Key :: string()) -> ok).
delete_object(BucketId, Prefix, Key)
	when erlang:is_list(BucketId) andalso erlang:is_list(Prefix) orelse Prefix =:= undefined
	    andalso erlang:is_list(Key) ->
    gen_server:cast(?MODULE, {add_task, BucketId, sql_lib, delete_object, [Prefix, Key]}).


%%-spec(add_action_log_record(BucketId :: string(), Prefix :: string(), Record :: #action_log_record{}) -> ok).
add_action_log_record(BucketId, Prefix, Record) ->
    gen_server:cast(?MODULE, {add_task, BucketId, Prefix, sql_lib, add_action_log_record, [Record]}).

%%
%% Allows combining two SQLs into one call.
%%
exec_sql(BucketId, SQL0, SQL1) ->
    gen_server:cast(?MODULE, {add_task, BucketId, ?MODULE, task_exec_sql, [SQL0, SQL1]}).


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
    {ok, Tref0} = timer:send_after(?INTERNAL_DB_UPDATE_INTERVAL, update_db),
    {ok, #state{update_db_timer = Tref0}}.


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
handle_cast({add_task, BucketId, Module, Func, Args}, #state{sync_sql_queue = SyncSqlQueue0} = State0) ->
    %% Adds records for periodic task processor of sync DB
    SyncSqlQueue1 =
	case proplists:is_defined(BucketId, SyncSqlQueue0) of
	    false ->
		%% Add to queue
		BQ0 = [{BucketId, [{Module, Func, Args}]}],
		SyncSqlQueue0 ++ BQ0;
	    true ->
		%% Change bucket queue
		lists:map(
		    fun(I) ->
			case element(1, I) of
			    BucketId ->
				BQ1 = element(2, I),
				{BucketId, BQ1 ++ [{Module, Func, Args}]};
			    _ -> I
			end
		    end, SyncSqlQueue0)
	end,
    {noreply, State0#state{sync_sql_queue = SyncSqlQueue1}};

handle_cast({add_task, BucketId, Prefix, Module, Func, Args}, #state{log_sql_queue = LogSqlQueue0} = State0) ->
    %% Adds records for periodic task processor of action log DB
    LogSqlQueue1 =
	case proplists:is_defined({BucketId, Prefix}, LogSqlQueue0) of
	    false ->
		%% Add to queue
		BQ2 = [{{BucketId, Prefix}, [{Module, Func, Args}]}],
		LogSqlQueue0 ++ BQ2;
	    true ->
		%% Change bucket queue
		lists:map(
		    fun(I) ->
			case element(1, I) of
			    {BucketId, Prefix} ->
				BQ3 = element(2, I),
				{{BucketId, Prefix}, BQ3 ++ [{Module, Func, Args}]};
			    _ -> I
			end
		    end, LogSqlQueue0)
	end,
    {noreply, State0#state{log_sql_queue = LogSqlQueue1}}.

%%
%% Adds pseudo-directory in SQLite db, if it do not exist yet
%%
task_create_pseudo_directory(Prefix, Name, User, DbName) ->
    %% Check if pseudo-directory exists first
    SQL0 = sql_lib:get_pseudo_directory(Prefix, Name),
    case sqlite3:sql_exec(DbName, SQL0) of
	[{columns, _}, {rows,[_OrigName]}] ->
	    %% Pseudo-directory is in DB already
	    [];
	[{columns, _}, {rows,[]}] ->
	    %% Return SQL for creating one
	    sql_lib:create_pseudo_directory(Prefix, Name, User);
	{error,_,_} ->
	    %% Table could not exist, but still return SQL for creating pseudo-dir
	    sql_lib:create_pseudo_directory(Prefix, Name, User)
    end.

task_exec_sql(SQL0, SQL1) -> {SQL0, SQL1}.


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
handle_info(update_db, #state{sync_sql_queue = SyncSqlQueue0, log_sql_queue = LogSqlQueue0} = State) ->
    %% Go over per-bucket queues of tasks, download SQLite db files,
    %% execute SQL statements and upload DBs again
    SyncSqlQueue1 =
	lists:map(
	    fun(I) ->
		BucketId = element(1, I),
		BucketQueue0 = element(2, I),
		BucketQueue1 =
		    case length(BucketQueue0) of
			0 -> [];  %% do nothing, try later
			_ ->
			    %% Acquire lock on db first
			    case lock_db(BucketId, ?DB_VERSION_LOCK_FILENAME) of
				ok -> update_db(BucketId, BucketQueue0);
				locked ->
				    %% Skip it. The next check is in 3 seconds
				    BucketQueue0
			    end
		    end,
		{BucketId, BucketQueue1}
	    end, SyncSqlQueue0),
    LogSqlQueue1 =
	lists:filtermap(
	    fun(I) ->
		BP = element(1, I),
		BucketId = element(1, BP),
		Prefix = element(2, BP),
		BucketQueue2 = element(2, I),
		case length(BucketQueue2) of
		    0 -> false;  %% remove empty entry from SQL queue
		    _ ->
			%% Update DB, but acquire the lock first
			PrefixedLockName = utils:prefixed_object_key(Prefix, ?ACTION_LOG_LOCK_FILENAME),
			case lock_db(BucketId, PrefixedLockName) of
			    ok ->
				BucketQueue3 = update_db(BucketId, Prefix, BucketQueue2),
				{true, {{BucketId, Prefix}, BucketQueue3}};
			    locked ->
				%% Skip it. The next check is in 3 seconds
				{true, {{BucketId, Prefix}, BucketQueue2}}
			end
		end
	    end, LogSqlQueue0),

    {ok, Tref0} = timer:send_after(?INTERNAL_DB_UPDATE_INTERVAL, update_db),
    {noreply, State#state{update_db_timer = Tref0, sync_sql_queue = SyncSqlQueue1, log_sql_queue = LogSqlQueue1}};

handle_info(_Info, State) ->
    {noreply, State}.

%%
%% Update file tree in SQL DB
%%
update_db(BucketId, BucketQueue0) ->
    DbName = erlang:list_to_atom(crypto_utils:random_string()),
    case open_db(BucketId, DbName) of
	{error, TempFn, _Reason} ->
	    %% leave queue as is
	    file:delete(TempFn),
	    BucketQueue0;
	{ok, TempFn, DbPid, Version0} ->
	    BucketQueue1 = lists:map(
		fun(J) ->
		    Module = element(1, J),
		    Func = element(2, J),
		    %% Add db name to arguments of calling function (in order to call multuple sql statements )
		    Args =
			case {Module, Func} of
			    {?MODULE, task_create_pseudo_directory} -> element(3, J) ++ [DbName];
			    _ -> element(3, J)
			end,
		    case erlang:function_exported(Module, Func, length(Args)) of
			true ->
			    case apply(Module, Func, Args) of
				[] -> [];
				{SQL0, SQL1} ->
				    case sqlite3:sql_exec(DbName, SQL0) of
					{error, _, Reason0} ->
					    lager:error("[sqlite_server] SQL: ~p Error: ~p", [SQL0, Reason0]),
					    {Module, Func, Args};  %% adding it back to queue
					_ ->
					    case sqlite3:sql_exec(DbName, SQL1) of
						{error, Reason1} ->
						    lager:error("[sqlite_server] SQL: ~p Error: ~p", [SQL1, Reason1]),
						    {Module, Func, Args};  %% adding it back to queue
						_ -> []
					    end
				    end;
				SQL ->
				    case sqlite3:sql_exec(DbName, SQL) of
					{error, _, Reason2} ->
					    lager:error("[sqlite_server] SQL: ~p Error: ", [SQL, Reason2]),
					    {Module, Func, Args};  %% adding it back to queue
					_Result -> []
				    end
			    end;
			false ->
			    lager:error("[sqlite_server] not exported: ~p:~p/~p~p",
				        [Module, Func, length(Args), Args]),
			    []  %% removing from queue
		    end
		end, BucketQueue0),
	    sqlite3:sql_exec(DbName, "VACUUM;"),
	    %% Read SQLitedb as file and write it to Riak CS
	    sqlite3:close(DbPid),
	    Timestamp = erlang:round(utils:timestamp()/1000),
	    Version1 = indexing:increment_version(Version0, Timestamp, []),
	    {ok, Blob} = file:read_file(TempFn),
	    RiakOptions = [{meta, [
		{"version", base64:encode(jsx:encode(Version1))},
		{"bytes", byte_size(Blob)}]}],
	    s3_api:put_object(BucketId, undefined, ?DB_VERSION_KEY, Blob, RiakOptions),
	    %% Remove lock object
	    %% remove temporary db file
	    s3_api:delete_object(BucketId, ?DB_VERSION_LOCK_FILENAME),
	    file:delete(TempFn),

	    %% Send notification to bucket subscribers
	    AtomicId = erlang:binary_to_list(crypto_utils:uuid4()),
	    Msg = jsx:encode([{version, Version1}, {bucket_id, erlang:list_to_binary(BucketId)},
			      {timestamp, Timestamp}]),
	    events_server_sup:send_message(BucketId, AtomicId, Msg),

	    lists:flatten(BucketQueue1)
    end.

%%
%% Update Action Log in SQL DB
%%
update_db(BucketId, Prefix, BucketQueue0) ->
    DbName = erlang:list_to_atom(crypto_utils:random_string()),
    case open_db(BucketId, Prefix, DbName) of
	{error, TempFn, _Reason} ->
	    %% leave queue as is
	    file:delete(TempFn),
	    BucketQueue0;
	{ok, TempFn, DbPid} ->
	    BucketQueue1 = lists:map(
		fun(J) ->
		    Module = element(1, J),
		    Func = element(2, J),
		    Args = element(3, J),
		    case erlang:function_exported(Module, Func, length(Args)) of
			true ->
			    case apply(Module, Func, Args) of
				[] -> [];
				SQL ->
				    case sqlite3:sql_exec(DbName, SQL) of
					{error, _, Reason0} ->
					    lager:error("[sqlite_server] ~p SQL: ~p Error: ", [BucketId, SQL, Reason0]),
					    {Module, Func, Args};  %% adding it back to queue
					_Result -> []
				    end
			    end;
			false ->
			    lager:error("[sqlite_server] not exported: ~p:~p/~p~p",
				        [Module, Func, length(Args), Args]),
			    []  %% removing from queue
		    end
		end, BucketQueue0),
	    sqlite3:sql_exec(DbName, "VACUUM;"),
	    %% Read SQLitedb as file and write it to Riak CS
	    sqlite3:close(DbPid),
	    {ok, Blob} = file:read_file(TempFn),
	    RiakOptions = [{meta, [{"bytes", byte_size(Blob)}]}],
	    PrefixedDbName = utils:prefixed_object_key(Prefix, ?ACTION_LOG_FILENAME),
	    s3_api:put_object(BucketId, undefined, PrefixedDbName, Blob, RiakOptions),
	    %% Remove lock object
	    %% remove temporary db file
	    PrefixedLockName = utils:prefixed_object_key(Prefix, ?ACTION_LOG_LOCK_FILENAME),
	    s3_api:delete_object(BucketId, PrefixedLockName),
	    file:delete(TempFn),

	    lists:flatten(BucketQueue1)
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
terminate(_Reason, _State) -> ok.

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

%%
%% Checks integrity of SQLite db.
%%
%% Table or index entries that are out of sequence
%% Misformatted records
%% Missing pages
%% Missing or surplus index entries
%% UNIQUE, CHECK, and NOT NULL constraint errors
%% Integrity of the freelist
%% Sections of the database that are used more than once, or not at all
%%
integrity_check(DbName, TempFn) ->
    {ok, _Pid} = sqlite3:open(DbName, [{file, TempFn}]),
    Result = sqlite3:sql_exec(DbName, "pragma integrity_check;"),
    IsConsistent =
	case proplists:get_value(rows, Result) of
	    [{<<"ok">>}] -> true;
	    _ -> false
	end,
    sqlite3:close(DbName),
    IsConsistent.

%%
%% Read File Tree DB from Riak CS.
%%
open_db(BucketId, DbName) ->
    TempFn = utils:get_temp_path(middleware),
    case s3_api:get_object(BucketId, ?DB_VERSION_KEY) of
	{error, Reason0} ->
	    ?ERROR("[sqlite_server] Failed to read existing db: ~p~n", [Reason0]),
	    {error, TempFn, Reason0};
	not_found ->
	    %% No SQLite db found, create a new one
	    {ok, Pid0} = sqlite3:open(DbName, [{file, TempFn}]),
	    case sql_lib:create_items_table_if_not_exist(DbName) of
		ok ->
		    %% Create a new version
		    Timestamp = erlang:round(utils:timestamp()/1000),
		    Version0 = indexing:increment_version(undefined, Timestamp, []),
		    {ok, TempFn, Pid0, Version0};
		{error, Reason1} ->
		    ?ERROR("[sqlite_server] Failed to create table: ~p~n", [Reason1]),
		    {error, TempFn, Reason1}
	    end;
	Object ->
	    Content = proplists:get_value(content, Object),
	    case s3_api:head_object(BucketId, ?DB_VERSION_KEY) of
		not_found ->
		    ?ERROR("[sqlite_server] DB object suddenly disappeared~n"),
		    {error, TempFn, "DB object suddenly disappeared"};
		Metadata ->
		    case file:write_file(TempFn, Content, [write, binary]) of
			ok ->
			    %% Read db, then call exec_sql
			    {ok, Pid1} = sqlite3:open(DbName, [{file, TempFn}]),
			    %% File could be empty for some reason, so lets create table, if it do not exist
			    case sql_lib:create_items_table_if_not_exist(DbName) of
				ok ->
				    %% Create a new version
				    Timestamp = erlang:round(utils:timestamp()/1000),
				    Version0 = indexing:increment_version(undefined, Timestamp, []),
				    {ok, TempFn, Pid1, Version0};
				exists ->
				    Version1 = proplists:get_value("x-amz-meta-version", Metadata),
				    Version2 = jsx:decode(base64:decode(Version1)),
				    {ok, TempFn, Pid1, Version2};
				{error, Reason2} ->
				    ?ERROR("[sqlite_server] Failed to create table: ~p~n", [Reason2]),
				    {error, TempFn, Reason2}
			    end;
			{error, Reason3} ->
			    ?ERROR("[sqlite_server] Can't write to db file: ~p~n", [Reason3]),
			    {error, TempFn, Reason3}
		    end
	    end
    end.

%%
%% Read Action Log DB from Riak CS.
%%
open_db(BucketId, Prefix, DbName) ->
    TempFn = utils:get_temp_path(middleware),
    PrefixedDbName = utils:prefixed_object_key(Prefix, ?ACTION_LOG_FILENAME),
    case s3_api:get_object(BucketId, PrefixedDbName) of
	{error, Reason0} ->
	    ?ERROR("[sqlite_server] Failed to read existing action log db: ~p~n", [Reason0]),
	    {error, TempFn, Reason0};
	not_found ->
	    %% No SQLite db found, create a new one
	    {ok, Pid0} = sqlite3:open(DbName, [{file, TempFn}]),
	    case sql_lib:create_action_log_table_if_not_exist(DbName) of
		ok -> {ok, TempFn, Pid0};
		{error, Reason1} ->
		    ?ERROR("[sqlite_server] Failed to create table: ~p~n", [Reason1]),
		    {error, TempFn, Reason1}
	    end;
	Object ->
	    Content = proplists:get_value(content, Object),
	    case s3_api:head_object(BucketId, PrefixedDbName) of
		{error, Reason4} ->
		    ?ERROR("[sqlite_server] Can't access DB object ~p/~p: ~p~n", [BucketId, PrefixedDbName, Reason4]),
		    {error, TempFn, Reason4};
		not_found ->
		    ?ERROR("[sqlite_server] Action log DB object suddenly disappeared~n"),
		    {error, TempFn, "Action log DB object suddenly disappeared"};
		_Metadata ->
		    case file:write_file(TempFn, Content, [write, binary]) of
			ok ->
			    %% Read db, then call exec_sql
			    {ok, Pid1} = sqlite3:open(DbName, [{file, TempFn}]),
			    %% File could be empty for some reason, so lets create table, if it do not exist
			    case sql_lib:create_action_log_table_if_not_exist(DbName) of
				ok -> {ok, TempFn, Pid1};
				exists -> {ok, TempFn, Pid1};
				{error, Reason2} ->
				    ?ERROR("[sqlite_server] Failed to create table: ~p~n", [Reason2]),
				    {error, TempFn, Reason2}
			    end;
			{error, Reason3} ->
			    ?ERROR("[sqlite_server] Can't write to Action Log DB file: ~p~n", [Reason3]),
			    {error, TempFn, Reason3}
		    end
	    end
    end.

%%
%% Create lock object in Riak CS
%%
lock_db(BucketId, LockName) ->
    %% Check lock file first
    case s3_api:head_object(BucketId, LockName) of
	{error, Reason} ->
	    ?ERROR("[sqlite_server] Can't check status of lock object: ~p~n", [Reason]),
	    {error, Reason};
	not_found ->
	    %% Create lock file instantly
	    Timestamp0 = erlang:round(utils:timestamp()/1000),
	    LockMeta0 = [{"modified-utc", Timestamp0}],
	    Result0 = s3_api:put_object(BucketId, undefined, LockName, <<>>, [{meta, LockMeta0}]),
	    case Result0 of
		{error, Reason0} -> {error, Reason0};
		_ -> ok
	    end;
	IndexLockMeta ->
	    %% Check for stale index
	    Timestamp1 = erlang:round(utils:timestamp()/1000),
	    DeltaSeconds =
		case proplists:get_value("x-amz-meta-modified-utc", IndexLockMeta) of
		    undefined -> 0;
		    T -> Timestamp1 - utils:to_integer(T)
		end,
	    case DeltaSeconds > ?DB_LOCK_COOLOFF_TIME of
		true ->
		    %% Remove previous lock object, create a new one
		    case s3_api:delete_object(BucketId, LockName) of
			{error, Reason} ->
			    lager:error("Failed removing lock ~p/~p", [BucketId, LockName]),
			    {error, Reason};
			{ok, _} ->
			    LockMeta1 = [{"modified-utc", Timestamp1}],
			    Result1 = s3_api:put_object(BucketId, undefined, LockName, <<>>, [{meta, LockMeta1}]),
			    case Result1 of
				{error, Reason1} -> {error, Reason1};
				_ -> ok
			    end
		    end;
		false -> locked
	    end
    end.
