%%
%% List handler returns contetnt of index.etf
%%
-module(list_handler).
-behavior(cowboy_handler).

-export([init/2, content_types_provided/2,
    to_json/2, allowed_methods/2, forbidden/2, is_authorized/2,
    resource_exists/2, previously_existed/2]).

-include("storage.hrl").
-include("entities.hrl").
-include("general.hrl").
-include("log.hrl").

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

%%
%% Called first
%%
allowed_methods(Req, State) ->
    {[<<"GET">>], Req, State}.


content_types_provided(Req, State) ->
    {[
	{{<<"application">>, <<"json">>, '*'}, to_json}
    ], Req, State}.

to_json(Req0, State) ->
    BucketId = proplists:get_value(bucket_id, State),
    Prefix0 = proplists:get_value(prefix, State),
    Groups =
	case proplists:get_value(user, State) of
	    undefined -> [];
	    User0 ->
		User1 = admin_users_handler:user_to_proplist(User0),
		proplists:get_value(groups, User1)
	end,
    ParsedQs = proplists:get_value(parsed_qs, State, []),
    ShowDeleted =
	case proplists:is_defined(<<"show-deleted">>, ParsedQs) of
	    true ->
		case proplists:get_value(<<"show-deleted">>, ParsedQs) of
		    <<"1">> -> true;
		    <<"true">> -> true;
		    _ -> false
		end;
	    false -> false
	end,
    T0 = utils:timestamp(),
    case s3_api:head_bucket(BucketId) of
	not_found ->
	    %% Bucket is valid, but it do not exist yet
	    s3_api:create_bucket(BucketId),
	    T1 = utils:timestamp(),
	    Req1 = cowboy_req:reply(200, #{
		<<"content-type">> => <<"application/json">>,
		<<"elapsed-time">> => io_lib:format("~.2f", [utils:to_float(T1-T0)/1000])
	    }, jsx:encode([{list, []}, {dirs, []}, {groups, Groups}]), Req0),
	    {stop, Req1, []};
	_ ->
	    Prefix1 = object_handler:prefix_lowercase(Prefix0),
	    PrefixedIndexFilename = utils:prefixed_object_key(Prefix1, ?INDEX_FILENAME),
	    case s3_api:get_object(BucketId, PrefixedIndexFilename) of
		{error, Reason} ->
		    lager:warning("[list_handler] get_object error ~p/~p: ~p",
				[BucketId, PrefixedIndexFilename, Reason]),
		    T1 = utils:timestamp(),
		    Req1 = cowboy_req:reply(200, #{
			<<"content-type">> => <<"application/json">>,
			<<"elapsed-time">> => io_lib:format("~.2f", [utils:to_float(T1-T0)/1000])
		    }, jsx:encode([{list, []}, {dirs, []}, {groups, Groups}]), Req0),
		    {stop, Req1, []};
		not_found -> {jsx:encode([{list, []}, {dirs, []}, {groups, Groups}]), Req0, []};
		RiakResponse ->
		    List0 = erlang:binary_to_term(proplists:get_value(content, RiakResponse)),
		    {Dirs, Objects} =
			case ShowDeleted of
			    false ->  %% filter out objects marked as deleted
				List1 = [I || I <- proplists:get_value(list, List0),
					 proplists:get_value(is_deleted, I) =:= false],
				Dirs0 = [I || I <- proplists:get_value(dirs, List0),
					 proplists:get_value(is_deleted, I) =:= false],
				{Dirs0, List1};
			    true -> {proplists:get_value(dirs, List0), proplists:get_value(list, List0)}
			end,
		    T1 = utils:timestamp(),
		    Req1 = cowboy_req:reply(200, #{
			<<"content-type">> => <<"application/json">>,
			<<"elapsed-time">> => io_lib:format("~.2f", [utils:to_float(T1-T0)/1000])
		    }, jsx:encode([{list, Objects}, {dirs, Dirs}, {groups, Groups}]), Req0),
		    {stop, Req1, []}
	    end
    end.

%%
%% Checks if provided token is correct.
%% Extracts token from request headers and looks it up in "security" bucket.
%% ( called after 'allowed_methods()' )
%%
is_authorized(Req0, _State) ->
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
	    {true, Req0, [
		{bucket_id, BucketId},
		{prefix, Prefix},
		{parsed_qs, ParsedQs},
		{user, User}
	    ]}
    end.

%%
%% ( called after 'is_authorized()' )
%%
forbidden(Req0, State) ->
    {false, Req0, State}.

%%
%% Validates request parameters
%% ( called after 'content_types_provided()' )
%%
resource_exists(Req0, State) ->
    {true, Req0, State}.

previously_existed(Req0, _State) ->
    {false, Req0, []}.
