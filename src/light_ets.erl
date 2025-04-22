%%
%% This server loads Unicode characters and MIME types into ETS tables and maintains a log queue.
%%
-module(light_ets).
-export([start_link/0, to_lower/1, guess_content_type/1, log_operation/2]).

-behaviour(gen_server).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-include("log.hrl").

-record(state, {unidata_ets = undefined, mime_ets = undefined, log_ets = undefined}).

%%
%% Converts characters of a string to a lowercase format.
%%
to_lower(String) when erlang:is_list(String) ->
    gen_server:call(?MODULE, {to_lower, String}).

guess_content_type(FileName) when erlang:is_list(FileName) ->
    gen_server:call(?MODULE, {mime_type, FileName}).

%% Log an operation (e.g., for auditing to_lower or guess_content_type calls)
log_operation(Operation, Details) ->
    gen_server:cast(?MODULE, {log, Operation, Details}).

%%
%% Utility Functions
%%
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

string_to_lower(Ets, String) ->
    pmap:pmap(
        fun(C) ->
            Key = erlang:list_to_integer(io_lib:fwrite("~B", [C])),
            case ets:lookup(Ets, Key) of
                [] -> Key;
                [{Key, Val}] -> lists:nth(1, unicode:characters_to_list([Val]))
            end
        end, String).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    Ets0 = load_unicode_mapping(),
    Ets1 = load_mime_types(),
    Ets2 = load_log_ets(),
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Ets0, Ets1, Ets2], []).

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
init([UnidataEts, MimeEts, LogEts]) ->
    {ok, #state{unidata_ets = UnidataEts, mime_ets = MimeEts, log_ets = LogEts}}.

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
handle_cast({log, Operation, Details}, State) ->
    LogEts = State#state.log_ets,
    % Generate a unique key (e.g., timestamp-based)
    Key = erlang:unique_integer([monotonic, positive]),
    % Prepend the new entry to the list of entries for this operation type
    CurrentEntries = case ets:lookup(LogEts, Operation) of
        [] -> [];
        [{Operation, Entries}] -> Entries
    end,
    NewEntry = {Key, Details},
    ets:insert(LogEts, {Operation, [NewEntry | CurrentEntries]}),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages. Called by send_after() call.
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

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
terminate(_Reason, State) ->
    % Clean up ETS tables
    ets:delete(State#state.unidata_ets),
    ets:delete(State#state.mime_ets),
    ets:delete(State#state.log_ets),
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
