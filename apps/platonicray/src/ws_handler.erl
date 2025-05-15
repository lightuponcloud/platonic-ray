-module(ws_handler).

%% Cowboy callbacks
-export([init/2, websocket_handle/2, websocket_info/2, websocket_init/1]).
-export([content_types_provided/2, to_json/2, terminate/3]).

-include_lib("common_lib/include/log.hrl").
-include_lib("common_lib/include/entities.hrl").
-include_lib("common_lib/include/general.hrl").

%% Ping interval in milliseconds
-define(PING_INTERVAL, 30000). % 30 seconds

%% State record for clarity and extensibility
-record(state, {
    user_id = undefined :: string() | undefined,
    session_id = undefined :: string() | undefined
}).

content_types_provided(Req, State) ->
    {[
      {{<<"application">>, <<"json">>, '*'}, to_json}
     ], Req, State}.

to_json(Req0, _State) -> {<<>>, Req0, []}.

init(Req0, _Opts) ->
    %% Set CORS headers
    Req1 = cowboy_req:set_resp_header(<<"access-control-allow-methods">>, <<"GET, OPTIONS">>, Req0),
    Req2 = cowboy_req:set_resp_header(<<"access-control-allow-origin">>, <<"*">>, Req1),
    {cowboy_websocket, Req2, #state{}}.

websocket_init(State) ->
    %% Start ping timer
    erlang:start_timer(?PING_INTERVAL, self(), ping),
    {ok, State}.

validate_binary(Bin) when is_binary(Bin), byte_size(Bin) > 0 -> true;
validate_binary(_) -> false.

parse_message(<<"CONFIRM ", _AtomicId/binary>>, #state{user_id = undefined} = State) ->
    ?INFO("[ws_handler] Confirmation attempted without login"),
    {ok, State};
parse_message(<<"CONFIRM ", AtomicId/binary>>, #state{user_id = UserId, session_id = SessionId} = State) ->
    case validate_binary(AtomicId) of
        true ->
            events_server:confirm_reception(utils:to_list(AtomicId), UserId, SessionId),
            {ok, State};
        false ->
            ?WARNING("[ws_handler] Invalid AtomicId: ~p", [AtomicId]),
            {ok, State}
    end;
parse_message(<<"Authorization ", Token0/binary>>, State) ->
    case validate_binary(Token0) of
        true ->
            Token1 = utils:to_list(Token0),
            case login_handler:check_token(Token1) of
                not_found ->
                    ?INFO("[ws_handler] Authentication failed for token ~p: not_found", [Token1]),
                    {ok, State};
                expired ->
                    ?INFO("[ws_handler] Authentication failed for token ~p: expired", [Token1]),
                    {ok, State};
                User0 ->
                    ?INFO("[ws_handler] Authentication passed for user ~p", [User0#user.id]),
                    {ok, State#state{user_id = User0#user.id, session_id = Token1}}
            end;
        false ->
            ?WARNING("[ws_handler] Invalid token"),
            {ok, State}
    end;
parse_message(<<"SUBSCRIBE ", _BucketIdList/binary>>, #state{user_id = undefined} = State) ->
    ?INFO("[ws_handler] Subscription attempted without login"),
    {ok, State};
parse_message(<<"SUBSCRIBE ", BucketIdList0/binary>>, #state{user_id = UserId, session_id = SessionId} = State) ->
    case validate_binary(BucketIdList0) of
	true ->
	    BucketIdList1 = binary:split(BucketIdList0, <<" ">>, [global]),
	    BucketIdList2 = [erlang:binary_to_list(B) || B <- BucketIdList1, validate_binary(B)],
	    case BucketIdList2 of
		[] ->
		    ?WARNING("[ws_handler] Empty or invalid bucket list"),
		    {ok, State};
		_ ->
		    case events_server:new_subscriber(UserId, self(), SessionId, BucketIdList2) of
			ok -> {ok, State};
			{error, Reason} ->
			    ?ERROR("[ws_handler] Subscription failed: ~p", [Reason]),
			    {ok, State}
		    end
	    end;
	false ->
	    ?WARNING("[ws_handler] Invalid bucket list"),
	    {ok, State}
    end;
parse_message(Data, State) ->
    ?WARNING("[ws_handler] Unrecognized message: ~p", [Data]),
    {ok, State}.

%% Handle WebSocket frames
websocket_handle(ping, State) ->
    {reply, pong, State};
websocket_handle({ping, Data}, State) ->
    {reply, {pong, Data}, State};
websocket_handle(pong, State) ->
    {ok, State};
websocket_handle({pong, _Data}, State) ->
    {ok, State};
websocket_handle({text, Data}, State) ->
    parse_message(Data, State);
websocket_handle(Frame, State) ->
    ?WARNING("[ws_handler] Unhandled frame: ~p", [Frame]),
    {ok, State}.

%% Handle Erlang messages
websocket_info({timeout, _Ref, ping}, State) ->
    erlang:start_timer(?PING_INTERVAL, self(), ping),
    {reply, {ping, <<>>}, State};
websocket_info({events_server, flush}, State) ->
    %% Ensure all pending messages are processed by relying on Cowboy's synchronous handling
    events_server ! {flushed, self()},
    {ok, State};
websocket_info({events_server, stop}, State) ->
    {stop, State};
websocket_info({events_server, Data}, State) ->
    {reply, {binary, Data}, State};
websocket_info(Info, State) ->
    ?WARNING("[ws_handler] Unhandled info: ~p", [Info]),
    {ok, State}.

terminate(Reason, PartialReq, #state{user_id = UserId, session_id = SessionId}) ->
    case UserId of
        undefined ->
            ?INFO("[ws_handler] Terminating, reason: ~p, req: ~p", [Reason, PartialReq]);
        _ ->
            ?INFO("[ws_handler] Terminating for user ~s, reason: ~p, req: ~p", [UserId, Reason, PartialReq])
    end,
    case SessionId of
        undefined -> ok;
        _ -> events_server:logout_subscriber(SessionId)
    end,
    ok.
