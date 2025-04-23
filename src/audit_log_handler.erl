%%
%% Retrieves logged actions from S3.
%%
-module(audit_log_handler).
-behavior(cowboy_handler).

-export([init/2, content_types_provided/2, to_json/2, allowed_methods/2,
	forbidden/2, resource_exists/2, previously_existed/2]).

-include("storage.hrl").
-include("entities.hrl").

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

%%
%% Called first
%%
allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>], Req, State}.


content_types_provided(Req, State) ->
    {[
	{{<<"application">>, <<"json">>, '*'}, to_json}
    ], Req, State}.

%%
%% Returns list of actions in pseudo-directory. If object_key specified, returns object history.
%%
to_json(Req0, State) ->
    BucketId = proplists:get_value(bucket_id, State),
    Prefix = proplists:get_value(prefix, State),

    Bits = string:tokens(BucketId, "-"),
    BucketTenantId = string:to_lower(lists:nth(2, Bits)),

    {{Year, Month, Day}, {_H, _M, _S}} = calendar:now_to_universal_time(os:timestamp()),
    LogPath1 = io_lib:format("~s/~4.10.0B/~2.10.0B/~2.10.0B_~s.jsonl",
                             [BucketTenantId, Year, Month, Day, EventId]),

    case s3_api:get_object(?AUDIT_LOG_PREFIX) of
	{error, Reason} ->
	    lager:error("[admin_tenants_handler] get_object error ~p/~p: ~p",
			[?SECURITY_BUCKET_NAME, PrefixedTenantId, Reason]),
	    not_found;
	not_found -> not_found;
	Response ->
	    %% TODO
    end


%%
%% Checks if provided token is correct.
%% ( called after 'allowed_methods()' )
%%
forbidden(Req0, _State) ->
    PathInfo = cowboy_req:path_info(Req0),
    ParsedQs = cowboy_req:parse_qs(Req0),
    BucketId =
	case lists:nth(1, PathInfo) of
	    undefined -> undefined;
	    <<>> -> undefined;
	    BV -> erlang:binary_to_list(BV)
	end,
    Prefix =
	case length(PathInfo) < 2 of
	    true -> undefined;
	    false ->
		%% prefix should go just after bucket id
		erlang:binary_to_list(utils:join_binary_with_separator(lists:nthtail(1, PathInfo), <<"/">>))
	end,
    PresentedSignature =
	case proplists:get_value(<<"signature">>, ParsedQs) of
	    undefined -> undefined;
	    Signature -> unicode:characters_to_list(Signature)
	end,
    case download_handler:has_access(Req0, BucketId, Prefix, undefined, PresentedSignature) of
	{error, Number} -> js_handler:unauthorized(Req0, Number, stop);
	{BucketId, Prefix, _ObjectKey, User} ->
	    {false, Req0, [
		{bucket_id, BucketId},
		{prefix, Prefix},
		{parsed_qs, ParsedQs},
		{user, User}
	    ]}
    end.

%%
%% Validates request parameters
%% ( called after 'content_types_provided()' )
%%
resource_exists(Req0, State) ->
    {true, Req0, State}.

previously_existed(Req0, _State) ->
    {false, Req0, []}.
