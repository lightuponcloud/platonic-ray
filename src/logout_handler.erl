%%
%% Logs user out.
%%
-module(logout_handler).
-behavior(cowboy_handler).

-export([init/2]).

-include("general.hrl").
-include("storage.hrl").

%%
%% Deletes auth token from DB
%%
-spec revoke_token(binary()|list()) -> ok.

revoke_token(SessionId0) when erlang:is_binary(SessionId0) ->
    %% Revoke session id, as this is request from browser
    case login_handler:check_session_id(SessionId0) of
	false -> ok;
	{error, Code} -> {error, Code};
	_User ->
	    UUID4 = erlang:binary_to_list(SessionId0),
	    PrefixedToken = utils:prefixed_object_key(?TOKEN_PREFIX, UUID4),
	    s3_api:delete_object(?SECURITY_BUCKET_NAME, PrefixedToken),
	    ok
    end;

revoke_token(List) when erlang:is_list(List) ->
    [revoke_token(I) || I <- List];
revoke_token([]) -> ok.

init(Req0, _Opts) ->
    Settings = #general_settings{},
    SessionCookieName = Settings#general_settings.session_cookie_name,
    #{SessionCookieName := SessionId0} = cowboy_req:match_cookies([{SessionCookieName, [], undefined}], Req0),
    case SessionId0 of
	undefined ->
	    %% Try to revoke the bearer token, as this is request to REST API
	    case utils:get_token(Req0) of
		undefined -> ok;
		Token ->
		    case login_handler:check_token(Token) of
			not_found -> ok;
			expired -> revoke_token(Token);
			_User -> revoke_token(Token)
		    end
	    end,
	    Req1 = cowboy_req:reply(200, #{
		<<"content-type">> => <<"application/json">>
	    }, <<"{\"status\": \"ok\"}">>, Req0),
	    {ok, Req1, []};
	_ ->
	    case revoke_token(SessionId0) of
		ok -> js_handler:redirect_to_login(Req0, [{drop_cookie, SessionCookieName}]);
		{error, Code} -> js_handler:incorrect_configuration(Req0, Code);
		Result ->
		    case lists:keyfind(error, 1, Result) of
			{error, Code} -> js_handler:incorrect_configuration(Req0, Code);
			_ -> js_handler:redirect_to_login(Req0, [{drop_cookie, SessionCookieName}])
		    end
	    end
    end.
