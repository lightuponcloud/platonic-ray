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
-export([start_link/0, to_lower/1, guess_content_type/1, log_operation/2, get_queue_size/1,
         enqueue_transcode/2, dequeue_transcode/1, requeue_transcode/1, get_transcode_queue_size/0]).

-behaviour(gen_server).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("log.hrl").

-define(VIDEO_TRANSCODE_QUEUE, video_transcode_queue).
-define(MAX_QUEUE_SIZE, 10_000). % From video_transcoding
-define(PMAP_WORKERS, 4).        % From video_transcoding

-record(state, {
    unidata_ets = undefined :: ets:tid() | undefined,
    mime_ets = undefined :: ets:tid() | undefined,
    log_ets = undefined :: ets:tid() | undefined,
    transcode_ets = undefined :: ets:tid() | undefined
}).

%% API for existing functionality

%%
%% Converts characters of a string to a lowercase format.
%%
to_lower(String) when is_list(String) ->
    gen_server:call(?MODULE, {to_lower, String}).

guess_content_type(FileName) when is_list(FileName) ->
    gen_server:call(?MODULE, {mime_type, FileName}).

log_operation(Operation, Details) ->
    gen_server:cast(?MODULE, {log, Operation, Details}).

%%
%% Get the size of the log queue from light_ets
%%
get_queue_size(QueueName) when is_atom(QueueName) ->
    case ets:lookup(log_queue, QueueName) of
        [] -> 0;
        [{QueueName, Entries}] -> length(Entries)
    end.

%% API for video transcoding queue
enqueue_transcode(BucketId, ObjectKey) ->
    gen_server:cast(?MODULE, {enqueue_transcode, BucketId, ObjectKey}).

dequeue_transcode(Limit) when is_integer(Limit), Limit > 0 ->
    gen_server:call(?MODULE, {dequeue_transcode, Limit}).

requeue_transcode(Task) ->
    gen_server:cast(?MODULE, {requeue_transcode, Task}).

get_transcode_queue_size() ->
    gen_server:call(?MODULE, get_transcode_queue_size).

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
            lager:error("~w: Cannot open file ~ts. ~n", [?MODULE, FileName]),
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
    Ets = ets:new(unidata, [{write_concurrency, false}, {read_concurrency, true}]),
    read_file({Fd, Ets}),
    file:close(Fd),
    Ets.

load_mime_types() ->
    EbinDir = filename:dirname(code:which(?MODULE)),
    AppDir = filename:dirname(EbinDir),
    MimeTypesFile = filename:join([AppDir, "priv", "mime.types"]),
    {ok, MimeTypes} = httpd_conf:load_mime_types(MimeTypesFile),
    Ets = ets:new(mime_types, [{write_concurrency, false}, {read_concurrency, true}]),
    [ets:insert(Ets, I) || I <- MimeTypes],
    Ets.

load_log_ets() ->
    ets:new(log_queue, [named_table, {write_concurrency, true}, {read_concurrency, true}]).

load_transcode_ets() ->
    ets:new(?VIDEO_TRANSCODE_QUEUE, [
        ordered_set,
        {write_concurrency, true},
        {read_concurrency, true},
        private
    ]).

string_to_lower(Ets, String) ->
    pmap:pmap(
        fun(C) ->
            Key = erlang:list_to_integer(io_lib:fwrite("~B", [C])),
            case ets:lookup(Ets, Key) of
                [] -> Key;
                [{Key, Val}] -> lists:nth(1, unicode:characters_to_list([Val]))
            end
        end, String).

%% Starts the server
start_link() ->
    Ets0 = load_unicode_mapping(),
    Ets1 = load_mime_types(),
    Ets2 = load_log_ets(),
    Ets3 = load_transcode_ets(),
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Ets0, Ets1, Ets2, Ets3], []).

%%% gen_server callbacks
init([UnidataEts, MimeEts, LogEts, TranscodeEts]) ->
    {ok, #state{
        unidata_ets = UnidataEts,
        mime_ets = MimeEts,
        log_ets = LogEts,
        transcode_ets = TranscodeEts
    }}.

handle_call({to_lower, String}, _From, State) ->
    Ets = State#state.unidata_ets,
    Result = string_to_lower(Ets, String),
    {reply, Result, State};

handle_call({mime_type, FileName}, _From, State) ->
    UnidataEts = State#state.unidata_ets,
    MimeEts = State#state.mime_ets,
    Result =
        case filename:extension(FileName) of
            [] -> "application/octet_stream";
            Extension0 ->
                Extension1 = string_to_lower(UnidataEts, unicode:characters_to_list(Extension0)),
                case Extension1 of
                    ".heic" -> "image/heic";
                    _ ->
                        LookupKey = string:substr(Extension1, 2),
                        case ets:lookup(MimeEts, LookupKey) of
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

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({log, Operation, Details}, State) ->
    LogEts = State#state.log_ets,
    Key = erlang:unique_integer([monotonic, positive]),
    CurrentEntries = case ets:lookup(LogEts, Operation) of
        [] -> [];
        [{Operation, Entries}] -> Entries
    end,
    NewEntry = {Key, Details},
    ets:insert(LogEts, {Operation, [NewEntry | CurrentEntries]}),
    {noreply, State};

handle_cast({enqueue_transcode, BucketId, ObjectKey}, #state{transcode_ets = Ets} = State) ->
    case ets:info(Ets, size) >= ?MAX_QUEUE_SIZE of
        true ->
            ?WARNING("[light_ets] Transcode queue overflow for bucket ~p", [BucketId]),
            {noreply, State};
        false ->
            Seq = erlang:unique_integer([monotonic, positive]),
            ets:insert(Ets, {Seq, {BucketId, ObjectKey, 0}}),
            {noreply, State}
    end;

handle_cast({requeue_transcode, Task}, #state{transcode_ets = Ets} = State) ->
    case ets:info(Ets, size) >= ?MAX_QUEUE_SIZE of
        true ->
            ?WARNING("[light_ets] Transcode queue overflow during requeue"),
            {noreply, State};
        false ->
            Seq = erlang:unique_integer([monotonic, positive]),
            ets:insert(Ets, {Seq, Task}),
            {noreply, State}
    end;

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    ets:delete(State#state.unidata_ets),
    ets:delete(State#state.mime_ets),
    ets:delete(State#state.log_ets),
    ets:delete(State#state.transcode_ets),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

