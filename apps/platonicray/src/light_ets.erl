%%
%% This server:
%% - Loads Unicode characters and MIME types into ETS tables
%% - Maintains a log queue.
%%
%% Why Not queue module:
%% 1. The large queue size risks memory pressure on the gen_server process,
%% 2. queue lacks efficient querying for potential future features.
%% 3. The check_queue operation converts the queue to a list for processing, which is O(n) and could be optimized with ETS’s select/2.
%%
-module(light_ets).

-behaviour(gen_server).

-export([start_link/0, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([to_lower/1]).
-export([guess_content_type/1]).
-export([log_operation/2]).
%% For video transcoding
-export([get_queue_size/1, enqueue_transcode/2, dequeue_transcode/1, requeue_transcode/1,
         get_transcode_queue_size/0]).
%% For websocket messaging
-export([add_subscriber/4, remove_subscriber/1, get_subscribers/0,
         get_subscribers_by_bucket/1, store_message/1, delete_message/2, get_messages_by_user/1,
         add_bucket_node/2, get_nodes_by_bucket/1, flush_logs/0]).
%% For collecting storage stats
-export([update_storage_metrics/3, get_storage_metrics/1, get_all_storage_metrics/0]).

-include_lib("common_lib/include/log.hrl").
-include_lib("common_lib/include/entities.hrl").

-define(MIME_TABLE, mime_types).
-define(UNIDATA_TABLE, unidata).
-define(LOG_QUEUE, log_queue).
-define(VIDEO_TRANSCODE_QUEUE, video_transcode_queue).
-define(SUBSCRIBERS_TABLE, subscribers).
-define(MESSAGES_TABLE, messages).
-define(BUCKET_NODES_TABLE, bucket_nodes).
-define(BUCKET_STORAGE_TABLE, bucket_storage).
-define(MAX_QUEUE_SIZE, 10_000). % From video_transcoding
-define(PMAP_WORKERS, 4).        % From video_transcoding

-record(state, {
    unidata_ets = undefined :: ets:tid() | undefined,
    mime_ets = undefined :: ets:tid() | undefined,
    log_ets = undefined :: ets:tid() | undefined,
    transcode_ets = undefined :: ets:tid() | undefined,
    subscribers_ets = undefined :: ets:tid() | undefined,
    messages_ets = undefined :: ets:tid() | undefined,
    bucket_nodes_ets = undefined :: ets:tid() | undefined,
    bucket_storage_ets = undefined :: ets:tid() | undefined
}).

%% API for existing functionality

%% Converts characters of a string to a lowercase format.
to_lower(String) when is_list(String) ->
    gen_server:call(?MODULE, {to_lower, String}).

guess_content_type(FileName) when is_list(FileName) ->
    gen_server:call(?MODULE, {mime_type, FileName}).

log_operation(Operation, Details) ->
    gen_server:cast(?MODULE, {log, Operation, Details}).

%% Get the size of the log queue from light_ets
get_queue_size(QueueName) when is_atom(QueueName) ->
    case ets:lookup(?LOG_QUEUE, QueueName) of
        [] -> 0;
        [{QueueName, Entries}] -> length(Entries)
    end.

enqueue_transcode(BucketId, ObjectKey) ->
    gen_server:cast(?MODULE, {enqueue_transcode, BucketId, ObjectKey}).

dequeue_transcode(Limit) when is_integer(Limit), Limit > 0 ->
    gen_server:call(?MODULE, {dequeue_transcode, Limit}).

requeue_transcode(Task) ->
    gen_server:cast(?MODULE, {requeue_transcode, Task}).

get_transcode_queue_size() ->
    gen_server:call(?MODULE, get_transcode_queue_size).

%% API for subscribers and messages

%% Add subscriber, if it do not exist yet
add_subscriber(UserId, Pid, SessionId, BucketIdList) when is_list(UserId), is_pid(Pid), is_list(SessionId), is_list(BucketIdList) ->
    gen_server:cast(?MODULE, {add_subscriber, UserId, Pid, SessionId, BucketIdList}).

%% Terminates user sessions on the same device and removes stale session
remove_subscriber(SessionId) when is_list(SessionId) ->
    gen_server:cast(?MODULE, {remove_subscriber, SessionId}).

get_subscribers() ->
    gen_server:call(?MODULE, get_subscribers).

get_subscribers_by_bucket(BucketId) when is_list(BucketId) ->
    gen_server:call(?MODULE, {get_subscribers_by_bucket, BucketId}).

store_message(MessageEntry) when is_record(MessageEntry, message_entry) ->
    gen_server:cast(?MODULE, {store_message, MessageEntry}).

delete_message(AtomicId, UserId) when is_list(AtomicId), is_list(UserId) ->
    gen_server:cast(?MODULE, {delete_message, AtomicId, UserId}).

get_messages_by_user(UserId) when is_list(UserId) orelse UserId =:= '_' ->
    gen_server:call(?MODULE, {get_messages_by_user, UserId}).

%% Utility Functions

hex_to_int(Code) ->
    case io_lib:fread("~16u", Code) of
        {ok, [Int], []} -> Int;
        _ -> false
    end.

-spec split(char(), string()) -> [string()].
split(Char, Str) -> lists:reverse(do_split(Char, Str, [], [])).

do_split(Char, [Char|Tail], Acc1, Acc2) ->
    do_split(Char, Tail, [], [lists:reverse(Acc1) | Acc2]);
do_split(_Char, [], Acc1, Acc2) ->
    [lists:reverse(Acc1) | Acc2];
do_split(Char, [Head|Tail], Acc1, Acc2) ->
    do_split(Char, Tail, [Head|Acc1], Acc2).

open_file(FileName) ->
    try
        {ok, Fd} = case lists:reverse(FileName) of
            "zg." ++ _List -> % is .gz?
                file:open(FileName, [read, compressed]);
            _ ->
                file:open(FileName, [read])
        end,
        Fd
    catch
        Class:Reason ->
            ?ERROR("~w: Cannot open file ~ts. ~n", [?MODULE, FileName]),
            throw(io_lib:format("Failed to open file: ~p ~p", [Class, Reason]))
    end.

parse(In) ->
    Tokens = split($;, In),
    [Code,_Comment,_Abbr,_Ccc,_,_DecompMap,_,_,_,_,_,_,_UC,LC|_] = Tokens,
    case hex_to_int(Code) of
        false -> skip;
        Char ->
            case hex_to_int(LC) of
                false -> skip;
                T ->
                    {ok, [{Char, T}]}
            end
    end.

delete_nr(Str) -> [X || X <- Str, X =/= $\n, X =/= $\r].
-spec delete_comments(string()) -> string().
delete_comments(Line) ->
    lists:reverse(do_delete_comments(Line, [])).

do_delete_comments([], Acc) -> Acc;
do_delete_comments([$# | _], Acc) -> Acc;
do_delete_comments([H|T], Acc) ->
    do_delete_comments(T, [H|Acc]).

read_file({Fd, Ets} = State) ->
    case file:read_line(Fd) of
        {ok, []} ->
            read_file(State);
        {ok, Line} ->
            case parse(delete_nr(delete_comments(Line))) of
                skip ->
                    read_file(State);
                {ok, Val} ->
                    ets:insert(Ets, Val),
                    read_file(State)
            end;
        eof -> ok
    end.

load_unicode_mapping() ->
    EbinDir = filename:dirname(code:which(?MODULE)),
    AppDir = filename:dirname(EbinDir),
    FilePath = filename:join([AppDir, "priv", "UnicodeData.txt.gz"]),
    Fd = open_file(FilePath),
    Ets = ets:new(?UNIDATA_TABLE, [named_table, public, {write_concurrency, false}, {read_concurrency, true}]),
    read_file({Fd, Ets}),
    file:close(Fd),
    Ets.

%% Add bucket_nodes ETS initialization
load_bucket_nodes_ets() ->
    ets:new(?BUCKET_NODES_TABLE, [
        bag,
        named_table,
        {write_concurrency, true},
        {read_concurrency, true},
        public
    ]).

load_mime_types() ->
    EbinDir = filename:dirname(code:which(?MODULE)),
    AppDir = filename:dirname(EbinDir),
    MimeTypesFile = filename:join([AppDir, "priv", "mime.types"]),
    {ok, MimeTypes} = httpd_conf:load_mime_types(MimeTypesFile),
    Ets = ets:new(?MIME_TABLE, [named_table, public, {write_concurrency, false}, {read_concurrency, true}]),
    [ets:insert(Ets, I) || I <- MimeTypes],
    Ets.

load_log_ets() ->
    ets:new(?LOG_QUEUE, [named_table, public, {write_concurrency, true}, {read_concurrency, true}]).

load_transcode_ets() ->
    ets:new(?VIDEO_TRANSCODE_QUEUE, [
        ordered_set,
        {write_concurrency, true},
        {read_concurrency, true},
        private
    ]).

load_subscribers_ets() ->
    ets:new(?SUBSCRIBERS_TABLE, [
        set,
        named_table,
        {write_concurrency, true},
        {read_concurrency, true},
        public
    ]).

load_messages_ets() ->
    ets:new(?MESSAGES_TABLE, [
        set,
        named_table,
        {write_concurrency, true},
        {read_concurrency, true},
        public
    ]).

load_bucket_storage_ets() ->
    ets:new(?BUCKET_STORAGE_TABLE, [
        set,
        named_table,
        {write_concurrency, true},
        {read_concurrency, true},
        public
    ]).

string_to_lower(String) ->
    pmap:pmap(
        fun(C) ->
            Key = erlang:list_to_integer(io_lib:fwrite("~B", [C])),
            case ets:lookup(?UNIDATA_TABLE, Key) of
                [] -> Key;
                [{Key, Val}] -> lists:nth(1, unicode:characters_to_list([Val]))
            end
        end, String).

update_metrics(upload, Size, {Used, Available}) ->
    {Used + Size, Available};
update_metrics(undelete, Size, {Used, Available}) ->
    {Used + Size, Available};
update_metrics(delete, Size, {Used, Available}) ->
    {Used - Size, Available};
update_metrics(copy, Size, {Used, Available}) ->
    {Used + Size, Available}; % Copy creates a new object in the same or different bucket
update_metrics(move, _Size, {Used, Available}) ->
    {Used, Available}; % Move within the same bucket doesn't change metrics
update_metrics({move, FromBucket, ToBucket}, Size, {Used, Available}) when FromBucket =/= ToBucket ->
    % Handle cross-bucket move as a remove from source and upload to destination
    {Used - Size, Available}. % This is for the source bucket; destination handled separately

%% Update storage metrics for a bucket based on operation
update_storage_metrics(BucketId, Operation, Size) when is_list(BucketId), is_atom(Operation), is_integer(Size) ->
    gen_server:cast(?MODULE, {update_storage, BucketId, Operation, Size}).

%% Get storage metrics for a specific bucket
get_storage_metrics(BucketId) when is_list(BucketId) ->
    gen_server:call(?MODULE, {get_storage_metrics, BucketId}).

%% Get storage metrics for all buckets
get_all_storage_metrics() ->
    gen_server:call(?MODULE, get_all_storage_metrics).

%% Starts the server
start_link() ->
    {ok, Pid} = gen_server:start_link({local, ?MODULE}, ?MODULE, [], []),
    % Wait for initialization to complete
    pong = gen_server:call(?MODULE, ping),
    {ok, Pid}.


add_bucket_node(BucketId, Node) when is_list(BucketId), is_atom(Node) ->
    gen_server:cast(?MODULE, {add_bucket_node, BucketId, Node}).

get_nodes_by_bucket(BucketId) when is_list(BucketId) ->
    gen_server:call(?MODULE, {get_nodes_by_bucket, BucketId}).

flush_logs() ->
    gen_server:call(?MODULE, flush_logs).

%%% gen_server callbacks
init([]) ->
    Ets0 = load_unicode_mapping(),
    Ets1 = load_mime_types(),
    Ets2 = load_log_ets(),
    Ets3 = load_transcode_ets(),
    Ets4 = load_subscribers_ets(),
    Ets5 = load_messages_ets(),
    Ets6 = load_bucket_nodes_ets(),
    Ets7 = load_bucket_storage_ets(),
    {ok, #state{
        unidata_ets = Ets0,
        mime_ets = Ets1,
        log_ets = Ets2,
        transcode_ets = Ets3,
        subscribers_ets = Ets4,
        messages_ets = Ets5,
        bucket_nodes_ets = Ets6,
        bucket_storage_ets = Ets7
    }}.

handle_call(ping, _From, State) ->
    {reply, pong, State};

handle_call({to_lower, String}, _From, State) ->
    Result = string_to_lower(String),
    {reply, Result, State};

handle_call({mime_type, FileName}, _From, State) ->
    Result =
        case filename:extension(FileName) of
            [] -> "application/octet_stream";
            Extension0 ->
                Extension1 = string_to_lower(unicode:characters_to_list(Extension0)),
                case Extension1 of
                    ".heic" -> "image/heic";
                    _ ->
                        LookupKey = string:substr(Extension1, 2),
                        case ets:lookup(?MIME_TABLE, LookupKey) of
                            [] -> "application/octet_stream";
                            [{_Key, Val}] -> Val
                        end
                end
        end,
    {reply, Result, State};

handle_call({dequeue_transcode, Limit}, _From, #state{transcode_ets = Ets} = State) ->
    Items = ets:select(Ets, [{{'$1', '$2'}, [], ['$2']}], Limit),
    case Items of
        {[], _} ->
            {reply, [], State};
        {Batch, _Cont} ->
            [ets:delete(Ets, Seq) || {Seq, _} <- Batch],
            {reply, Batch, State}
    end;

handle_call(get_transcode_queue_size, _From, #state{transcode_ets = Ets} = State) ->
    Size = ets:info(Ets, size),
    {reply, Size, State};

handle_call(get_subscribers, _From, #state{subscribers_ets = Ets} = State) ->
    Subscribers = ets:tab2list(Ets),
    {reply, Subscribers, State};

handle_call({get_subscribers_by_bucket, BucketId}, _From, #state{subscribers_ets = Ets} = State) ->
    Subscribers = ets:match_object(Ets, {'$1', '$2', '$3', '$4'}),
    Filtered = [S || S <- Subscribers, lists:member(BucketId, element(4, S))],
    {reply, Filtered, State};

handle_call({get_messages_by_user, '_'}, _From, #state{messages_ets = Ets} = State) ->
    Messages = ets:tab2list(Ets),
    {reply, Messages, State};
handle_call({get_messages_by_user, UserId}, _From, #state{messages_ets = Ets} = State) ->
    Messages = ets:match_object(Ets, {'$1', #message_entry{user_id = UserId, _ = '_'}}),
    {reply, Messages, State};

handle_call({get_nodes_by_bucket, BucketId}, _From, State) ->
    Nodes = lists:usort([Node || {_, Node} <- ets:lookup(?BUCKET_NODES_TABLE, BucketId)]),
    {reply, Nodes, State};

handle_call(flush_logs, _From, State) ->
    case ets:lookup(?LOG_QUEUE, audit_log) of
	[] -> {reply, [], State};
	[{audit_log, Entries}] ->
	    %% Clear the ETS table
	    ets:insert(?LOG_QUEUE, {audit_log, []}),
	    {reply, Entries, State}
    end;

handle_call({get_storage_metrics, BucketId}, _From, State) ->
    Metrics = case ets:lookup(?BUCKET_STORAGE_TABLE, BucketId) of
        [] -> {BucketId, {0, undefined}};
        [{BucketId, {Used, Available}}] -> {BucketId, {Used, Available}}
    end,
    {reply, Metrics, State};

handle_call(get_all_storage_metrics, _From, State) ->
    Metrics = ets:tab2list(?BUCKET_STORAGE_TABLE),
    {reply, Metrics, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({log, Operation, Details}, State) ->
    Key = erlang:unique_integer([monotonic, positive]),
    CurrentEntries = case ets:lookup(?LOG_QUEUE, Operation) of
        [] -> [];
        [{Operation, Entries}] -> Entries
    end,
    NewEntry = {Key, Details},
    ets:insert(?LOG_QUEUE, {Operation, [NewEntry | CurrentEntries]}),
    {noreply, State};


handle_cast({enqueue_transcode, BucketId, ObjectKey}, #state{transcode_ets = Ets} = State) ->
    case ets:info(Ets, size) >= ?MAX_QUEUE_SIZE of
        true ->
            ?WARNING("[light_ets] Transcode queue overflow for bucket ~p", [BucketId]),
            {noreply, State};
        false ->
            Seq = erlang:unique_integer([monotonic, positive]),
            ets:insert(?VIDEO_TRANSCODE_QUEUE, {Seq, {BucketId, ObjectKey, 0}}),
            {noreply, State}
    end;

handle_cast({requeue_transcode, Task}, #state{transcode_ets = Ets} = State) ->
    case ets:info(Ets, size) >= ?MAX_QUEUE_SIZE of
        true ->
            ?WARNING("[light_ets] Transcode queue overflow during requeue"),
            {noreply, State};
        false ->
            Seq = erlang:unique_integer([monotonic, positive]),
            ets:insert(?VIDEO_TRANSCODE_QUEUE, {Seq, Task}),
            {noreply, State}
    end;

handle_cast({add_subscriber, UserId, Pid, SessionId, BucketIdList}, State) ->
    ets:insert(?SUBSCRIBERS_TABLE, {UserId, Pid, SessionId, BucketIdList}),
    ?INFO("[light_ets] Added subscriber ~p", [UserId]),
    {noreply, State};

handle_cast({remove_subscriber, SessionId}, #state{subscribers_ets = Ets} = State) ->
    ets:match_delete(Ets, {'$1', '$2', SessionId, '$3'}),
    ?INFO("[light_ets] Removed subscriber with session ~p", [SessionId]),
    {noreply, State};

handle_cast({store_message, MessageEntry}, State) ->
    Key = {MessageEntry#message_entry.atomic_id, MessageEntry#message_entry.user_id},
    ets:insert(?MESSAGES_TABLE, {Key, MessageEntry}),
    ?INFO("[light_ets] Stored message ~p for user ~p", [MessageEntry#message_entry.atomic_id, MessageEntry#message_entry.user_id]),
    {noreply, State};

handle_cast({delete_message, AtomicId, UserId}, #state{messages_ets = Ets} = State) ->
    ets:delete(Ets, {AtomicId, UserId}),
    ?INFO("[light_ets] Deleted message ~p for user ~p", [AtomicId, UserId]),
    {noreply, State};

handle_cast({add_bucket_node, BucketId, Node}, State) ->
    ets:insert(?BUCKET_NODES_TABLE, {BucketId, Node}),
    ?INFO("[light_ets] Added node ~p for bucket ~p", [Node, BucketId]),
    {noreply, State};

handle_cast({update_storage, BucketId, Operation, Size}, State) ->
    %% Initialize bucket storage if it doesn't exist
    Current = case ets:lookup(?BUCKET_STORAGE_TABLE, BucketId) of
        [] -> {0, undefined}; % {UsedBytes, AvailableBytes}
        [{BucketId, {Used, Available}}] -> {Used, Available}
    end,
    {NewUsed, NewAvailable} = update_metrics(Operation, Size, Current),

    % Update ETS with new metrics - ensure non-negative used bytes
    ValidUsed = max(0, NewUsed),

    % Only remove entry if used is 0 AND it was a remove operation
    case ValidUsed =:= 0 andalso Operation =:= remove of
        true ->
            % Don't remove buckets from ETS when they reach 0 - keep the quota information
            % Just update with zero usage
            ets:insert(?BUCKET_STORAGE_TABLE, {BucketId, {0, NewAvailable}});
        false ->
            ets:insert(?BUCKET_STORAGE_TABLE, {BucketId, {ValidUsed, NewAvailable}})
    end,
    ?INFO("[light_ets] Updated storage for bucket ~p: Operation=~p, Size=~p, Used=~p, Available=~p",
          [BucketId, Operation, Size, ValidUsed, NewAvailable]),
    {noreply, State};


handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    lists:foreach(fun(I) ->
	    case ets:info(I) of
		undefined -> ok;
		_ -> ets:delete(I)
	    end
	end, [?MIME_TABLE, ?UNIDATA_TABLE, ?LOG_QUEUE, ?VIDEO_TRANSCODE_QUEUE, ?SUBSCRIBERS_TABLE,
	      ?MESSAGES_TABLE, ?BUCKET_NODES_TABLE]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
