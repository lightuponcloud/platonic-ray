%%
%% Supervises the image scaling gen_server
%%
-module(video_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 1, period => 5},
    ChildSpecs = lists:map(
        fun(PortNum) ->
            Name = list_to_atom(
                lists:flatten(io_lib:format("video_port_~p", [PortNum]))),
            #{id => Name,
              start => {video, start_link, [PortNum]},
              restart => permanent,
              shutdown => brutal_kill,
              type => worker,
              modules => [video]}
        end,
        lists:seq(1, 2)
    ),
    {ok, {SupFlags, ChildSpecs}}.
