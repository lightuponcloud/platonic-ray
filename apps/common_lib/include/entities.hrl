-export_type([tenant/0, group/0, user/0, token/0, csrf_token/0, object/0]).

%% Time in miliseconds
-define(CSRF_TOKEN_EXPIRATION_TIME, 31449600000). % 1000 * 60 * 60 * 24 * 7 * 52
-define(SESSION_EXPIRATION_TIME, 86400000).  %% 24 hours

-type tenant() :: #{
    id          => string(),
    name        => string(),
    enabled     => boolean(),
    groups      => list(),
    api_key     => string()
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
    groups      = []::list(),  %% Grous within that project
    api_key     = ""::string()
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

%% Message entry, contains the counter ( number of attempts ),
%% pid ( to send terminate signal to ) and the message itself.
-record(message_entry, {
    counter = 0 :: integer(),
    session_id = undefined :: string() | undefined,
    user_id = undefined :: string() | undefined,
    bucket_id = undefined :: string() | undefined,
    atomic_id = undefined :: string() | undefined,
    pid = undefined :: pid() | undefined,
    message = undefined :: binary() | undefined
}).

-define(AUTH_NAME, pbkdf2_sha256).

-define(ADMIN_USER, #user{
    id = "lightup",
    name = "41646d696e6973747261746f72",
    tenant_id = "lightup",
    tenant_name = "4c696768745570",
    tenant_enabled = true,
    enabled = true,
    staff = true
}).

%%
%% The following user is used when actions are performed using signatures
%%
-define(ANONYMOUS_USER, #user{
    id = "anonymous",
    name = "416e6f6e796d6f7573",
    tenant_id = undefined,
    tenant_name = undefined,
    tenant_enabled = true,
    enabled = true,
    staff = false
}).
