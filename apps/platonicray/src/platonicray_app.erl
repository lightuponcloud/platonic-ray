%%%-------------------------------------------------------------------
%% @doc platonicray public API
%% @end
%%%-------------------------------------------------------------------

-module(platonicray_app).

-behaviour(application).

-export([start/2, stop/1]).


-include_lib("common_lib/include/storage.hrl").
-include_lib("common_lib/include/general.hrl").

start(_Type, _Args) ->
    PrivDir = code:priv_dir(platonicray),

    Dispatch = cowboy_router:compile([
	{'_', [
	    {"/riak/static/[...]", cowboy_static, {dir, PrivDir, [{mimetypes, cow_mimetypes, all}]}},
	    {"/riak/list/[...]", list_handler, []},
	    {"/riak/object/[...]", object_handler, []},
	    {"/riak/download/[...]", download_handler, []},
	    {"/riak/download-zip/[...]", zip_stream_handler, []},
	    {"/riak/thumbnail/[...]", img_scale_handler, []},
	    {"/riak/video/[:bucket_id]/", video_handler, []},
	    {"/riak/version/[...]/", version_handler, []},

	    {"/riak/upload/[:bucket_id]/", upload_handler, []},
	    {"/riak/upload/[:bucket_id]/[:upload_id]/[:part_num]/", upload_handler, []},

	    {"/riak/copy/[:src_bucket_id]/", copy_handler, []},
	    {"/riak/move/[:src_bucket_id]/", move_handler, []},
	    {"/riak/rename/[...]/", rename_handler, []},

	    {"/riak/audit-log/[...]", audit_log_handler, []},
	    {"/riak-search/", search_handler, []},

	    {"/riak/admin/users/", admin_users_handler, []},
	    {"/riak/admin/[:tenant_id]/users/", admin_users_handler, []},
	    {"/riak/admin/[:tenant_id]/users/[:user_id]/", admin_users_handler, []},
	    {"/riak/admin/tenants/", admin_tenants_handler, []},
	    {"/riak/admin/tenants/[:tenant_id]/", admin_tenants_handler, []},

	    {"/riak/login/", login_handler, []},
	    {"/riak/logout/", logout_handler, []},

	    {"/riak/health/", health_handler, []},
	    {"/riak/js/", js_handler, []},
	    {"/riak/js/[:bucket_id]/", js_handler, []},
	    {"/riak/", first_page_handler, []},
	    {"/riak/websocket", ws_handler, []},
	    {"/riak/[:bucket_id]/", first_page_handler, []}
	]}
    ]),
    Settings = utils:read_config(platonicray),
    %% idle_timeout is set to make sure client has enough time to download big file
    {ok, _} = cowboy:start_clear(platonicray_http_listener,
	[{port, Settings#general_settings.http_listen_port},
	 {max_connections, infinity}],
	#{env => #{
	    dispatch => Dispatch
	}}),

    light_ets:start_link(),  %% used for logging, lowercase transformation, pubsub
    audit_log:start_link(),
    sqlite_server:start_link(),  %% Puts changes to SQLite DB
    copy_server:start_link(),    %% Performs time-consuming copy/move operations
    cleaner:start_link(),        %% Removes expired tokens
    platonicray_sup:start_link().

stop(_State) -> ok.
