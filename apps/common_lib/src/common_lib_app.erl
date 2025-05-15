-module(common_lib_app).
-behaviour(application).

-export([start/2, stop/1]).

-include_lib("common_lib/include/general.hrl").  %% For ?SCOPE_PG definition

start(_StartType, _StartArgs) ->
    %% Initialize the process group scope
    pg:start(?SCOPE_PG).

stop(_State) ->
    ok.
