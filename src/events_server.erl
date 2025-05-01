%%
%% This asyncronous process broadcasts messages to websockets.
%%
-module(events_server).
-behaviour(gen_server).

-include("general.hrl").
-include("entities.hrl").
-include("log.hrl").

%% API
-export([start_link/0, start/0, stop/0]).
-export([new_subscriber/4, logout_subscriber/1, send_message/3,
         user_active/1, confirm_reception/3, get_subscribers/0]).

%% gen_server callbacks
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3]).

%% Constants
-define(MESSAGE_RETRY_ATTEMPTS, 1).
-define(MESSAGE_RETRY_INTERVAL, 1000). % 1 second
-define(CHECK_CONFIRMATIONS_INTERVAL, 1000). % 1 second
-define(WS_PG, notifications).
-define(FLUSH_TIMEOUT, 5000). % 5 seconds for flush

%% State
-record(state, {
    monitored_pids = #{} :: #{pid() => reference()}
}).

%% Validation utility
validate_string(S) when is_list(S), S =/= [] -> true;
validate_string(_) -> false.

%% Management API
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

start() ->
    gen_server:start({local, ?MODULE}, ?MODULE, [], []).

stop() ->
    gen_server:call(?MODULE, stop).

%% Registers a new subscriber syncronously (UserId -> Pid mapping).
new_subscriber(UserId, Pid, SessionId, BucketIdList) when is_list(UserId), is_pid(Pid), is_list(SessionId), is_list(BucketIdList) ->
    case {validate_string(UserId), validate_string(SessionId), lists:all(fun validate_string/1, BucketIdList)} of
        {true, true, true} ->
            case erlang:is_process_alive(Pid) of
                true ->
                    gen_server:call(?MODULE, {new_subscriber, UserId, Pid, SessionId, BucketIdList});
                false ->
                    {error, invalid_pid}
            end;
        _ ->
            {error, invalid_input}
    end.

logout_subscriber(SessionId) when is_list(SessionId) ->
    case validate_string(SessionId) of
        true ->
            Pids = pg:get_members(?SCOPE_PG, ?WS_PG),
            [gen_server:cast(Pid, {logout_subscriber, SessionId}) || Pid <- Pids],
            ok;
        false ->
            {error, invalid_session_id}
    end.

get_subscribers() ->
    light_ets:get_subscribers().

%% Check user has active channel
user_active(UserId) when is_list(UserId) ->
    case validate_string(UserId) of
        true ->
            Pids = pg:get_members(?SCOPE_PG, ?WS_PG),
            user_active(UserId, Pids, []);
        false ->
            {error, invalid_user_id}
    end.

user_active(_UserId, [], Acc) -> Acc;
user_active(UserId, [Pid | T], Acc) ->
    Subs = gen_server:call(Pid, {user_active, UserId}),
    user_active(UserId, T, lists:append(Subs, Acc)).

%% Send message to user's session asyncronously.
send_message(BucketId, AtomicId, Msg) when is_list(BucketId), is_list(AtomicId), is_binary(Msg) ->
    case {validate_string(BucketId), validate_string(AtomicId)} of
        {true, true} ->
            gen_server:cast(?MODULE, {message, BucketId, AtomicId, Msg}),
            ok;
        _ ->
            {error, invalid_input}
    end.

confirm_reception(AtomicId, UserId, SessionId) when is_list(AtomicId), is_list(UserId), is_list(SessionId) ->
    case {validate_string(AtomicId), validate_string(UserId), validate_string(SessionId)} of
        {true, true, true} ->
            gen_server:cast(?MODULE, {confirmation, AtomicId, UserId, SessionId}),
            ok;
        _ ->
            {error, invalid_input}
    end.

%% gen_server callbacks
init(_) ->
    process_flag(trap_exit, true),
    pg:join(?SCOPE_PG, ?WS_PG, self()),
    erlang:start_timer(?CHECK_CONFIRMATIONS_INTERVAL, self(), check_confirmations),
    {ok, #state{monitored_pids = #{}}}.

terminate(_Reason, _State) ->
    ok.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};

handle_call({new_subscriber, UserId, Pid, SessionId, BucketIdList}, _From, #state{monitored_pids = Pids} = State) ->
    case erlang:is_process_alive(Pid) of
        true ->
            Ref = erlang:monitor(process, Pid),
            light_ets:add_subscriber(UserId, Pid, SessionId, BucketIdList),
            Node = node(Pid),
            [light_ets:add_bucket_node(BucketId, Node) || BucketId <- BucketIdList],
            {reply, ok, State#state{monitored_pids = Pids#{Pid => Ref}}};
        false ->
            {reply, {error, pid_not_alive}, State}
    end;

handle_call({user_active, UserId}, _From, State) ->
    Subscribers = light_ets:get_subscribers(),
    Active = [S || S <- Subscribers, element(1, S) =:= UserId],
    {reply, Active, State};

handle_call(_Other, _From, State) ->
    {reply, {error, request}, State}.

%% Sends messages to connected websocket sessions asyncronously.
handle_cast({message, BucketId, AtomicId, Msg}, State) ->
    EncodedMsg = jsx:encode([{id, utils:to_binary(AtomicId)}, {message, Msg}]),
    Subscribers = light_ets:get_subscribers_by_bucket(BucketId),
    Nodes = light_ets:get_nodes_by_bucket(BucketId),
    lists:foreach(
        fun(Node) ->
            case lists:member(Node, Nodes) of
                true ->
                    send_to_subscribers(Subscribers, BucketId, AtomicId, EncodedMsg);
                false ->
                    ok
            end
        end, Nodes),
    {noreply, State};

%% Confirmation on reception of message.
handle_cast({confirmation, AtomicId, UserId, _SessionId}, State) ->
    light_ets:delete_message(AtomicId, UserId),
    ?INFO("[events_server] Confirmation received for message ~p, user ~p", [AtomicId, UserId]),
    {noreply, State};

handle_cast({logout_subscriber, SessionId}, State) ->
    Subscribers = light_ets:get_subscribers(),
    RelevantSubs = [S || S <- Subscribers, element(3, S) =:= SessionId],
    lists:foreach(
        fun({_, Pid, _, _}) ->
            case erlang:is_process_alive(Pid) of
                true ->
                    Pid ! {events_server, flush},
                    receive
                        {flushed, Pid} -> ok
                    after ?FLUSH_TIMEOUT ->
                        ?WARN("[events_server] Flush timeout for ~p", [Pid])
                    end,
                    Pid ! {events_server, stop};
                false ->
                    ok
            end
        end, RelevantSubs),
    light_ets:remove_subscriber(SessionId),
    {noreply, State};

handle_cast(_Other, State) ->
    {noreply, State}.

%% Check if confirmation received. Terminate websocket connection
%% in case confirmation not received ``MESSAGE_RETRY_ATTEMPTS`` times.
handle_info({timeout, _Ref, check_confirmations}, State) ->
    Messages = light_ets:get_messages_by_user('_'), % Get all messages
    lists:foreach(
        fun({{AtomicId, UserId}, #message_entry{counter = Counter, pid = Pid, session_id = SessionId} = Entry}) ->
            case Counter > ?MESSAGE_RETRY_ATTEMPTS of
                true ->
                    ?INFO("[events_server] Terminating session ~p on timeout", [SessionId]),
                    case erlang:is_process_alive(Pid) of
                        true -> Pid ! {events_server, stop};
                        false -> ok
                    end,
                    light_ets:delete_message(AtomicId, UserId);
                false ->
                    case erlang:is_process_alive(Pid) of
                        true ->
                            NewEntry = Entry#message_entry{counter = Counter + 1},
                            light_ets:store_message(NewEntry),
                            send_msg(Pid, Entry#message_entry.message);
                        false ->
                            light_ets:delete_message(AtomicId, UserId)
                    end
            end
        end, Messages),
    erlang:start_timer(?CHECK_CONFIRMATIONS_INTERVAL, self(), check_confirmations),
    {noreply, State};

handle_info({'DOWN', Ref, process, Pid, _Reason}, #state{monitored_pids = Pids} = State) ->
    case maps:take(Pid, Pids) of
        {Ref, NewPids} ->
            Subscribers = light_ets:get_subscribers(),
            case [S || S <- Subscribers, element(2, S) =:= Pid] of
                [{UserId, _, SessionId, _}] ->
                    light_ets:remove_subscriber(SessionId),
                    Messages = light_ets:get_messages_by_user(UserId),
                    [light_ets:delete_message(AtomicId, UserId) || {{AtomicId, _}, _} <- Messages],
                    ?INFO("[events_server] Cleaned up subscriber ~p due to process death", [UserId]);
                _ ->
                    ok
            end,
            {noreply, State#state{monitored_pids = NewPids}};
        error ->
            {noreply, State}
    end;

handle_info(_Other, State) ->
    {noreply, State}.

code_change(_Vsn, State, _Extra) ->
    {ok, State}.

%% Internal functions
send_to_subscribers(Subscribers, BucketId, AtomicId, Msg) ->
    lists:foreach(
        fun({UserId, Pid, SessionId, _}) ->
            case erlang:is_process_alive(Pid) of
                true ->
                    send_msg(Pid, Msg),
                    MessageEntry = #message_entry{
                        counter = 1,
                        session_id = SessionId,
                        user_id = UserId,
                        bucket_id = BucketId,
                        atomic_id = AtomicId,
                        pid = Pid,
                        message = Msg
                    },
                    light_ets:store_message(MessageEntry);
                false ->
                    ?WARN("[events_server] Subscriber ~p (pid ~p) is dead", [UserId, Pid])
            end
        end, Subscribers).

send_msg(Pid, Msg) ->
    try
        Pid ! {events_server, utils:to_binary(Msg)},
        ?INFO("[events_server] Sent message to ~p", [Pid])
    catch
        error:Reason ->
            ?ERROR("[events_server] Failed to send message to ~p: ~p", [Pid, Reason])
    end.
