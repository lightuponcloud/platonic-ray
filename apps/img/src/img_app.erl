-module(img_app).
-behaviour(application).

-export([start/0, stop/0, start/2, stop/1]).

start() ->
    application:start(img).

stop() ->
    application:stop(img).

start(_Type, _Args) ->
    img_sup:start_link().

stop(_State) ->
    ok.
