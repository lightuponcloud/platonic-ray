%%
%% API endpoints for login and other user-related logic
%%
-module(login_handler).
-behavior(cowboy_handler).

-export([init/2, content_types_provided/2, content_types_accepted/2,
	 allowed_methods/2, to_json/2, handle_post/2, new_token/2,
	 check_token/1, check_credentials/2, new_csrf_token/0,
	 check_csrf_token/1, check_session_id/1, get_user_or_error/2]).

-include_lib("xmerl/include/xmerl.hrl").
-include("riak.hrl").
-include("entities.hrl").

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

%%
%% Returns User if password match what's in DB.
%% Otherwise returns false
%%
-spec check_credentials(binary(), binary()) -> boolean()|not_found|blocked.

check_credentials(<<>>, _Password) -> false;
check_credentials(null, _Password) -> false;
check_credentials(undefined, _Password) -> false;
check_credentials(_Login, <<>>) -> false;
check_credentials(_Login, undefined) -> false;
check_credentials(_Login, null) -> false;
check_credentials(Login, Password)
	when erlang:is_binary(Login), erlang:is_binary(Password) ->
    UserId = utils:hex(erlang:md5(Login)),
    case admin_users_handler:get_user(UserId) of
	not_found -> not_found;
	User ->
	    case User#user.enabled of
		false -> blocked;
		true ->
		    Salt = utils:unhex(utils:to_binary(User#user.salt)),
		    HashedPassword = User#user.password,
		    IsPwdCorrect = riak_crypto:check_password(Password, HashedPassword, Salt),
		    case IsPwdCorrect of
			true -> User;
			false -> false
		    end
	    end
    end.

%%
%% Adds a new authentication token. TODO: add expiration time.
%%
-spec new_token(string(), string()) -> token().

new_token(UserId, TenantId) ->
    case riak_api:head_bucket(?SECURITY_BUCKET_NAME) of
	not_found -> riak_api:create_bucket(?SECURITY_BUCKET_NAME);
        _ -> ok
    end,
    ExpirationTime0 = utils:timestamp() + ?SESSION_EXPIRATION_TIME,
    ExpirationTime1 = io_lib:format("~p", [ExpirationTime0]),
    NewToken = {token, [
	{expires, [ExpirationTime1]},
	{user_id, [UserId]},
	{tenant_id, [TenantId]}
    ]},
    RootElement0 = #xmlElement{name=auth, content=[NewToken]},
    XMLDocument0 = xmerl:export_simple([RootElement0], xmerl_xml),
    UUID4 = utils:to_list(riak_crypto:uuid4()),
    Response = riak_api:put_object(?SECURITY_BUCKET_NAME, ?TOKEN_PREFIX, UUID4,
				   unicode:characters_to_binary(XMLDocument0)),
    case Response of
	{error, Reason} ->
	    lager:error("[login_handler] Can't put object ~p/~p/~p: ~p", 
			[?SECURITY_BUCKET_NAME, ?TOKEN_PREFIX, UUID4, Reason]),
	    throw("Can't issue tocket at this time.");
	_ -> UUID4
    end.

%%
%% Adds a new CSRF token
%%
-spec new_csrf_token() -> token().

new_csrf_token() ->
    case riak_api:head_bucket(?SECURITY_BUCKET_NAME) of
        not_found -> riak_api:create_bucket(?SECURITY_BUCKET_NAME);
        _ -> ok
    end,
    ExpirationTime0 = utils:timestamp() + ?CSRF_TOKEN_EXPIRATION_TIME,
    ExpirationTime1 = io_lib:format("~p", [ExpirationTime0]),
    NewCSRFToken = {token, [{expires, [ExpirationTime1]}]},

    RootElement0 = #xmlElement{name=auth, content=[NewCSRFToken]},
    XMLDocument0 = xmerl:export_simple([RootElement0], xmerl_xml),
    UUID4 = utils:to_list(riak_crypto:uuid4()),
    Response = riak_api:put_object(?SECURITY_BUCKET_NAME, ?CSRF_TOKEN_PREFIX, UUID4,
	unicode:characters_to_binary(XMLDocument0)),
    case Response of
	{error, Reason} ->
	    lager:error("[login_handler] Can't put object ~p/~p/~p: ~p",
			[?SECURITY_BUCKET_NAME, ?CSRF_TOKEN_PREFIX, UUID4, Reason]),
	    throw("Can't issue CSRF token at this time");
	_ -> UUID4
    end.

%%
%% Checks if CSRF token exists and has not expired.
%%
-spec check_csrf_token(string()) -> boolean().

check_csrf_token(undefined) -> false;
check_csrf_token(UUID4) when erlang:is_binary(UUID4) ->
    case check_cookie(UUID4) of
	false -> false;
	CookieValue ->
	    PrefixedToken = utils:prefixed_object_key(?CSRF_TOKEN_PREFIX,
		erlang:binary_to_list(CookieValue)),
	    case riak_api:get_object(?SECURITY_BUCKET_NAME, PrefixedToken) of
		{error, Reason} ->
		    lager:error("[login_handler] get_object error ~p/~p: ~p",
				[?SECURITY_BUCKET_NAME, PrefixedToken, Reason]),
		    false;
		not_found -> false;
		TokenObject ->
		    %% Check for error in response first
		    XMLDocument0 = utils:to_list(proplists:get_value(content, TokenObject)),
		    {RootElement0, _} = xmerl_scan:string(XMLDocument0),
		    case string:str(XMLDocument0, "<Error><Code>") of
			0 ->
			    {RootElement, _} = xmerl_scan:string(XMLDocument0),
			    ExpirationTime0 = erlcloud_xml:get_text("/auth/token/expires", RootElement),
			    ExpirationTime1 = utils:to_integer(ExpirationTime0),
			    utils:timestamp() - ExpirationTime1 < 0;
			_ ->
			    ErrorCode = erlcloud_xml:get_text("/Error/Code", RootElement0),
			    {error, ErrorCode}
		    end
	    end
    end.

%%
%% 1. Checks if token exists and has not expired.
%% 2. Returns user record with his actual existing groups.
%% 3. Updates token expiration time
%%
-spec check_token(string()) -> user()|not_found|expired.

check_token(UUID4) when erlang:is_list(UUID4) ->
    PrefixedToken = utils:prefixed_object_key(?TOKEN_PREFIX, UUID4),
    case riak_api:get_object(?SECURITY_BUCKET_NAME, PrefixedToken) of
	{error, Reason} ->
	    lager:error("[login_handler] get_object error ~p/~p: ~p",
			[?SECURITY_BUCKET_NAME, PrefixedToken, Reason]),
	    not_found;
	not_found -> not_found;
	TokenObject ->
	    %% Check for error in response first
	    XMLDocument0 = utils:to_list(proplists:get_value(content, TokenObject)),
	    {RootElement0, _} = xmerl_scan:string(XMLDocument0),
	    case string:str(XMLDocument0, "<Error><Code>") of
		0 ->
		    ExpirationTime0 = erlcloud_xml:get_text("/auth/token/expires", RootElement0),
		    ExpirationTime1 = utils:to_integer(ExpirationTime0),
		    case utils:timestamp() - ExpirationTime1 < 0 of
			false -> expired;
			true ->
			    UserId = erlcloud_xml:get_text("/auth/token/user_id", RootElement0),
			    TenantId = erlcloud_xml:get_text("/auth/token/tenant_id", RootElement0),

			    %% Extend the expiration time
			    ExpirationTime2 = utils:timestamp() + ?SESSION_EXPIRATION_TIME,
			    NewToken = {token, [
				{expires, [io_lib:format("~p", [ExpirationTime2])]},
				{user_id, [UserId]},
				{tenant_id, [TenantId]}
			    ]},
			    RootElement1 = #xmlElement{name=auth, content=[NewToken]},
			    XMLDocument1 = xmerl:export_simple([RootElement1], xmerl_xml),
			    Response = riak_api:put_object(?SECURITY_BUCKET_NAME, ?TOKEN_PREFIX, UUID4,
				unicode:characters_to_binary(XMLDocument1)),
			    case Response of
				{error, Reason} -> lager:error("[login_handler] Can't put object ~p/~p/~p: ~p", 
				       [?SECURITY_BUCKET_NAME, ?TOKEN_PREFIX, UUID4, Reason]);
				_ -> ok
			    end,
			    admin_users_handler:get_user(UserId)
		    end;
		_ ->
		    ErrorCode = erlcloud_xml:get_text("/Error/Code", RootElement0),
		    {error, ErrorCode}
	    end
    end.

%%
%% Checks if provided cookie value lengths is 36 characters
%%
-spec check_cookie(binary()) -> boolean().

check_cookie(CookieValue0) when erlang:is_list(CookieValue0) ->
    %% Session ID and CSRF token might consist of several keys
    %% in case when several cookies with the same name were set
    %% by another web app running on the same domain
    case [I || I <- CookieValue0, byte_size(I) =:= 36] of
	[] -> false;
	List -> lists:nth(1, List)  %% take the first one
    end;

check_cookie(CookieValue0) when erlang:is_binary(CookieValue0) ->
    case byte_size(CookieValue0) =:= 36 of
	true -> CookieValue0;
	false -> false
    end.

%%
%% Checks if provided session ID exists in security bucket
%%
-spec check_session_id(binary()) -> boolean().

check_session_id(undefined) -> false;

check_session_id(SessionID0) when erlang:is_binary(SessionID0) ->
    case check_cookie(SessionID0) of
	false -> false;
	CookieValue ->
	    case check_token(erlang:binary_to_list(CookieValue)) of
		not_found -> false;
		expired -> false;
		{error, Code} -> {error, Code};
		User -> User
	    end
    end.

%%
%% Called first
%%
allowed_methods(Req, State) ->
    {[<<"POST">>], Req, State}.

content_types_accepted(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, handle_post}], Req, State}.

%%
%% Returns callback 'to_json()'
%% ( called after 'forbidden()' )
%%
content_types_provided(Req, State) ->
    {[
	{{<<"application">>, <<"json">>, []}, to_json}
    ], Req, State}.

%%
%% Serializes response to json
%%
to_json(Req0, State) ->
    {jsx:encode(State), Req0, State}.


handle_post(Req0, _State) ->
    case cowboy_req:method(Req0) of
	<<"POST">> ->
	    {ok, Body, _Req1} = cowboy_req:read_body(Req0),
	    case jsx:is_json(Body) of
		{error, badarg} -> js_handler:bad_request(Req0, 21);
		false -> js_handler:bad_request(Req0, 21);
		true ->
		    FieldValues = jsx:decode(Body),
		    Login = proplists:get_value(<<"login">>, FieldValues),
		    Password = proplists:get_value(<<"password">>, FieldValues),
		    case check_credentials(Login, Password) of
			false -> js_handler:forbidden(Req0, 3, stop);
			not_found -> js_handler:forbidden(Req0, 17, stop);
			blocked -> js_handler:forbidden(Req0, 19, stop);
			User0 ->
			    UUID4 = new_token(User0#user.id, User0#user.tenant_id),
			    Req1 = cowboy_req:set_resp_body(jsx:encode(
				admin_users_handler:user_to_proplist(User0) ++ [{token, erlang:list_to_binary(UUID4)}]
			    ), Req0),
			    {true, Req1, []}
		    end
	    end;
	<<"GET">> ->
	    %{ok, _Headers, Client} = oauth2c:retrieve_access_token(
	    %	<<"client_credentials">>, ?OAUTH2_TOKEN_URL, ?CONSUMER_KEY, ?CONSUMER_SECRET),
	    js_handler:bad_request(Req0, 18);
	_ -> js_handler:bad_request(Req0, 18)
    end.

%%
%% Returns User record or error, that should be returned by is_authorized function.
%%
get_user_or_error(Req0, Token) ->
    case check_token(Token) of
	not_found -> js_handler:unauthorized(Req0, 28);
	expired -> js_handler:unauthorized(Req0, 28);
	User -> {true, Req0, User}
    end.
