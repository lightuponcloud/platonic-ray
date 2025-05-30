%%
%% erlydtl tags, that are used from templates are defined here.
%%
-module(dtl_tags).
-behaviour(erlydtl_library).

-export([inventory/1, version/0, basename/1, even/1]).

-include_lib("common_lib/include/storage.hrl").

version() -> 1.

inventory(tags) -> [];
inventory(filters) -> [basename, even].

%% @doc Returns filename without path
-spec basename(string()|binary()) -> string().

basename(ObjectKey) when erlang:is_list(ObjectKey) ->
    filename:basename(ObjectKey);
basename(ObjectKey) when erlang:is_binary(ObjectKey) ->
    filename:basename(unicode:characters_to_list(ObjectKey)).

-spec even(list()) -> boolean().

even(Number) ->
    utils:even(utils:to_integer(Number)).
