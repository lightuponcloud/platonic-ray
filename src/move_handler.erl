%%
%% Allows to move objects and pseudo-directories.
%%
-module(move_handler).
-behavior(cowboy_handler).

-export([init/2, content_types_provided/2, content_types_accepted/2,
	 to_json/2, allowed_methods/2, is_authorized/2, forbidden/2,
	 handle_post/2]).

-include("storage.hrl").
-include("entities.hrl").
-include("action_log.hrl").

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

%%
%% Returns callback 'handle_post()'
%% ( called after 'resource_exists()' )
%%
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
%% Validates POST request and sends request to Riak CS to copy objects and delete them
%%
handle_post(Req0, State0) ->
    case cowboy_req:method(Req0) of
	<<"POST">> ->
	    case copy_handler:validate_copy_parameters(State0) of
		{error, Number} -> js_handler:bad_request(Req0, Number);
		State1 -> move(Req0, State1)
	    end;
	_ -> js_handler:bad_request(Req0, 16)
    end.


move(Req0, State) ->
    SrcBucketId = proplists:get_value(src_bucket_id, State),
    SrcPrefix = proplists:get_value(src_prefix, State),
    SrcObjectKeys = proplists:get_value(src_object_keys, State),
    DstBucketId = proplists:get_value(dst_bucket_id, State),
    DstPrefix =
	case proplists:get_value(dst_prefix, State) of
	    undefined -> undefined;
	    P -> copy_handler:validate_dst_prefix(P)
	end,
    User = proplists:get_value(user, State),
    copy_server:move(SrcBucketId, DstBucketId, SrcPrefix, DstPrefix, SrcObjectKeys, User),

    Req1 = cowboy_req:reply(200, #{
	<<"content-type">> => <<"application/json">>
    }, <<"{\"status\": \"ok\"}">>, Req0),
    {stop, Req1, []}.

%%
%% Serializes response to json
%%
to_json(Req0, State) ->
    {<<"{\"status\": \"ok\"}">>, Req0, State}.

%%
%% Called first
%%
allowed_methods(Req, State) ->
    {[<<"POST">>], Req, State}.

%%
%% Checks if provided token is correct.
%% ( called after 'allowed_methods()' )
%%
is_authorized(Req0, _State) ->
    case utils:get_token(Req0) of
	undefined -> js_handler:unauthorized(Req0, 28);
	Token -> login_handler:get_user_or_error(Req0, Token)
    end.

%%
%% Checks if user has access
%% - To source bucket
%% - To destination bucket
%%
%% ( called after 'is_authorized()' )
%%
forbidden(Req0, State) ->
    copy_handler:copy_forbidden(Req0, State).
