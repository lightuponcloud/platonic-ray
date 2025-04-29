%%
%% brand_name
%%	Name that appears in title of index.html
%%
%% domain
%%	FQDN you are going to use. Used to set cookies
%% session_cookie_name
%%      Authentication cookie name, that you can change
%%      in case it conflicts with another web application.
%%
%% csrf_cookie_name
%%	You can change that in case of conflicts with another app
%%
%% root_path
%%	Root path of this application on web server. Used in JavaScript.
%%
%% static_root
%%	URI where static files are available
%%
%% listen_port
%%	Port number for Cowboy to listen on
%%
-type general_settings() :: #{
    version => string(),
    brand_name => string(),
    admin_email => string(),
    domain => string(),
    session_cookie_name => atom(),
    csrf_cookie_name => atom(),
    root_path => string(),
    static_root => string(),
    http_listen_port => integer(),
    locale => string(),
    admin_api_key => string() %% If set, admin key allows applications to perform CRUD operations on tenants and users.

}.

-record(general_settings, {
    version="0.1"::string(),
    brand_name="LightUponCloud"::string(),
    admin_email="support@xentime.com"::string(),
    session_cookie_name=midsessionid::atom(),
    root_path="/riak/"::string(),
    static_root="/riak-media/"::string(),  %% This default path is used when STATIC_BASE_URL env var is not set
    http_listen_port=8081,
    locale="uk",
    admin_api_key="NeedZojbubquilNeutmofentAvukByctansyacDuehawEbvifCecksElkiadVaijitmortOmibwieznu"
}).

-define(DEFAULT_LANGUAGE_TAG, "en").

-define(SCOPE_PG, pubsub).
