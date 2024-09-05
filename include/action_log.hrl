-record(action_log_record, {
    key = ""::string(), %% object key
    orig_name = ""::string(), %% original name of object
    guid = ""::string(),  %% store GUID, so we can find object on S3, in case its link is deleted
    is_dir = false,
    action = ""::string(),
    details = ""::list(), %% unicode-encoded characters list
    user_id = ""::string(),
    user_name = ""::string(),
    tenant_name = ""::string(),
    timestamp = undefined,
    duration = undefined,
    version = ""::string(),
    is_locked = false,
    lock_user_id = ""::string(),
    lock_user_name = ""::string(),
    lock_user_tel = ""::string(),
    lock_modified_utc = undefined
}).

-type action_log_record() :: #{
    key => string(),  %% object key
    orig_name => string(),  %% original name of object
    guid => string(),
    is_dir => boolean(),
    action => string(),  %% mkdir, move, copy, delete, upload, restored
    details => list(),
    user_id => list(),
    user_name => string(),
    tenant_name => string(),
    timestamp => integer(),
    duration => integer(),
    version => string(),  %% stores version of object
    is_locked => boolean(),
    lock_user_id => string(),
    lock_user_name => string(),
    lock_user_tel => string(),
    lock_modified_utc => integer()
}.
