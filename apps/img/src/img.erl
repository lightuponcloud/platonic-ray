%%
%% Contains gen_server, that sends commands to image resizing application.
%%
-module(img).
-behaviour(gen_server).

-export([start_link/1, port_action/2]).

-export([init/1, handle_info/2, terminate/2, code_change/3, handle_call/3, handle_cast/2]).

-include_lib("common_lib/include/log.hrl").
-include_lib("common_lib/include/storage.hrl").
-include_lib("common_lib/include/general.hrl").
-include_lib("kernel/include/file.hrl").

%% State for the img gen_server.
%% - port: The opened port to the external image processing program.
%% - links: Set of PIDs monitoring the port.
%% - os_pid: OS process ID of the external program.
%% - num: Port number assigned to this worker.
-record(state, {port :: undefined | port(),
                links = sets:new() :: sets:set(),
                os_pid :: undefined | pos_integer(),
                num :: pos_integer(),
                monitored = false :: boolean(),
                last_pong = undefined :: undefined | erlang:timestamp(),
                ping_retries = 0 :: non_neg_integer(),
                ping_timer = undefined}).
-define(IMG_PORT, img_port).
-define(INTERNAL_IMAGE_WORKERS, 4).  %% The number of imagemagick workers for scaling images
-define(INTERNAL_IMAGE_POPRT_PING_INTERVAL, 30000).  % 30 seconds ( this is retry timeout )
-define(MAX_PING_RETRIES, 3).        % Maximum number of ping retry attempts

%% Starts N servers for image/video thumbnails
start_link(PortNumber) ->
    Name = erlang:list_to_atom("img_port_" ++ erlang:integer_to_list(PortNumber)),
    gen_server:start_link({local, Name}, ?MODULE, [PortNumber], []).

init([PortNumber]) ->
    {Port, OSPid} = start_port(PortNumber, 3),  % retries
    process_flag(trap_exit, true),
    {ok, Tref} = timer:send_interval(?INTERNAL_IMAGE_POPRT_PING_INTERVAL, ping),
    {ok, #state{port = Port, os_pid = OSPid, num = PortNumber, ping_timer=Tref}}.

port_action(scale, Term) when erlang:is_list(Term) ->
    Timeout = get_timeout(Term),
    PortNum = rand:uniform(?INTERNAL_IMAGE_WORKERS),
    PortName = erlang:list_to_atom("img_port_" ++ erlang:integer_to_list(PortNum)),
    gen_server:call(PortName, {command, Term, Timeout});

port_action(get_size, Term) when erlang:is_list(Term) ->
    Timeout = get_timeout(Term),
    PortNum = rand:uniform(?INTERNAL_IMAGE_WORKERS),
    PortName = erlang:list_to_atom("img_port_" ++ erlang:integer_to_list(PortNum)),
    gen_server:call(PortName, {command, Term, Timeout}).


-spec get_timeout(proplists:proplist()) -> pos_integer().

get_timeout(Term) ->
    FileSize = proplists:get_value(size, Term, 0), % Size in bytes
    case FileSize of
        Size when Size =< 1_000_000 -> 3000; % Small images (<1MB): 3s
        Size when Size =< 5_000_000 -> 5000; % Medium images (<5MB): 5s
        Size when Size =< 10_000_000 -> 7000; % Large images (<10MB): 7s
        _ -> 10000 % Very large images: 10s
    end.

file_exists(Path) ->
    case file:read_file_info(Path) of
        {error, Reason} -> {error, Reason};
        {ok, FileInfo} ->
            % Check executable permissions
            case FileInfo#file_info.mode band 8#111 of
                0 -> {error, no_exec_rights};
                _ -> ok
            end
    end.

start_port(_PortNumber, Retries) when Retries > 3 ->
    ?ERROR("Failed to start port after ~p retries", [Retries]),
    {undefined, undefined};
start_port(PortNumber, Retries) ->
    Env = [
        {"MAGICK_THREAD_LIMIT", application:get_env(img, magick_thread_limit, "4")},
        {"MAGICK_MEMORY_LIMIT", application:get_env(img, magick_memory_limit, "20000000")}
    ],
    case code:priv_dir(img) of
        {error, bad_name} ->
            ?ERROR("img binary not found, retries=~p", [Retries]),
            erlang:send_after(1000, self(), {start_port, Retries + 1}),
            {undefined, undefined};
        Dir ->
            Path = filename:join([Dir, "img"]),
            ?INFO("Attempting to start port from path: ~p", [Path]),
            case file_exists(Path) of
                {error, Reason} ->
                    ?ERROR("Failed to access ~s: ~p, retries=~p", [Path, Reason, Retries]),
                    erlang:send_after(1000, self(), {start_port, Retries + 1}),
                    {undefined, undefined};
                ok ->
                    Port = open_port({spawn, Path}, [{packet, 4}, binary, {env, Env}]),
                    Group = {?IMG_PORT, PortNumber},
                    pg:join(?SCOPE_PG, Group, self()),  % Register in process group and associate with the port
                    OSPid = case erlang:port_info(Port, os_pid) of
                        {os_pid, Pid} -> Pid;
                        undefined -> undefined
                    end,
                    monitor_port(Port),
                    ?INFO("Successfully started port ~p with OS PID ~p", [Port, OSPid]),
                    {Port, OSPid}
            end
    end.

handle_info({Port, {data, Term0}}, #state{port = Port} = State) ->
    case erlang:binary_to_term(Term0) of
        {ping, _Tag} ->
            % Pong received
            {noreply, State#state{last_pong = os:timestamp(), ping_retries = 0}};
        {Tag, Term1} ->
            Pid = erlang:binary_to_term(Tag),
            case erlang:is_process_alive(Pid) of
                true ->
                    Pid ! {Port, Term1},
                    {noreply, State};
                false ->
                    ?WARNING("[img] Dropping response for dead PID: ~p", [Pid]),
                    {noreply, State}
            end
    end;

handle_info({monitor_port, Port, Pid}, State) ->
    if State#state.port =:= Port ->
            Links = sets:add_element(Pid, State#state.links),
            {noreply, State#state{links = Links, monitored=true}};
       true ->
            Pid ! {'EXIT', Port, normal},
            {noreply, State}
    end;
handle_info({demonitor_port, Port, Pid}, #state{monitored = true} = State) ->
    if State#state.port =:= Port ->
            Links = sets:del_element(Pid, State#state.links),
            {noreply, State#state{links = Links}};
       true -> {noreply, State}
    end;
handle_info({demonitor_port, _Port, _Pid}, #state{monitored = false} = State) ->
    {noreply, State};

handle_info({'EXIT', Port, Reason}, #state{port = Port} = State) ->
    ?ERROR("[img] process (pid=~w) has terminated unexpectedly: ~p", [State#state.os_pid, Reason]),
    if State#state.port =:= Port ->
            demonitor_port(Port),
            erlang:send_after(200, self(), {start_port, ?MAX_PING_RETRIES}),
            {noreply, State#state{port=undefined, os_pid=undefined}};
       true -> {noreply, State}
    end;

handle_info({start_port, Retries}, #state{port = undefined, num = PortNumber} = State) ->
    {Port, OSPid} = start_port(PortNumber, Retries),
    {noreply, State#state{port = Port, os_pid = OSPid}};
handle_info(start_port, #state{port = undefined, num = PortNumber} = State) ->
    {Port, OSPid} = start_port(PortNumber, 0),
    {noreply, State#state{port = Port, os_pid = OSPid}};

handle_info(ping, #state{port = undefined} = State) ->
    % No port to ping, try to restart
    self() ! {start_port, ?MAX_PING_RETRIES},
    {noreply, State};

handle_info(ping, #state{port = Port, ping_retries = RetryCount} = State) ->
    Timeout = 3000,
    Tag = erlang:term_to_binary(self()),
    Data = erlang:term_to_binary([{ping, port}, {tag, Tag}]),
    case send_image_command(Port, Data, Timeout) of
        {data, _Binary} ->
            % Successfully received ping response
            {noreply, State#state{last_pong = os:timestamp(), ping_retries = 0}};
        {error, Reason} ->
            % Ping failed
            ?WARNING("[img] port did not respond to ping: ~p, retry count: ~p", [Reason, RetryCount]),
            if RetryCount >= ?MAX_PING_RETRIES ->
                % Max retries reached, restart the port
                ?ERROR("[img] port failed to respond after ~p ping attempts, restarting port", [RetryCount + 1]),
                demonitor_port(Port),
                self() ! {start_port, ?MAX_PING_RETRIES},
                {noreply, State#state{port = undefined, os_pid = undefined, ping_retries = 0}};
            true ->
                % Schedule another ping with a short retry interval (5 seconds)
                erlang:send_after(5000, self(), ping),
                {noreply, State#state{ping_retries = RetryCount + 1}}
            end
    end;

handle_info(Info, State) ->
    ?ERROR("[img] got unexpected info: ~p", [Info]),
    {noreply, State}.

handle_call({command, Term, Timeout}, _From, #state{port = Port} = State) ->
    Tag = erlang:term_to_binary(self()),
    Data = erlang:term_to_binary(Term++[{tag, Tag}]),
    case send_image_command(Port, Data, Timeout) of
        {data, <<>>} ->
	    ?WARNING("No data received from img port"),
            {reply, <<>>, State};
        {data, Binary} ->
            {_Tag, Reply} = erlang:binary_to_term(Binary),
            {reply, Reply, State};
        {error, Reason} ->
            ?ERROR("[img] port returned error: ~p", [Reason]),
            demonitor_port(Port),
            self() ! {start_port, ?MAX_PING_RETRIES},
            {noreply, {error, Reason}, State#state{port = undefined, os_pid = undefined, ping_retries = 0}}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast(_Msg, State) ->
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
        undefined -> ok
    end,
    flush_queue(Port).

-spec flush_queue(port() | undefined) -> ok.

flush_queue(Port) when erlang:is_port(Port) ->
    receive
        {Port, _} -> flush_queue(Port);
        {'EXIT', Port, _} -> flush_queue(Port)
    after 0 -> ok
    end;
flush_queue(_) ->
    ok.

send_image_command(Port, Data, Timeout) when erlang:is_binary(Data) andalso erlang:is_integer(Timeout) ->
    case erlang:port_info(Port) of
        undefined ->
            demonitor_port(Port),
            {error, port_down};
        _ ->
            case port_command(Port, Data) of
                true ->
                    receive
                        {Port, Reply} ->
                            demonitor_port(Port),
                            Reply;
                        {'EXIT', Port, Reason} -> {error, Reason}
                    after Timeout ->
                        {error, timeout}
                    end;
                false -> {error, badarg}
            end
    end.

terminate(Reason, #state{port = Port, num = PortNumber, ping_timer = Tref} = State) ->
    lager:warning("[img] terminating port. Reason: ~p~n", [Reason]),
    case Tref of
        undefined -> ok;
        _ -> timer:cancel(Tref)
    end,
    pg:leave(?SCOPE_PG, {?IMG_PORT, PortNumber}, self()),
    if erlang:is_port(Port) ->
            catch port_close(Port),
            sets:filter(
              fun(Pid) ->
                      Pid ! {'EXIT', Port, terminated},
                      false
              end, State#state.links);
       true -> ok
    end.

code_change(_OldVsn, State, _Extra) -> {ok, State}.
