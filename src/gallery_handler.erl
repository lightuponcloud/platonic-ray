%%
%% Gallery handler renders HTML page with images of public bucket.
%%
-module(gallery_handler).

-export([init/2]).

-include("general.hrl").
-include("riak.hrl").
-include("entities.hrl").


init(Req0, _Opts) ->
    BucketId =
	case cowboy_req:binding(bucket_id, Req0) of
	    undefined -> undefined;
	    BV -> erlang:binary_to_list(BV)
	end,
    ParsedQs = cowboy_req:parse_qs(Req0),
    Prefix0 =
	case list_handler:validate_prefix(BucketId, proplists:get_value(<<"prefix">>, ParsedQs)) of
	    {error, _} -> not_found;
	    P -> P
	end,
    Settings0 = #general_settings{},
    StaticRoot =
	case os:getenv("STATIC_BASE_URL") of
	    false ->  Settings0#general_settings.static_root;
	    V -> V
	end,
    Settings1 = Settings0#general_settings{static_root = StaticRoot},
    case BucketId =:= undefined of
	true -> not_found_error(Req0);
	false ->
	    {Prefix1, DirectoryName} =
		case Prefix0 of
		    undefined -> {undefined, "Portfolio"};
		    _ ->
			BinPrefix = erlang:list_to_binary(Prefix0),
			{list_handler:prefix_lowercase(BinPrefix), lists:flatten(utils:unhex_path(utils:to_list(BinPrefix)))}
		end,
	    PrefixedIndexFilename = utils:prefixed_object_key(Prefix1, ?RIAK_INDEX_FILENAME),
	    case riak_api:get_object(BucketId, PrefixedIndexFilename) of
		{error, Reason} ->
		    lager:error("[gallery_handler] get_object error ~p/~p: ~p",
				[BucketId, PrefixedIndexFilename, Reason]),
		    not_found_error(Req0);
		not_found -> not_found_error(Req0);
		RiakResponse ->
		    List0 = erlang:binary_to_term(proplists:get_value(content, RiakResponse)),
		    List1 = proplists:get_value(list, List0),
		    List2 = [I || I <- List1, proplists:get_value(is_deleted, I) =/= true],
		    Locale = Settings1#general_settings.locale,
		    Directories0 = proplists:get_value(dirs, List0),
		    Directories1 = [I ++ [{name, lists:flatten(utils:unhex_path(utils:to_list(proplists:get_value(prefix, I))))}]
                                    || I <- Directories0, proplists:get_value(is_deleted, I) =/= true],
		    {ok, Body} = gallery_dtl:render([
			{bucket_id, BucketId},
			{hex_prefix, Prefix1},
			{brand_name, Settings1#general_settings.brand_name},
			{static_root, Settings1#general_settings.static_root},
			{root_path, Settings1#general_settings.root_path},
			{objects_list, List2},
			{directories, Directories1},
			{title, DirectoryName}
		    ], [{translation_fun, fun utils:translate/2}, {locale, Locale}]),
		    Req1 = cowboy_req:reply(200, #{
			<<"content-type">> => <<"text/html">>
		    }, unicode:characters_to_binary(Body), Req0),
		    {ok, Req1, []}
	    end
    end.


not_found_error(Req0) ->
    Settings = #general_settings{},
    {ok, Body} = not_found_dtl:render([
	{brand_name, Settings#general_settings.brand_name}
    ]),
    Req1 = cowboy_req:reply(404, #{
	<<"content-type">> => <<"text/html">>
    }, unicode:characters_to_binary(Body), Req0),
    {stop, Req1, []}.

