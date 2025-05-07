-type proplist() :: proplists:proplist().

%%
%% Configuration variables of Riak CS connection
%%
-record(api_config, {
	  s3_scheme="http://"::string(),
	  s3_host="s3.amazonaws.com"::string(),
	  s3_region="US",
	  s3_port=80::non_neg_integer(),
	  s3_proxy_host="127.0.0.1"::string(),
	  s3_proxy_port=8080::non_neg_integer(),
	  s3_follow_redirect=false::boolean(),
	  s3_follow_redirect_count=2::non_neg_integer(),
	  %% Riak's access key and secret
	  access_key_id="GUXIOJVOKUDDMG0HPWKP"::string(),
	  secret_access_key="SF94xTjigPb1t3deGjlwCls_fgeIho9GnvzxfA"::string(),
	  %% Network request timeout; if not specifed, the default timeout will be used:
	  timeout=undefined::timeout()|undefined
	 }).
-type(api_config() :: #api_config{}).

%%
%% Maximum size of uploaded file
%%
%% Default: 5368709122
%%	    ( 5 GB )
%%
-define(FILE_MAXIMUM_SIZE, 11811160064).

%%
%% Option for image scaling API endpoint.
%% Value in pixels that should be used for scaling
%% if not specified in request.
%%
%% Default: 250
%%
-define(DEFAULT_IMAGE_WIDTH, 250).

%%
%% Middleware will cache images bigger than the following value.
%%
%% Default: 2097152 ( 2 MB )
%%
-define(MINIMUM_CACHE_IMAGE_SIZE, 2097152).

%%
%% Maximum image size to try to scale, in bytes ( 21 MB ).
%% It should be bigger than FILE_UPLOAD_CHUNK_SIZE.
%%
-define(MAXIMUM_IMAGE_SIZE_BYTES, 22020096).

%%
%% The number of imagemagick workers for scaling images
%%
-define(IMAGE_WORKERS, 5).
%%
%% The number of ffmpeg gen_server processes for transcoding videos.
%%
-define(VIDEO_WORKERS, 4).


%%
%% --------------------------------------------------------------------------------------------
%%
%% If you change the following values, you have to re-initialize the contents of object storage.
%% Everything should be REMOVED.
%%
%% --------------------------------------------------------------------------------------------
%%
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
%% Ther's convention within that project to use the
%% following bucket names
%% the-projectname-groupname-res
%% ^^^ ^^^^^^^^^^^ ^^^^^^^^  ^^^
%% prefix  bucket  group     suffix
%%
%% Suffix can be "private" or "restricted"
%%
%% Private bucket is available to staff users only
%%
%% Default: "private"
%%
-define(PRIVATE_BUCKET_SUFFIX, "priv").
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
-define(INDEX_FILENAME, ".riak_index.etf"). %% External Term Format
%%
%% Lock object name. Indicates process of updating index if exists.
%%
%% Default: ".riak_index.lock"
%%
-define(LOCK_INDEX_FILENAME, ".riak_index.lock").
%%
%% The number of seconds index lock can exist.
%% In case of very large number of files this number should be increased,
%% as it might take more time to update index.
%%
-define(LOCK_INDEX_COOLOFF_TIME, 30).
%%
%% The name of index object, storing dotted version vectors for objects.
%% This object is stored undef ``RIAK_REAL_OBJECT_PREFIX`` directory.
%%
-define(DVV_INDEX_FILENAME, ".dvv.etf").
%%
%% Lock object name. It is created during DVV update.
%%
-define(LOCK_DVV_INDEX_FILENAME, ".dvv.lock").
%%
%% The number of seconds dvv lock can exist.
%%
-define(LOCK_DVV_COOLOFF_TIME, 30).

%%
%% Pseudo-directory sharing options are stored in object with undermentioned name.
%%
%% Default: ".riak_sharing.etf"
%%
-define(SHARING_OPTIONS_FILENAME, ".sharing_options.etf").
%%
%% Lock object name. Indicates process of updating index if exists.
%%
%% Default: ".sharing_options.lock"
%%
-define(LOCK_SHARING_OPTIONS_FILENAME, ".sharing_options.lock").
%%
%% All objects are stored by the following prefix ( list response contains links to the real path ).
%%
%% Default: "~object"
%%
-define(REAL_OBJECT_PREFIX, "~object").
%%
%% Prefix for audit logs.
%%
%% Default: "~audit"
%%
-define(AUDIT_LOG_PREFIX, "audit").
%%
%% Locked object suffix.
%% Temporary object created with .lock extension by default.
%% Locked objects are not supposed to be modified.
%%
%% Default: ".lock"
%%
-define(LOCK_SUFFIX, ".lock").
%%
%% The object key of thumbnail for image or video.
%%
-define(THUMBNAIL_KEY, "thumbnail").
%%
%% Name of bucket prefix
%%
%% Assumption: Riak is configured with the following option
%% {multi_backend_prefix_list, [{<<"the-">>, be_blocks}]}
%%
%% Default: "the"
%%
-define(BACKEND_PREFIX, "the").

%%
%% Special bucket stores information on Tokens,
%% CSRF Tokens, Users and Tenants in security bucket.
%%
%% Default: "security"
%%
-define(SECURITY_BUCKET_NAME, "security2").
%%
%% Bucket for temporary upload IDs,
%% Those IDs point to real objects and are used
%% to detect stale uploads.
%%
-define(UPLOADS_BUCKET_NAME, "uploads").
%%
%% Prefix to object, that stores User session
%% in security bucket.
%%
%% Default: "tokens/"
%%
-define(TOKEN_PREFIX, "tokens/").
%%
%% Prefix to object, that stores CSRF token,
%% used to validate login from web page.
%%
%% Default: "csrf-tokens/"
%%
-define(CSRF_TOKEN_PREFIX, "csrf-tokens/").
%%
%% Prefix to object, that stores User profile
%% in security bucket.
%%
%% Default: "users/"
%%
-define(USER_PREFIX, "users/").
%%
%% Prefix to object, that stores Tenant details
%% in security bucket.
%%
%% Default: "tenants/"
%%
-define(TENANT_PREFIX, "tenants/").
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
%% WARNING: Sum of tenand and group lengths should be <= 51 characters
%%
-define(MAXIMUM_TENANT_NAME_LENGTH, 26).
-define(MAXIMUM_GROUP_NAME_LENGTH, 25).

%%
%% Object name for preventing removal
%%
-define(STOP_OBJECT_SUFFIX, ".stop").
%%
%% If case watermark with this key is present in bucket, thumbnails will have watermark on them.
%%
-define(WATERMARK_OBJECT_KEY, "watermark.png").
%%
%% Name of object to read when playlist is requested
%%
-define(HLS_720p_OBJECT_KEY, "720p.m3u8").
%%
%% SQLite db object key. This db stores file tree.
%%
-define(DB_VERSION_KEY, ".luc").
%%
%% SQLite db lock object key. If that file present, other processes can't overwrite db.
%%
%% Default: ".luc.lock"
%%
-define(DB_VERSION_LOCK_FILENAME, ".luc.lock").

%%
%% The number of seconds lock can exist.
%%
-define(DB_LOCK_COOLOFF_TIME, 30).
%%
%% Retry parameters for S3 operations
%%
-define(S3_RETRY_COUNT, 3).           % Maximum number of retries
-define(S3_BASE_DELAY_MS, 100).       % Base delay for exponential backoff (100ms)
-define(S3_MAX_DELAY_MS, 5000).       % Maximum delay for backoff (5 seconds)
-define(S3_JITTER_PERCENT, 0.1).      % 10% jitter for randomization
