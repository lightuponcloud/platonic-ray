-module(pmap).
-export([pmap/2, pmap/3]).

% Default concurrency limit (e.g., number of CPU cores)
pmap(F, L) ->
    pmap(F, L, erlang:system_info(schedulers)).

% Parallel map with configurable concurrency limit
pmap(F, L, MaxWorkers) ->
    Parent = self(),
    Ref = make_ref(),
    {Pids, Monitors} = spawn_workers(F, L, Parent, Ref, MaxWorkers),
    Results = collect_results(Pids, Ref, Monitors, []),
    cleanup(Pids, Monitors, Ref),
    Results.

% Spawn workers in batches to limit concurrency
spawn_workers(F, L, Parent, Ref, MaxWorkers) ->
    spawn_workers(F, L, Parent, Ref, MaxWorkers, [], []).

spawn_workers(_F, [], _Parent, _Ref, _MaxWorkers, Pids, Monitors) ->
    {lists:reverse(Pids), lists:reverse(Monitors)};
spawn_workers(F, [X | Xs], Parent, Ref, MaxWorkers, Pids, Monitors) when length(Pids) < MaxWorkers ->
    % Spawn a new worker
    {Pid, MonRef} = spawn_monitor(fun() ->
        Result = try
                     {ok, F(X)}
                 catch
                     Class:Reason:Stacktrace ->
                         {error, X, {Class, Reason, Stacktrace}}
                 end,
        Parent ! {self(), Ref, Result}
    end),
    spawn_workers(F, Xs, Parent, Ref, MaxWorkers, [Pid | Pids], [{Pid, MonRef} | Monitors]);
spawn_workers(F, Xs, Parent, Ref, MaxWorkers, Pids, Monitors) ->
    % Wait for one worker to finish before spawning more
    receive
        {Pid, Ref, _Result} ->
            % Remove Pid from Pids, keep Monitors until collect_results
            Pids1 = lists:delete(Pid, Pids),
            spawn_workers(F, Xs, Parent, Ref, MaxWorkers, Pids1, Monitors)
        after 5000 ->
            throw({timeout, waiting_for_worker})
    end.

% Collect results in order
collect_results([], _Ref, _Monitors, Acc) ->
    lists:reverse(Acc);
collect_results([Pid | Pids], Ref, Monitors, Acc) ->
    receive
        {Pid, Ref, {ok, Result}} ->
            % Remove this monitor
            {Pid, MonRef} = lists:keyfind(Pid, 1, Monitors),
            erlang:demonitor(MonRef, [flush]),
            collect_results(Pids, Ref, lists:keydelete(Pid, 1, Monitors), [Result | Acc]);
        {Pid, Ref, {error, _X, Error}} ->
            % Remove this monitor
            {Pid, MonRef} = lists:keyfind(Pid, 1, Monitors),
            erlang:demonitor(MonRef, [flush]),
            collect_results(Pids, Ref, lists:keydelete(Pid, 1, Monitors), [{error, Error} | Acc]);
        {'DOWN', MonRef, process, Pid, Reason} when Reason /= normal ->
            % Process crashed before sending result
            erlang:demonitor(MonRef, [flush]),
            collect_results(Pids, Ref, lists:keydelete(Pid, 1, Monitors), [{error, {crash, Reason}} | Acc])
    after 5000 ->
        % Timeout: Mark as error and continue
        {Pid, MonRef} = lists:keyfind(Pid, 1, Monitors),
        erlang:demonitor(MonRef, [flush]),
        exit(Pid, kill),
        collect_results(Pids, Ref, lists:keydelete(Pid, 1, Monitors), [{error, timeout} | Acc])
    end.

% Cleanup lingering processes
cleanup(Pids, Monitors, Ref) ->
    % Send exit signal to all remaining processes
    [exit(Pid, kill) || Pid <- Pids],
    % Flush any remaining messages
    [receive {Pid, Ref, _} -> ok after 0 -> ok end || Pid <- Pids],
    % Demonitor all remaining monitors
    [erlang:demonitor(MonRef, [flush]) || {_Pid, MonRef} <- Monitors].
