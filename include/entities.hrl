-export_type([tenant/0, group/0, user/0, token/0, csrf_token/0, object/0]).

%% Time in miliseconds
-define(CSRF_TOKEN_EXPIRATION_TIME, 31449600000). % 1000 * 60 * 60 * 24 * 7 * 52
-define(SESSION_EXPIRATION_TIME, 86400000).  %% 24 hours

-type tenant() :: #{
    id          => string(),
    name        => string(),
    enabled     => boolean(),
    groups      => list()
}.

-type group() :: #{
    id          => string(),
    name        => string(),
    date_added  => string()
}.

-type user() :: #{
    id          => string(),
    name        => string(),
    tenant_id   => string(),
    tenant_name => string(),
    login       => string(),
    tel         => string(),
    enabled     => boolean(),
    staff       => boolean(),
    groups      => list()
}.

%%
%% Authentication token for API requests
%%
-type token() :: #{
    id          => string(),
    expires     => pos_integer() | infinity,
    user_id     => string()
}.

%%
%% CSRF token for login page
%%
-type csrf_token() :: #{
    id          => string(),
    expires     => pos_integer() | infinity
}.

-type object() :: #{
    key                 => string(),
    version             => string(),
    orig_name           => binary(),
    upload_time         => integer(),
    bytes               => integer(),
    guid                => string(),
    upload_id           => string(),
    copy_from_guid      => string(),  %% before it was copied
    copy_from_bucket_id => string(),
    is_deleted          => boolean(),
    author_id           => string(),
    author_name         => binary(),
    author_tel          => string(),
    is_locked           => boolean(),
    lock_user_id        => string(),
    lock_user_name      => binary(),
    lock_user_tel       => string(),
    lock_modified_utc   => integer(),
    md5                 => string(),
    content_type        => string()
}.

-record(tenant, {
    id          = ""::string(),
    name        = ""::string(),
    enabled     = true::boolean(),
    groups      = []::list()  %% Grous within that project
}).

-record(user, {
    id             = ""::string(),
    name           = ""::string(),
    tenant_id      = ""::string(),
    tenant_name    = ""::string(),
    tenant_enabled = true::boolean(),
    login          = ""::string(),
    tel            = ""::string(),
    salt           = ""::string(),
    password	   = ""::string(),
    hash_type      = ""::string(),
    enabled        = true::boolean(),
    staff          = false::boolean(),
    groups         = []::list()  %% Groups user belongs to
}).

-record(group, {
    id          = ""::string(),
    name        = ""::string()
}).

-record(object, {
    key                 = "",
    version             = undefined,
    orig_name           = "",
    upload_time         = undefined,
    bytes               = 0,
    guid                = undefined,
    upload_id           = undefined,
    copy_from_guid      = undefined,
    copy_from_bucket_id = undefined,
    is_deleted          = false,
    author_id           = undefined,
    author_name         = undefined,
    author_tel          = undefined,
    is_locked           = false,
    lock_user_id        = undefined,
    lock_user_name      = undefined,
    lock_user_tel       = undefined,
    lock_modified_utc   = undefined,
    md5                 = undefined,
    content_type        = undefined
}).

-define(AUTH_NAME, pbkdf2_sha256).

-define(ADMIN_USER, #user{
    id = lightup,
    name = administrator,
    tenant_id = lightup,
    tenant_name = lightup,
    tenant_enabled = true,
    enabled = true,
    staff = true
}).
