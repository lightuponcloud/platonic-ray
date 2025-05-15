-module(video_app).
-behaviour(application).

-export([start/0, stop/0, start/2, stop/1]).

start() ->
    application:start(video).

stop() ->
    application:stop(video).

start(_Type, _Args) ->
    video_sup:start_link().

stop(_State) ->
    ok.
