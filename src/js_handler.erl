%%
%% Provides javascript library with required context variables.
%%
-module(js_handler).

-export([init/2, bad_request/2, bad_request_ok/2, forbidden/3, forbidden/4,
	 unauthorized/3, unauthorized/2, not_found/1, not_found_ok/1,
	 too_many/1, too_many/2, not_modified/1, redirect_to_login/1,
	 redirect_to_login/2, incorrect_configuration/2]).

-include("general.hrl").
-include("riak.hrl").
-include("entities.hrl").

%%
%% Parse IETF language tag
%%
%% Ther's room for improvement, as it uses only 2-letter language code.
%% No variants supported. Old format not supported as well.
%%
-spec parse_language_tag(binary()) -> string().

parse_language_tag(undefined) -> ?DEFAULT_LANGUAGE_TAG;
parse_language_tag(<<>>) -> ?DEFAULT_LANGUAGE_TAG;
parse_language_tag(Code0) when erlang:is_binary(Code0) ->
    Bits0 = binary:split(Code0, <<",">>, [global]),
    case length(Bits0) of
	0 -> ?DEFAULT_LANGUAGE_TAG;
	_ ->
	    Bits1 = binary:split(lists:nth(1, Bits0), <<"-">>, [global]),
	    case length(Bits1) =:= 2 of
		false -> ?DEFAULT_LANGUAGE_TAG;
		true ->
		    Code1 = lists:nth(1, Bits1),
		    case byte_size(Code1) =:= 2 of
			true -> erlang:binary_to_list(Code1);
			false -> ?DEFAULT_LANGUAGE_TAG
		    end
	    end
    end.

decode_messages_json(Path, DefaultPath) ->
    case file:read_file(Path) of
	{ok, Content0} ->
	    case jsx:is_json(Content0) of
		{error, badarg} -> "{}";
		false -> "{}";
		true -> jsx:decode(Content0)
	    end;
	{error, _Error} ->
	    case file:read_file(DefaultPath) of
		{ok, Content1} ->
		    case jsx:is_json(Content1) of
			{error, badarg} -> "{}";
			false -> "{}";
			true -> jsx:decode(Content1)
		    end
	    end
    end.

%%
%% Returns Javascript module for UI initialization.
%%
init(Req0, Opts) ->
    BucketId =
	case cowboy_req:binding(bucket_id, Req0) of
	    undefined -> undefined;
	    Value0 -> binary_to_list(Value0)
	end,
    Settings0 = #general_settings{},
    StaticRoot =
	case os:getenv("STATIC_BASE_URL") of
	    false ->  Settings0#general_settings.static_root;
	    V -> V
	end,
    Settings1 = Settings0#general_settings{static_root = StaticRoot},
    SessionCookieName = Settings1#general_settings.session_cookie_name,
    #{SessionCookieName := SessionID0} = cowboy_req:match_cookies([{SessionCookieName, [], undefined}], Req0),
    case login_handler:check_session_id(SessionID0) of
	false -> bad_request_ok(Req0, 28);
	{error, _} -> bad_request_ok(Req0, 28);
	User ->
	    %% Since ther's no way to detect browser language preference, Accept-Language should be used instead
	    LanguageCode = parse_language_tag(cowboy_req:header(<<"accept-language">>, Req0)),
	    %% Load messages from catalog, stored in JSON file in filesystem
	    EbinDir = filename:dirname(code:which(js_handler)),
	    AppDir = filename:dirname(EbinDir),
	    MessagesFilePath = filename:join([AppDir, "priv", lists:flatten([LanguageCode, ".json"])]),
	    DefaultMessagesFilePath = filename:join([AppDir, "priv", "en.json"]),
	    JSONMessages = decode_messages_json(MessagesFilePath, DefaultMessagesFilePath),
	    {ok, Body} = jquery_riak_js_dtl:render([
		{messages, JSONMessages},
		{root_path, Settings1#general_settings.root_path},
		{static_root, Settings1#general_settings.static_root},
		{bucket_id, BucketId},
		{token, SessionID0},
		{user_id, User#user.id},
		{chunk_size, ?FILE_UPLOAD_CHUNK_SIZE}
	    ]),
	    Req1 = cowboy_req:reply(200, #{<<"content-type">> => <<"text/html">>}, unicode:characters_to_binary(Body), Req0),
	    {ok, Req1, Opts}
    end.

bad_request(Req0, MsgCode)
	when erlang:is_integer(MsgCode) orelse erlang:is_list(MsgCode) orelse erlang:is_atom(MsgCode) ->
    Req1 = cowboy_req:reply(400, #{
	<<"content-type">> => <<"application/json">>
    }, jsx:encode([{error, MsgCode}]), Req0),
    {stop, Req1, []}.

bad_request_ok(Req0, MsgCode)
	when erlang:is_integer(MsgCode) orelse erlang:is_list(MsgCode) orelse erlang:is_atom(MsgCode) ->
    Req1 = cowboy_req:reply(400, #{
	<<"content-type">> => <<"application/json">>
    }, jsx:encode([{error, MsgCode}]), Req0),
    {ok, Req1, []}.

forbidden(Req0, MsgCode, ReturnType) when erlang:is_integer(MsgCode) ->
    Req1 = cowboy_req:reply(403, #{
	<<"content-type">> => <<"application/json">>
    }, jsx:encode([{error, MsgCode}]), Req0),
    {ReturnType, Req1, []}.

forbidden(Req0, MsgCode, Groups, ReturnType) when erlang:is_integer(MsgCode), erlang:is_list(Groups) ->
    Req1 = cowboy_req:reply(403, #{
	<<"content-type">> => <<"application/json">>
    }, jsx:encode([{error, MsgCode}, {groups, Groups}]), Req0),
    {ReturnType, Req1, []}.


unauthorized(Req0, MsgCode) when erlang:is_integer(MsgCode) ->
    unauthorized(Req0, MsgCode, stop).

unauthorized(Req0, MsgCode, ReturnType) when erlang:is_integer(MsgCode) ->
    Req1 = cowboy_req:reply(401, #{
	<<"content-type">> => <<"application/json">>
    }, jsx:encode([{error, MsgCode}]), Req0),
    {ReturnType, Req1, []}.

incorrect_configuration(Req0, MsgCode) when erlang:is_list(MsgCode) ->
    Req1 = cowboy_req:reply(500, #{
	<<"content-type">> => <<"application/json">>
    }, jsx:encode([{error, erlang:list_to_binary(MsgCode)}]), Req0),
    {stop, Req1, []}.

too_many(Req0) ->
    too_many(Req0, 0).

too_many(Req0, ElapsedTime) ->
    Req1 = cowboy_req:reply(429, #{
	<<"content-type">> => <<"application/json">>,
	<<"elapsed-time">> => io_lib:format("~.2f", [utils:to_float(ElapsedTime)])
    }, jsx:encode([{error, 33}]), Req0),
    {stop, Req1, []}.

not_found(Req0) ->
    Req1 = cowboy_req:reply(404, #{
	<<"content-type">> => <<"application/json">>
    }, Req0),
    {stop, Req1, []}.

not_found_ok(Req0) ->
    Req1 = cowboy_req:reply(404, #{
	<<"content-type">> => <<"application/json">>
    }, Req0),
    {ok, Req1, []}.

not_modified(Req0) ->
    Req1 = cowboy_req:reply(304, #{
	<<"content-type">> => <<"application/json">>
    }, Req0),
    {stop, Req1, []}.

redirect_to_login(Req0) ->
    redirect_to_login(Req0, []).

redirect_to_login(Req0, Options) ->
    Settings = #general_settings{},
    Scheme = cowboy_req:scheme(Req0),
    Host = cowboy_req:host(Req0),
    Port =
	case cowboy_req:port(Req0) of
	    80 -> <<>>;
	    N when erlang:is_integer(N) ->
		P = utils:to_binary(N),
		<< <<":">>/binary, P/binary >>;
	    _ -> <<>>
	end,
    URI = utils:to_binary(Settings#general_settings.root_path),
    Headers0 = #{
	<<"Location">> => << Scheme/binary, <<"://">>/binary,
			     Host/binary, Port/binary, URI/binary >>
    },
    Headers1 =
	case proplists:is_defined(drop_cookie, Options) of
	    true ->
		SessionCookieName = utils:to_binary(proplists:get_value(drop_cookie, Options)),
		Headers0#{
		    <<"Set-Cookie">> => <<SessionCookieName/binary, "=deleted; Version=1; Expires=Thu, 01-Jan-1970 00:00:01 GMT">>
		};
	    false -> Headers0
	end,
    Req1 = cowboy_req:reply(302, Headers1, <<>>, Req0),
    {ok, Req1, []}.
