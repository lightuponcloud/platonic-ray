-type proplist() :: proplists:proplist().

%%
%% Configuration variables of Riak CS connection
%%
-record(riak_api_config, {
          s3_scheme="http://"::string(),
          s3_host="s3.amazonaws.com"::string(),
          s3_port=80::non_neg_integer(),
	  s3_proxy_host="127.0.0.1"::string(),
	  s3_proxy_port=8080::non_neg_integer(),
          s3_follow_redirect=false::boolean(),
          s3_follow_redirect_count=2::non_neg_integer(),
	  %% Riak's access key and secret
          access_key_id="ADD YOUR KEY ID ( aka admin.key in riak-cs.conf )"::string(),
          secret_access_key="ADD ACCESS KEY ( aka riak_control.auth.user.admin.password in riak.conf )"::string(),
          %% Network request timeout; if not specifed, the default timeout will be used:
          timeout=undefined::timeout()|undefined
         }).
-type(riak_api_config() :: #riak_api_config{}).

%%
%% Length of the chunk of data, sent from remote client
%% to server at a time. This value can be adjusted for
%% different network thoughput.
%%
%% Default: 2000000
%%	    ( 2 MB )
%%
-define(FILE_UPLOAD_CHUNK_SIZE, 2000000).  % 2 MB
%%
%% Maximum size of uploaded file
%%
%% Default: 5368709122
%%	    ( 5 GB )
%%
-define(FILE_MAXIMUM_SIZE, 5368709122).
%%
%% Ther's convention within that project to use the
%% following bucket names
%% the-projectname-groupname-public
%% ^^^ ^^^^^^^^^^^ ^^^^^^^^  ^^^^^^
%% prefix  bucket  group     suffix
%%
%% Suffix can be "public", "private" or "restricted"
%% Buckets ending with PUBLIC_BUCKET_SUFFIX can
%% be read by anyone in the Internet.
%%
%% Default: "public"
%%
-define(PUBLIC_BUCKET_SUFFIX, "public").
%%
%% Private bucket is available to staff users only
%%
%% Default: "private"
%%
-define(PRIVATE_BUCKET_SUFFIX, "private").
%%
%% Restricted bucket is available only to group,
%% encoded in bucket name and to staff users
%%
%% Default: "restricted"
%%
-define(RESTRICTED_BUCKET_SUFFIX, "res").
%%
%% Index object name, stored in every pseudo-directory
%% Listing API endpoint do not return object with that name.
%%
%% Default: ".riak_index.etf"
%%
-define(RIAK_INDEX_FILENAME, ".riak_index.etf"). %% External Term Format
%%
%% Lock object name. Indicates process of updating index if exists.
%%
%% Default: ".riak_index.lock"
%%
-define(RIAK_LOCK_INDEX_FILENAME, ".riak_index.lock").
%%
%% Action logs are stored in XML format in every pseudo-directory
%% except root ( "/" ).
%%
%% Default: ".riak_action_log.xml"
%%
-define(RIAK_ACTION_LOG_FILENAME, ".riak_action_log.xml").
%%
%% Name of bucket prefix
%%
%% Assumption: Riak is configured with the following option
%% {multi_backend_prefix_list, [{<<"the-">>, be_blocks}]}
%%
%% Default: "the"
%%
-define(RIAK_BACKEND_PREFIX, "the").
%%
%% Option for image scaling API endpoint.
%% Value in pixels that should be used for scaling
%% if not specified in request.
%%
%% Default: 250
%%
-define(DEFAULT_IMAGE_WIDTH, 250).

%%
%% Special bucket stores information on Tokens,
%% CSRF Tokens, Users and Tenants in security bucket.
%%
%% Default: "security"
%%
-define(SECURITY_BUCKET_NAME, "security").
%%
%% Prefix to object, that stores User session
%% in security bucket.
%%
%% Default: "tokens/"
%%
-define(TOKENS_PREFIX, "tokens/").
%%
%% Prefix to object, that stores CSRF token,
%% used to validate login from web page.
%%
%% Default: "csrf-tokens/"
%%
-define(CSRF_TOKENS_PREFIX, "csrf-tokens/").
%%
%% Prefix to object, that stores information
%% on Application tokens.
%%
%% Default: "app-tokens/"
%%
-define(APP_TOKENS_PREFIX, "app-tokens/").
%%
%% Prefix to object, that stores User profile
%% in security bucket.
%%
%% Default: "users/"
%%
-define(USERS_PREFIX, "users/").
%%
%% Prefix to object, that stores Tenant details
%% in security bucket.
%%
%% Default: "tenants/"
%%
-define(TENANTS_PREFIX, "tenants/").

%%
%% Enable this to allow the creation of an admin user when
%% setting up a system. It is recommended to only enable this
%% temporarily unless your use-case specifically dictates letting
%% anonymous users to create accounts.
%%
%% Default: off
%%
%% Acceptable values:
%%   - on or off
%%
-define(ANONYMOUS_USER_CREATION, false).
%%
%% Maximum length of bucket name in Riak CS is 64 latin characters.
%% This middleware uses tenant and group name as parts of the bucket name.
%%
%% For example:
%% the-projectname-groupname-public
%% ^^^ ^^^^^^^^^^^ ^^^^^^^^  ^^^^^^
%% prefix  bucket  group     suffix
%%
%% The fllowing setting allows you to specify maximum lengths of tenant and
%% group names to avoid errors from Riak CS.
%%
%% Sum of tenand and group lengths should be <= 51 characters
-define(MAXIMUM_TENANT_NAME, 26).
-define(MAXIMUM_GROUP_NAME, 25).
