%%
%% Supervises the image scaling gen_server
%%
-module(img_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 1, period => 5},
    ChildSpecs = lists:map(
        fun(PortNum) ->
            Name = list_to_atom(
                lists:flatten(io_lib:format("img_port_~p", [PortNum]))),
            #{id => Name,
              start => {img, start_link, [PortNum]},
              restart => permanent,
              shutdown => brutal_kill,
              type => worker,
              modules => [img]}
        end,
        lists:seq(1, 4)
    ),
    {ok, {SupFlags, ChildSpecs}}.
