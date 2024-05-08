%%
%% Renders first page template if user is logged in.
%% Otherwise displays login page.
%%
-module(first_page_handler).

-export([init/2, allowed_methods/2, login/2, forbidden_response/1,
	 content_types_accepted/2, bad_request/1]).

-include("general.hrl").
-include("riak.hrl").
-include("entities.hrl").


init(Req0, _Opts) ->
    Settings0 = #general_settings{},
    SessionCookieName = Settings0#general_settings.session_cookie_name,
    #{SessionCookieName := SessionID0} = cowboy_req:match_cookies([{SessionCookieName, [], undefined}], Req0),
    SessionID1 =
	case SessionID0 of
	    [H|_] -> H;
	    _ -> SessionID0
	end,

    StaticRoot =
	case os:getenv("STATIC_BASE_URL") of
	    false ->  Settings0#general_settings.static_root;
	    V -> V
	end,
    Settings1 = Settings0#general_settings{static_root = StaticRoot},
    case login_handler:check_session_id(SessionID1) of
	false -> login(Req0, Settings1);
	{error, Code} -> js_handler:incorrect_configuration(Req0, Code);
	User ->
	    TenantId = User#user.tenant_id,
	    Bits0 = [?RIAK_BACKEND_PREFIX, TenantId, ?PUBLIC_BUCKET_SUFFIX],
	    PublicBucketId = lists:flatten(utils:join_list_with_separator(Bits0, "-", [])),
	    Bits1 = [?RIAK_BACKEND_PREFIX, TenantId, ?RESTRICTED_BUCKET_SUFFIX],
	    TenantBucketId = lists:flatten(utils:join_list_with_separator(Bits1, "-", [])),
	    State = admin_users_handler:user_to_proplist(User)
		++ [{token, SessionID1}, {public_bucket_id, PublicBucketId},
		    {tenant_bucket_id, TenantBucketId}],
	    first_page(Req0, Settings1, State)
    end.

%%
%% Called first
%%
allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>], Req, State}.

bad_request(Req0) ->
    Req1 = cowboy_req:reply(400, #{
	<<"content-type">> => <<"text/html">>
    }, Req0),
    {stop, Req1, []}.

content_types_accepted(Req, State) ->
    case cowboy_req:method(Req) of
	<<"POST">> -> {[{{<<"application">>, <<"x-www-form-urlencoded">>, '*'}, handle_post}], Req, State};
	_ -> {[{{<<"application">>, <<"x-www-form-urlencoded">>, '*'}, bad_request}], Req, State}
    end.

forbidden_response(Req0) ->
    {ok, Body} = forbidden_dtl:render([]),
    Req1 = cowboy_req:reply(403, #{
	<<"content-type">> => <<"text/html">>
    }, unicode:characters_to_binary(Body), Req0),
    {stop, Req1, []}.


validate_post(Req0) ->
    %% Same-domain requests should have referer set ( very rarely absent )
    case cowboy_req:header(<<"referer">>, Req0) of
	undefined -> false;
	_ ->
	    {ok, KeyValues, _} = cowboy_req:read_urlencoded_body(Req0),
	    %% Check CSRF token from body of POST request
	    CSRFToken0 = proplists:get_value(<<"csrf_token">>, KeyValues),
	    case login_handler:check_csrf_token(CSRFToken0) of
		{error, _} -> false;
		false -> false;
		true -> {
			    proplists:get_value(<<"login">>, KeyValues),
			    proplists:get_value(<<"password">>, KeyValues)
		        }
	    end
    end.

-spec error_response(any(), #general_settings{}) -> any().

error_response(Req0, Settings) ->
    CSRFToken0 = login_handler:new_csrf_token(),
    {ok, Body} = login_dtl:render([
	{static_root, Settings#general_settings.static_root},
	{root_path, Settings#general_settings.root_path},
	{csrf_token, CSRFToken0},
	{error, "Incorrect Credentials"}
    ]),
    Req1 = cowboy_req:reply(200, #{
	<<"content-type">> => <<"text/html">>
    }, unicode:characters_to_binary(Body), Req0),
    {ok, Req1, []}.


login(Req0, Settings) ->
    case cowboy_req:method(Req0) of
	<<"GET">> ->
	    CSRFToken0 = login_handler:new_csrf_token(),
	    {ok, Body} = login_dtl:render([
		{static_root, Settings#general_settings.static_root},
		{root_path, Settings#general_settings.root_path},
		{csrf_token, CSRFToken0}
	    ]),
	    SessionCookieName = utils:to_binary(Settings#general_settings.session_cookie_name),
	    Req1 = cowboy_req:reply(200, #{
		<<"content-type">> => <<"text/html">>,
		<<"Set-Cookie">> => <<SessionCookieName/binary, "=deleted; Version=1; Expires=Thu, 01-Jan-1970 00:00:01 GMT">>
	    }, unicode:characters_to_binary(Body), Req0),
	    {ok, Req1, []};
	<<"POST">> ->
	    case validate_post(Req0) of
		false -> forbidden_response(Req0);
		{Login, Password} ->
		    case login_handler:check_credentials(Login, Password) of
			false -> error_response(Req0, Settings);
			not_found -> error_response(Req0, Settings);
			User ->
			    UUID4 = login_handler:new_token(User#user.id, User#user.tenant_id),
			    State = admin_users_handler:user_to_proplist(User) ++ [{token, UUID4}],
			    %% Set Session ID cookie
			    %% If HTTPS is used, add secure => true
			    SessionCookieName = utils:to_binary(Settings#general_settings.session_cookie_name),
			    Req1 = cowboy_req:set_resp_cookie(SessionCookieName,
				UUID4, Req0, #{max_age => ?SESSION_EXPIRATION_TIME}),
			    first_page(Req1, Settings, State)
		    end
	    end
    end.

first_page(Req0, Settings, State) ->
    BucketId0 =
	case cowboy_req:binding(bucket_id, Req0) of
	    undefined -> undefined;
	    BV -> erlang:binary_to_list(BV)
	end,
    ParsedQs = cowboy_req:parse_qs(Req0),
    Prefix0 =
	case list_handler:validate_prefix(BucketId0, proplists:get_value(<<"prefix">>, ParsedQs)) of
	    {error, _} -> not_found;
	    Prefix1 -> Prefix1
	end,
    UserGroups = proplists:get_value(groups, State),
    BucketId1 =
	case BucketId0 =:= undefined of
	    true ->
		case lists:any(fun(_) -> true end, UserGroups) of
		    true ->
			%% Display the first bucket in list
			Group = lists:nth(1, UserGroups),
			GroupId = erlang:binary_to_list(proplists:get_value(id, Group)),
			TenantId0 = erlang:binary_to_list(proplists:get_value(tenant_id, State)),
			Bits0 = [?RIAK_BACKEND_PREFIX, TenantId0, GroupId, ?RESTRICTED_BUCKET_SUFFIX],
			lists:flatten(utils:join_list_with_separator(Bits0, "-", []));
		    false -> undefined
		end;
	    false -> BucketId0
	end,
    case BucketId1 =:= undefined orelse Prefix0 =:= not_found of
	true ->
	    {ok, Body} = not_found_dtl:render([
		{brand_name, Settings#general_settings.brand_name}
	    ]),
	    Req1 = cowboy_req:reply(404, #{
		<<"content-type">> => <<"text/html">>
	    }, unicode:characters_to_binary(Body), Req0),
	    {ok, Req1, []};
	false ->
	    Locale = Settings#general_settings.locale,
	    TenantId1 = erlang:binary_to_list(proplists:get_value(tenant_id, State)),
	    Bits1 = [?RIAK_BACKEND_PREFIX, TenantId1, ?PUBLIC_BUCKET_SUFFIX],
	    PublicBucketId = lists:flatten(utils:join_list_with_separator(Bits1, "-", [])),
	    Title =
		case Prefix0 of
		    undefined -> "Files";
		    _ -> utils:unhex_path(Prefix0)
		end,
	    {ok, Body} = index_dtl:render([
		{title, Title},
		{hex_prefix, Prefix0},
		{bucket_id, BucketId1},
		{brand_name, Settings#general_settings.brand_name},
		{static_root, Settings#general_settings.static_root},
		{root_path, Settings#general_settings.root_path},
		{bucket_suffix, ""},
		{private_suffix, ?PRIVATE_BUCKET_SUFFIX},
		{public_suffix, ?PUBLIC_BUCKET_SUFFIX},
		{public_bucket_id, PublicBucketId}
	    ] ++ State, [{translation_fun, fun utils:translate/2}, {locale, Locale}]),
	    Req1 = cowboy_req:reply(200, #{
		<<"content-type">> => <<"text/html">>
	    }, unicode:characters_to_binary(Body), Req0),
	    {ok, Req1, []}
    end.
