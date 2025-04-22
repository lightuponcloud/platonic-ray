%%
%% Stores information on performed actions.
%%
-module(audit_log).
-behavior(cowboy_handler).

-export([init/2, content_types_provided/2, to_json/2, allowed_methods/2,
	 content_types_accepted/2,  forbidden/2, resource_exists/2,
	 previously_existed/2]).
-export([fetch_full_object_history/2,
	 validate_object_key/4, validate_post/3, handle_post/2]).

-include_lib("xmerl/include/xmerl.hrl").

-include("storage.hrl").
-include("entities.hrl").

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

%%
%% Called first
%%
allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>], Req, State}.


content_types_provided(Req, State) ->
    {[
	{{<<"application">>, <<"json">>, '*'}, to_json}
    ], Req, State}.

content_types_accepted(Req, State) ->
    case cowboy_req:method(Req) of
	<<"POST">> ->
	    {[{{<<"application">>, <<"json">>, '*'}, handle_post}], Req, State}
    end.


%%
%% Returns list of actions in pseudo-directory. If object_key specified, returns object history.
%%
to_json(Req0, State) ->
    BucketId = proplists:get_value(bucket_id, State),
    Prefix = proplists:get_value(prefix, State),

    case proplists:get_value(object_key, State) of
	undefined -> get_action_log(Req0, State, BucketId, Prefix, undefined);
	ObjectKey0 ->
	    ObjectKey1 = unicode:characters_to_list(ObjectKey0),
	    get_object_changelog(Req0, State, BucketId, Prefix, ObjectKey1)
    end.


log_operation(OperationName, Status, ObjectKeys, Context)
	when erlang:is_atom(OperationName) andalso erlang:is_list(Status) andalso 
	erlang:is_list(ObjectKeys) ->
    EventId = crypto_utils:uuid4(),
    Timestamp = crypto_utils:iso_8601_basic_time(),
    Version = utils:get_server_version(middleware),

    %% Create main log entry
    MainLog = [
        {event_id, EventId},
        {version, utils:to_binary(Version)},
        {timestamp, utils:to_binary(Timestamp)},
        {severity, <<"info">>},
        {facility, <<"user">>},
        {message, utils:to_binary(io_lib:format("~s on ~B objects", [OperationName, length(ObjectKeys)]))},
        {operation_name, utils:to_binary(OperationName)},
        {operation, [
            {"status", Status},
            {"status_code", proplists:get_value(status_code, Context, 200)},
            {"request_id", proplists:get_value(request_id, Context, null)},
            {"time_to_response_ns", proplists:get_value(time_to_response_ns, Context, null)}
        ]},
        {"object_keys", case length(ObjectKeys) < 100 of
            true -> ObjectKeys;  % Include keys directly if reasonable
            false -> null        % Otherwise omit
        end,
        {object_count, length(ObjectKeys)},
        {user_id, proplists:get_value(user_id, Context, null)},
        {actor, proplists:get_value(actor, Context, null)},
        {environment, proplists:get_value(environment, Context, null)},
        {compliance_metadata, proplists:get_value(compliance_metadata, Context, null)}
    ],

    %% Create detailed manifest if object count is large
    case length(ObjectKeys) >= 100 of
	true ->
	    Manifest = [
		{operation_id, EventId},
		{operation_name, OperationName},
		{timestamp, Timestamp},
		{object_keys, ObjectKeys}
	    ],
	    Response = s3_api:put_object(?SECURITY_BUCKET_NAME, ?AUDIT_LOG_PREFIX ++ "/manifests",
		io_lib:format("~s.json", [EventId]), jsx:encode(Manifest)),
	    case Response of
		{error, Reason} -> lager:error("[audit_log] Can't put object ~p/~p/~p: ~p",
						[?SECURITY_BUCKET_NAME, ?AUDIT_LOG_PREFIX ++ "/manifests",
						io_lib:format("~s.json", [EventId]), Reason]);
		_ -> ok
	    end,
            log_action(MainLog++[{manifest_path, utils:to_binary(io_lib:format("~s.json", [EventId]))}]);
        false ->
            log_action(MainLog)
    end.


log_action(BucketId, Prefix) when erlang:is_list(BucketId) andalso erlang:is_list(Prefix) ->
    %% Quarter for storing audit logs in less number of files
    {{Year,Month,_},{_,_,_}} = calendar:now_to_universal_time(os:timestamp()),
    Quarter = (Month - 1) div 3 + 1,

    LogPath = io_lib:format("~s/buckets/~s/~4.10.0B-Q~B.jsonl", [?AUDIT_LOG_PREFIX, BucketId, Year, Quarter]).

    JsonLine = jiffy:encode(Action) ++ "\n",

    %% Append to log with optimistic concurrency
    append_to_object(LogPath, JsonLine),

    %% Update indices for fast lookups if needed
    maybe_update_indices(Action).

    Json = jsone:encode(Log),
    Key = lists:flatten(io_lib:format("audit-logs/~p/~p/~p/service-name_~p.jsonl", [Year, Month, Day, Date])),
    aws_s3:put_object("your-bucket", Key, Json ++ "\n").


%% Append to an object with consistency handling
append_to_object(Path, Data) ->
    %% Use poolboy or similar for connection pooling
    Worker = poolboy:checkout(s3_pool),
    try
        case erlcloud_s3:get_object_metadata("your-bucket", Path, [], [{worker, Worker}]) of
            {ok, Metadata} ->
                %% Object exists, append with conditional put
                {ok, CurrentContent} = erlcloud_s3:get_object("your-bucket", Path, [], [{worker, Worker}]),
                CurrentETag = proplists:get_value(etag, Metadata),
                NewContent = <<CurrentContent/binary, (list_to_binary(Data))/binary>>,
                
                %% Use conditional put for optimistic concurrency
                erlcloud_s3:put_object("your-bucket", Path, NewContent, 
                                      [{"if-match", CurrentETag}], [{worker, Worker}]);
            {error, _} ->
                %% Object doesn't exist, create it
                erlcloud_s3:put_object("your-bucket", Path, Data, [], [{worker, Worker}])
        end
    after
        poolboy:checkin(s3_pool, Worker)
    end.

%% Get all actions for a directory
get_directory_actions(DirectoryPath, TimeRange) ->
    %% Calculate directory hash
    DirHash = crypto:hash(sha256, DirectoryPath),
    DirectoryHashHex = binary:encode_hex(binary:part(DirHash, 0, 8)),
    
    %% Generate list of potential log files based on time range
    LogPaths = generate_log_paths(DirectoryHashHex, TimeRange),
    
    %% Fetch and process logs in parallel
    Results = pmap(
        fun(Path) -> 
            fetch_and_filter_log(Path, DirectoryPath) 
        end,
        LogPaths
    ),
    
    %% Combine and sort by timestamp
    lists:sort(
        fun(A, B) -> 
            maps:get(timestamp, A) =< maps:get(timestamp, B) 
        end,
        lists:flatten(Results)
    ).

%% Parallel map implementation
pmap(F, L) ->
    Parent = self(),
    Pids = [spawn(fun() -> Parent ! {self(), F(X)} end) || X <- L],
    [receive {Pid, Result} -> Result end || Pid <- Pids].

%% Fetch and filter a log file for specific directory
fetch_and_filter_log(Path, DirectoryPath) ->
    try
        {ok, Content} = erlcloud_s3:get_object("your-bucket", Path),
        Lines = binary:split(Content, <<"\n">>, [global]),
        
        %% Parse and filter JSON lines
        lists:filtermap(
            fun(Line) ->
                case Line of
                    <<>> -> false; % Skip empty lines
                    _ ->
                        Action = jiffy:decode(Line, [return_maps]),
                        case maps:get(directory_path, Action, undefined) of
                            DirectoryPath -> {true, Action};
                            _ -> false
                        end
                end
            end,
            Lines
        )
    catch
        _:_ -> []
    end.


%%
%% Checks if provided token is correct.
%% ( called after 'allowed_methods()' )
%%
forbidden(Req0, _State) ->
    PathInfo = cowboy_req:path_info(Req0),
    ParsedQs = cowboy_req:parse_qs(Req0),
    BucketId =
	case lists:nth(1, PathInfo) of
	    undefined -> undefined;
	    <<>> -> undefined;
	    BV -> erlang:binary_to_list(BV)
	end,
    Prefix =
	case length(PathInfo) < 2 of
	    true -> undefined;
	    false ->
		%% prefix should go just after bucket id
		erlang:binary_to_list(utils:join_binary_with_separator(lists:nthtail(1, PathInfo), <<"/">>))
	end,
    PresentedSignature =
	case proplists:get_value(<<"signature">>, ParsedQs) of
	    undefined -> undefined;
	    Signature -> unicode:characters_to_list(Signature)
	end,
    case download_handler:has_access(Req0, BucketId, Prefix, undefined, PresentedSignature) of
	{error, Number} -> js_handler:unauthorized(Req0, Number, stop);
	{BucketId, Prefix, _ObjectKey, User} ->
	    {false, Req0, [
		{bucket_id, BucketId},
		{prefix, Prefix},
		{parsed_qs, ParsedQs},
		{user, User}
	    ]}
    end.

%%
%% Validates request parameters
%% ( called after 'content_types_provided()' )
%%
resource_exists(Req0, State) ->
    {true, Req0, State}.

previously_existed(Req0, _State) ->
    {false, Req0, []}.
