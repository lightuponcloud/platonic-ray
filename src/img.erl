%%
%% Contains gen_server, that sends commands to image resizing application.
%%
-module(img).
-behaviour(gen_server).

-export([start_link/1, scale/1, get_size/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-include("log.hrl").
-include("storage.hrl").

-record(state, {port :: undefined | port(),
		links = sets:new() :: sets:set(),
		os_pid :: undefined | pos_integer(),
		num :: pos_integer()}).

%%
%% Starts N servers for image/video thumbnails
%%
start_link(PortNumber) ->
    Name = list_to_atom(
	lists:flatten(io_lib:format("img_sup_~p", [PortNumber]))),
    gen_server:start_link({local, Name}, ?MODULE, [PortNumber], []).


init([PortNumber]) ->
    {Port, OSPid} = start_port(PortNumber),
    process_flag(trap_exit, true),
    {ok, #state{port = Port, os_pid = OSPid, num = PortNumber}}.


-spec scale(proplists:proplist()) -> binary().

scale(Term) when erlang:is_list(Term) ->
    Tag = erlang:term_to_binary(self()),
    PortNumber = rand:uniform(?IMAGE_WORKERS)-1,
    PortName = list_to_atom(
	lists:flatten(io_lib:format("img_port_~p", [PortNumber]))),
    Port = whereis(PortName),
    Data = erlang:term_to_binary(Term++[{tag, Tag}]),
    try
	case port_command(Port, Data) of
	    true ->
		receive
		    {Port, Reply} ->
			demonitor_port(Port),
			Reply;
		    {'EXIT', Port, _} -> erlang:error(badarg)
		after 7000 ->
		    demonitor_port(Port),
		    {error, timeout}
		end;
	    false -> erlang:error(badarg)
	end
    catch _:badarg ->
	demonitor_port(Port),
	{error, no_response}
    end.


-spec get_size(binary()) -> tuple().

get_size(ImageData) when erlang:is_binary(ImageData) ->
    Tag = erlang:term_to_binary(self()),
    PortNumber = rand:uniform(?IMAGE_WORKERS)-1,
    PortName = list_to_atom(
	lists:flatten(io_lib:format("img_port_~p", [PortNumber]))),
    Port = whereis(PortName),
    Data = erlang:term_to_binary([{from, ImageData}, {tag, Tag}, {just_get_size, true}]),
    try
	case port_command(Port, Data) of
	    true ->
		receive
		    {Port, Reply} ->
			demonitor_port(Port),
			Reply;
		    {'EXIT', Port, _} -> erlang:error(badarg)
		after 7000 ->
		    demonitor_port(Port),
		    {error, timeout}
		end;
	    false -> erlang:error(badarg)
	end
    catch _:badarg ->
	demonitor_port(Port),
	{error, no_response}
    end.

-spec start_port(pos_integer()) -> {port() | undefined, integer() | undefined}.

start_port(PortNumber) ->
    EbinDir = filename:dirname(code:which(img)),
    AppDir = filename:dirname(EbinDir),
    Path = filename:join([AppDir, "c_src", img]),
    %%
    %% You might want to set MAGICK_TMPDIR environment variable
    %% to the directory, where more space is available.
    %%
    Env = [{"MAGICK_THREAD_LIMIT", "4"},
	   {"MAGICK_MEMORY_LIMIT", "20000000"}],
    %% Check if port file can be opened
    case file:open(Path, [read]) of
	{ok, Fd} ->
	    file:close(Fd),
	    Port = open_port({spawn, Path}, [{packet, 4}, binary, {env, Env}]),
	    try
		link(Port),
		PortName = list_to_atom(
		    lists:flatten(io_lib:format("img_port_~p", [PortNumber]))),
		register(PortName, Port),
		case erlang:port_info(Port, os_pid) of
		    {os_pid, OSPid} ->
			monitor_port(Port),
			{Port, OSPid};
		    undefined ->
			{Port, undefined}
		end
	    catch _:badarg ->
		flush_queue(Port),
		%% Restart
		erlang:send_after(1000, self(), start_port),
		{undefined, undefined}
	    end;
        {error, _} ->
	    ?ERROR("Failed to read ~s", [Path]),
	    %% Restart
	    erlang:send_after(1000, self(), start_port),
	    {undefined, undefined}
    end.

handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast(_Msg, State) ->  {noreply, State}.

handle_info({Port, {data, Term0}}, #state{port=Port}=State) ->
    {Tag, Term1} = erlang:binary_to_term(Term0),
    case Tag of
	error ->
	    lager:warning("[img] ~p~n", [Term1]),
	    {noreply, State};
	_ ->
	    Pid = erlang:binary_to_term(Tag),
	    Pid ! {Port, Term1},
	    {noreply, State}
    end;
handle_info({monitor_port, Port, Pid}, State) ->
    if State#state.port =:= Port ->
	    Links = sets:add_element(Pid, State#state.links),
	    {noreply, State#state{links = Links}};
       true ->
	    Pid ! {'EXIT', Port, normal},
	    {noreply, State}
    end;
handle_info({demonitor_port, Port, Pid}, State) ->
    if State#state.port =:= Port ->
	    Links = sets:del_element(Pid, State#state.links),
	    {noreply, State#state{links = Links}};
       true ->
	    {noreply, State}
    end;
handle_info({'EXIT', Port, Reason}, #state{port = Port} = State) ->
    ?ERROR("[img] External img process (pid=~w) has terminated unexpectedly",
	    [State#state.os_pid]),
    Links = sets:filter(
	      fun(Pid) ->
		      Pid ! {'EXIT', Port, Reason},
		      false
	      end, State#state.links),
    State1 = State#state{port = undefined,
			 os_pid = undefined,
			 links = Links},
    demonitor_port(Port),
    erlang:send_after(200, self(), start_port),
    {noreply, State1};
handle_info(start_port, #state{port = undefined, num = PortNumber} = State) ->
    {Port, OSPid} = start_port(PortNumber),
    {noreply, State#state{port = Port, os_pid = OSPid}};
handle_info(Info, State) ->
    ?ERROR("[img] got unexpected info: ~p", [Info]),
    {noreply, State}.

-spec monitor_port(port() | undefined) -> ok.

monitor_port(Port) ->
    case erlang:port_info(Port, connected) of
	{connected, Pid} ->
	    Pid ! {monitor_port, Port, self()};
	undefined ->
	    self() ! {'EXIT', Port, normal}
    end,
    ok.

-spec demonitor_port(port() | undefined) -> ok.

demonitor_port(Port) ->
    case erlang:port_info(Port, connected) of
	{connected, Pid} ->
	    Pid ! {demonitor_port, Port, self()};
	undefined ->
	    ok
    end,
    flush_queue(Port).

-spec flush_queue(port() | undefined) -> ok.

flush_queue(Port) when erlang:is_port(Port) ->
    receive {'EXIT', Port, _} -> ok
    after 0 -> ok
    end;
flush_queue(_) ->
    ok.

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
terminate(Reason, #state{port = Port} = State) ->
    lager:warning("[img] terminating port. Reason: ~p~n", [Reason]),
    if erlang:is_port(Port) ->
	    catch port_close(Port),
	    sets:filter(
	      fun(Pid) ->
		      Pid ! {'EXIT', Port, terminated},
		      false
	      end, State#state.links);
       true ->
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
code_change(_OldVsn, State, _Extra) -> {ok, State}.
