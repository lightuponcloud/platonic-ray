%%
%% This server loads unicode characters to memory and provides possibility to
%% convert characters to lowercase.
%%
-module(light_unicode).
-export([start_link/0, to_lower/1]).

-behaviour(gen_server).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-include("log.hrl").

-record(state, {ets = undefined}).

%%
%% Converts characters of a string to a lowercase format.
%%
to_lower(String) when erlang:is_list(String) ->
    gen_server:call(?MODULE, {to_lower, String}).


hex_to_int(Code) ->
    case io_lib:fread("~16u", Code) of
	{ok, [Int], []} -> Int;
	_ -> false
    end.

%% This functions are used in parser modules.
-spec split(char(), string()) -> [string].
split(Char, Str) -> lists:reverse(do_split(Char, Str, [], [])).

do_split(Char, [Char|Tail], Acc1, Acc2) ->
    do_split(Char, Tail, [], [lists:reverse(Acc1) | Acc2]);
do_split(_Char, [], Acc1, Acc2) ->
    [lists:reverse(Acc1) | Acc2];
do_split(Char, [Head|Tail], Acc1, Acc2) ->
    do_split(Char, Tail, [Head|Acc1], Acc2).


%% Return a file descriptor or throw error.
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
            io:fwrite(
                "~w: Cannot open file ~ts. ~n",
                [?MODULE, FileName]),
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


load_mapping() ->
    EbinDir = filename:dirname(code:which(light_unicode)),
    AppDir = filename:dirname(EbinDir),
    FilePath = filename:join([AppDir, "priv", "UnicodeData.txt.gz"]),
    Fd = open_file(FilePath),
    Ets = ets:new(unidata, [{write_concurrency, false}, {read_concurrency, true}]),
    read_file({Fd, Ets}),
    file:close(FilePath),
    Ets.

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    Ets = load_mapping(),
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Ets], []).

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
init([Ets]) ->
    {ok, #state{ets = Ets}}.


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
handle_call({to_lower, String}, _, State0) ->
    Ets = State0#state.ets,

    Result = lists:map(
	fun(C) ->
	    Key = erlang:list_to_integer(io_lib:fwrite("~B", [C])),
	    case ets:lookup(Ets, Key) of
		[] -> Key;
		[{Key, Val}] -> lists:nth(1, unicode:characters_to_list([Val]))
	    end
	end, String),

    {reply, Result, State0};

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
handle_cast(_Info, State) ->
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
handle_info(_Info, State) ->
    {noreply, State}.

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
