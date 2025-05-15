%%%-------------------------------------------------------------------
%% @doc platonicray top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(platonicray_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-spec start_link() -> {ok, pid()}.

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% sup_flags() = #{strategy => strategy(),         % optional
%%                 intensity => non_neg_integer(), % optional
%%                 period => pos_integer()}        % optional
%% child_spec() = #{id => child_id(),       % mandatory
%%                  start => mfargs(),      % mandatory
%%                  restart => restart(),   % optional
%%                  shutdown => shutdown(), % optional
%%                  type => worker(),       % optional
%%                  modules => modules()}   % optional
init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 1, period => 5},
    ChildSpecs = [#{id => solr_api,
		    start => {solr_api, start_link, []},
		    restart => permanent,
		    shutdown => 10000,
		    type => worker,
		    modules => []},
		  #{id => events_server,
		    start => {events_server, start_link, []},
		    restart => permanent,
		    shutdown => 10000,
		    type => worker,
		    modules => []}
		],
    {ok, {SupFlags, ChildSpecs}}.

%% internal functions
