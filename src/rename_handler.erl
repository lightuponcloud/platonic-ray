%%%
%%% Renames object
%%%
%%% Check priv/en.json for error codes.
%%%
-module(rename_handler).
-behavior(cowboy_handler).

-export([init/2, content_types_provided/2, content_types_accepted/2,
	 to_json/2, allowed_methods/2, forbidden/2, is_authorized/2,
	 handle_post/2, rename_pseudo_directory/6, rename_pseudo_directory/5]).

-include("storage.hrl").
-include("entities.hrl").

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

%%
%% Returns callback 'to_json()'
%% ( called after 'forbidden()' )
%%
content_types_provided(Req, State) ->
    {[
	{{<<"application">>, <<"json">>, []}, to_json}
    ], Req, State}.

%%
%% Returns callback 'handle_post()'
%% ( called after 'resource_exists()' )
%%
content_types_accepted(Req, State) ->
    case cowboy_req:method(Req) of
	<<"POST">> -> {[{{<<"application">>, <<"json">>, '*'}, handle_post}], Req, State};
	_ -> {[], Req, State}
    end.

%%
%% Checks if provided source prefix is valid.
%% If object key ends with "/", it checks this prefix as well.
%%
validate_src_object_key(BucketId, Prefix0, SrcObjectKey0) ->
    case object_handler:validate_prefix(BucketId, Prefix0) of
	{error, Number0} -> {error, Number0};
	Prefix1 ->
	    case utils:ends_with(SrcObjectKey0, <<"/">>) of
		true ->
		    case object_handler:validate_prefix(BucketId,
			    utils:prefixed_object_key(Prefix0, SrcObjectKey0)) of
			{error, Number1} -> {error, Number1};
			SrcObjectKey1 -> {Prefix1, SrcObjectKey1}
		    end;
		false -> {Prefix1, string:to_lower(erlang:binary_to_list(SrcObjectKey0))}
	    end
    end.

%%
%% Check if correct source directory provided
%%
check_src_dir(BucketId, Prefix) ->
    PrefixedIndexFilename = utils:prefixed_object_key(Prefix, ?INDEX_FILENAME),
    case s3_api:get_object(BucketId, PrefixedIndexFilename) of
	{error, Reason} ->
	    lager:error("[rename_handler] get_object error ~p/~p: ~p",
			[BucketId, PrefixedIndexFilename, Reason]),
	    {error, 5};
	not_found -> {error, 9};
	IndexContent0 -> erlang:binary_to_term(proplists:get_value(content, IndexContent0))
    end.

%%
%% Checks if pseudo-directory exists, by requesting its index object and
%% then checking if requested name is present.
%%
%% Returns the following
%%
%% - Prefixed destination object name
%% - {error, code}
%%
validate_dst_name(BucketId, Prefix, DstName0, IndexContent)
	when erlang:is_binary(DstName0) ->
    case IndexContent of
	{error, Number} -> {error, Number};
	_ ->
	    case indexing:directory_or_object_exists(BucketId, Prefix, DstName0, IndexContent) of
		{directory, _DirName} -> {error, 10};
		{object, _OrigName} -> {error, 29};
		false -> utils:prefixed_object_key(Prefix, utils:hex(DstName0))
	    end
    end.

%%
%% Checks if object exists and if not marked as deleted.
%%
validate_src_dst_name(BucketId, Prefix, SrcObjectKey, DstName0, IndexContent)
	when erlang:is_binary(SrcObjectKey) andalso erlang:is_binary(DstName0) ->
    case validate_dst_name(BucketId, Prefix, DstName0, IndexContent) of
	{error, Reason} -> {error, Reason};
	PrefixedDstName ->
           case utils:ends_with(SrcObjectKey, <<"/">>) of
               true ->
		    case object_handler:validate_prefix(BucketId, SrcObjectKey) of
			{error, Number} -> {error, Number};
			SrcPrefix -> {SrcPrefix, PrefixedDstName}
		    end;
               false ->
		    %% Check source object key or prefix
		    case indexing:get_object_record(IndexContent, SrcObjectKey) of
			[] -> {error, 9};
			_ -> {SrcObjectKey, PrefixedDstName}
		    end
	    end
    end.

validate_post(BucketId, FieldValues) ->
    Prefix0 = proplists:get_value(<<"prefix">>, FieldValues),
    SrcObjectKey0 = proplists:get_value(<<"src_object_key">>, FieldValues),
    DstObjectName0 = proplists:get_value(<<"dst_object_name">>, FieldValues),
    case (SrcObjectKey0 =:= undefined orelse DstObjectName0 =:= undefined) of
	true -> {error, 9};
	false ->
	    case validate_src_object_key(BucketId, Prefix0, SrcObjectKey0) of
		{error, Number} -> {error, Number};
		{Prefix1, SrcObjectKey1} ->
		    case utils:is_valid_object_key(DstObjectName0) of
			false -> {error, 9};
			true ->
			    [{prefix, Prefix1},
			     {src_object_key, SrcObjectKey1},
			     {dst_object_name, DstObjectName0}]
		    end
	    end
    end.

%%
%% Validates provided fields and updates object index, in case of object rename
%% or moves objects to the new prefix, in case prefix rename requested.
%%
handle_post(Req0, State0) ->
    BucketId = proplists:get_value(bucket_id, State0),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case jsx:is_json(Body) of
	{error, badarg} -> js_handler:bad_request(Req1, 21);
	false -> js_handler:bad_request(Req1, 21);
	true ->
	    FieldValues = jsx:decode(Body),
	    case validate_post(BucketId, FieldValues) of
		{error, Number} -> js_handler:bad_request(Req0, Number);
		State1 ->
		    Prefix0 = proplists:get_value(prefix, State1),
		    SrcObjectKey0 = erlang:list_to_binary(proplists:get_value(src_object_key, State1)),
		    DstObjectName0 = proplists:get_value(dst_object_name, State1),
		    IndexContent = check_src_dir(BucketId, Prefix0),
		    case validate_src_dst_name(BucketId, Prefix0, SrcObjectKey0, DstObjectName0, IndexContent) of
			{error, Number} -> js_handler:bad_request(Req0, Number);
			{SrcObjectKey1, PrefixedDstDirectoryName1} ->
			    State2 = lists:keyreplace(src_object_key, 1, State1, {src_object_key, SrcObjectKey1}) ++
				[{prefixed_dst_directory_name, PrefixedDstDirectoryName1++"/"}],
			    rename(Req0, BucketId, State0 ++ State2, IndexContent)
		    end
	    end
    end.

%%
%% Copies file and checks the status of copy.
%% Returns ok in case of success. Otherwise returns filename.
%%
copy_delete(BucketId, PrefixedSrcDirectoryName, PrefixedDstDirectoryName, PrefixedObjectKey0) ->
    PrefixedObjectKey1 = re:replace(PrefixedObjectKey0, "^" ++ PrefixedSrcDirectoryName, "", [{return, list}]),
    %% We have cheked previously that destination directory do not exist
    PrefixedObjectKey2 = utils:prefixed_object_key(PrefixedDstDirectoryName, PrefixedObjectKey1),

    CopyResult = s3_api:copy_object(BucketId, PrefixedObjectKey2, BucketId, PrefixedObjectKey0),
    case CopyResult of 
	{error, _} -> PrefixedObjectKey2;
	_ ->
	    case proplists:get_value(content_length, CopyResult, 0) == 0 of
		true -> PrefixedObjectKey2;
		false ->
		    %% Delete regular object
		    case s3_api:delete_object(BucketId, PrefixedObjectKey0) of
			{error, Reason} -> lager:error("[rename_handler] Can't delete object ~p/~p: ~p", [BucketId, PrefixedObjectKey0, Reason]);
			{ok, _} -> ok
		    end,
		    PrefixedObjectKey2,
		    ok
	    end
    end.

%%
%% Rename moves nested objects to new pseudo-directory within the same bucket.
%%
%% Prefix0 -- current pseudo-directory
%%
%% SrcDirectoryName0 -- hex encoded pseudo-directory, that should be renamed
%%
rename_pseudo_directory(BucketId, Prefix0, PrefixedSrcDirectoryName, DstDirectoryName0, IsDeleted)
	when erlang:is_list(BucketId), erlang:is_list(Prefix0) orelse Prefix0 =:= undefined,
	     erlang:is_list(PrefixedSrcDirectoryName), erlang:is_binary(DstDirectoryName0)
	     andalso erlang:is_boolean(IsDeleted) ->
    PrefixedDstDirectoryName0 =
	case Prefix0 of
	    undefined -> utils:hex(DstDirectoryName0);
	    _ -> utils:prefixed_object_key(Prefix0, utils:hex(DstDirectoryName0))
	end,
    rename_pseudo_directory(BucketId, Prefix0, PrefixedSrcDirectoryName, DstDirectoryName0,
			    PrefixedDstDirectoryName0, IsDeleted).

-spec rename_pseudo_directory(BucketId, Prefix, PrefixedSrcDirectoryName, DstDirectoryName, PrefixedDstDirectoryName0) ->
    not_found|exists|true when
    BucketId :: string(),
    Prefix :: string()|undefined,
    PrefixedSrcDirectoryName :: string(),
    PrefixedDstDirectoryName0 :: string(),  %% prefixed hex-encoded directory name
    DstDirectoryName :: binary().           %% original directory name

rename_pseudo_directory(BucketId, Prefix0, PrefixedSrcDirectoryName, DstDirectoryName0,
			PrefixedDstDirectoryName0, IsDeleted)
	when erlang:is_list(BucketId), erlang:is_list(Prefix0) orelse Prefix0 =:= undefined,
	     erlang:is_list(PrefixedSrcDirectoryName), erlang:is_binary(DstDirectoryName0)
	     andalso erlang:is_boolean(IsDeleted) ->
    Timestamp = utils:timestamp(), %% measure time of request
    List0 = s3_api:recursively_list_pseudo_dir(BucketId, PrefixedSrcDirectoryName),
    RenameResult0 = [copy_delete(BucketId, PrefixedSrcDirectoryName,
				 PrefixedDstDirectoryName0, PrefixedObjectKey)
		     || PrefixedObjectKey <- List0,
		     utils:is_hidden_prefix(PrefixedObjectKey) =:= false andalso
		     lists:suffix(?INDEX_FILENAME, PrefixedObjectKey) =/= true],
    %% Update indices for nested pseudo-directories
    PseudoDirectoryMoveResult = lists:map(
	fun(PrefixedObjectKey) ->
	    case lists:suffix(?INDEX_FILENAME, PrefixedObjectKey) of
		false -> ok;
		true ->
		    SrcPrefix =
			case filename:dirname(PrefixedObjectKey) of
			    "." -> undefined;
			    P0 -> P0++"/"
			end,
		    DstKey0 = re:replace(PrefixedObjectKey, "^"++PrefixedSrcDirectoryName, "", [{return, list}]),
		    DstPrefix =
			case utils:prefixed_object_key(PrefixedDstDirectoryName0, DstKey0) of
			    "." -> undefined;
			    P1 ->
				case filename:dirname(P1) of
				    "." -> undefined;
				    P2 -> P2++"/"
				end
			end,
		    case indexing:update(BucketId, DstPrefix, [{copy_from, [
					 {bucket_id, BucketId}, {prefix, SrcPrefix}]}]) of
			lock -> filename:dirname(PrefixedObjectKey);
			_ ->
			    case s3_api:delete_object(BucketId, PrefixedObjectKey) of
				{error, Reason} ->
				    lager:error("[rename_handler] Can't delete object ~p/~p: ~p", [BucketId, PrefixedObjectKey, Reason]),
				    ok;
				{ok, _} -> ok
			    end
		    end
	    end
	end, List0),
    RenameErrors1 = [I || I <- PseudoDirectoryMoveResult, I =/= ok],
    RenameErrors2 = [I || I <- RenameResult0, I =/= ok],
    case length(RenameErrors1) =:= 0 andalso length(RenameErrors2) =:= 0 of
	false -> {accepted, {RenameErrors1, RenameErrors2}};
	true ->
	    DstDirectoryName1 = utils:hex(DstDirectoryName0),
	    case IsDeleted of
		true ->
		    %% User initiated deletion of directory. We need to rename directory, in order to allow undelete later.
		    case indexing:update(BucketId, Prefix0, [{to_delete,
					 [{erlang:list_to_binary(DstDirectoryName1++"/"), Timestamp}]}]) of
			lock ->
			    lager:warning("[rename_handler] Can't move directory, as lock exists: ~p/~p", [BucketId, Prefix0]),
			    lock;
			_ -> {dir_name, deleted, DstDirectoryName0}
		    end;
		false ->
		    %% Update pseudo-directory index
		    case indexing:update(BucketId, Prefix0) of
			lock ->
			    lager:warning("[rename_handler] Can't move directory, as lock exists: ~p/~p", [BucketId, Prefix0]),
			    lock;
			_ -> {dir_name, renamed, DstDirectoryName0}
		    end
	    end
    end.

%%
%% Delete a source object object
%%
%% Returns SQL for updating SQLite DB
%%
delete_source_object(BucketId, SrcPrefix, SrcObjectKey, DstObjectKey) ->
    PrefixedSrcObjectKey = utils:prefixed_object_key(SrcPrefix, SrcObjectKey),
    SQL =
	case s3_api:delete_object(BucketId, PrefixedSrcObjectKey) of
	    {error, Reason0} ->
		lager:error("[rename_handler] Can't delete object ~p/~p: ~p",
			    [BucketId, PrefixedSrcObjectKey, Reason0]),
		{error, Reason0};
	    {ok, _} -> sql_lib:delete_object(SrcPrefix, SrcObjectKey)
	end,
    %% Rename lock object key, if exsits, as the name changed
    PrefixedSrcLockKey1 = PrefixedSrcObjectKey ++ ?LOCK_SUFFIX,
    PrefixedDstLockKey = utils:prefixed_object_key(SrcPrefix, DstObjectKey ++ ?LOCK_SUFFIX),
    case s3_api:copy_object(BucketId, PrefixedSrcLockKey1, BucketId, PrefixedDstLockKey) of
	{error, _Reason} -> ok;  %% Source object lock do not exist
	_ ->
	    case s3_api:delete_object(BucketId, PrefixedSrcLockKey1) of
		{error, Reason} ->
		    lager:error("[rename_handler] Can't delete lock object ~p/~p: ~p",
				[BucketId, PrefixedSrcLockKey1, Reason]),
		    ok;  %% no harm if lock remains, it will be outdated anyway, if its name matches another object
		{ok, _} -> ok
	    end
    end,
    SQL.

%%
%% Copies object using new name, deletes old object.
%%
rename_object(BucketId, Prefix0, SrcObjectKey0, DstObjectName0, User, IndexContent) ->
    %% We can't just update index with new name, as further file upload or rename operations
    %% would complain "object exist". Provided they have the same object name.
    UserName = utils:unhex(erlang:list_to_binary(User#user.name)),

    T0 = utils:timestamp(), %% measure time of request
    {ObjectKey0, OrigName0, _IsNewVersion, ExistingObject0, _IsConflict} = s3_api:pick_object_key(
	    BucketId, Prefix0, DstObjectName0, undefined, UserName, IndexContent),
    %% Check if target object exists
    %% If not, check if source object is locked.
    case ExistingObject0 of
	undefined ->
	    %% rename only if no such object with the same name exists
	    case object_handler:is_locked_for_user(BucketId, Prefix0, SrcObjectKey0, User#user.id) of
		{error, not_found} -> not_found;
		{error, Number} -> {error, Number};
		{true, _} -> {error, 43};
		{false, Metadata0} ->
		    Meta = object_handler:parse_object_record(Metadata0, [{orig_name, utils:hex(OrigName0)}]),
		    case s3_api:put_object(BucketId, Prefix0, ObjectKey0, <<>>, [{meta, Meta}]) of
			{error, Reason3} ->
			    lager:error("[rename_handler] Can't put object ~p/~p/~p: ~p",
					[BucketId, Prefix0, ObjectKey0, Reason3]),
			    {error, 5};
			ok ->
			    SQL =
				case delete_source_object(BucketId, Prefix0, SrcObjectKey0, ObjectKey0) of
				    {error, _} -> undefined;
				    S -> S
				end,
			    %% Find original object name for action log record
			    ObjectRecord = lists:nth(1,
				[I || I <- proplists:get_value(list, IndexContent),
				 proplists:get_value(object_key, I) =:= erlang:list_to_binary(SrcObjectKey0)]),

			    %% Update objects index
			    case indexing:update(BucketId, Prefix0, [{modified_keys, [ObjectKey0]}]) of
				lock ->
				    lager:warning("[rename_handler] Can't update index, as lock exists: ~p/~p",
						  [BucketId, Prefix0]),
				    lock;
				_ ->
				    %% Create action log record
				    PreviousOrigName = utils:to_binary(proplists:get_value(orig_name, ObjectRecord)),
				    Summary = <<"Renamed \"", PreviousOrigName/binary, "\" to \"", OrigName0/binary, "\"">>,
				    T1 = utils:timestamp(), %% measure time of request
				    audit_log:log_operation(
					BucketId,
					Prefix0,
					rename,
					200,
					[utils:to_binary(SrcObjectKey0)],
					[{status_code, 200},
					 {request_id, null},
					 {time_to_response, utils:to_float(T1-T0)/1000},
					 {user_id, User#user.id},
					 {user_name, utils:unhex(erlang:list_to_binary(User#user.name))},
					 {actor, user},
					 {environment, null},
					 {compliance_metadata, [{orig_name, PreviousOrigName}, {summary, Summary}]}]
				    ),
				    Metadata1 = object_handler:parse_object_record(Metadata0, [
					{orig_name, unicode:characters_to_binary(OrigName0)}]),
				    {ObjectKey0, Metadata1, SQL}
			    end
		    end
	    end;
	_ -> {error, 35}  %% Failed to rename object, as target one exists
    end.

rename(Req0, BucketId, State, IndexContent) ->
    Prefix0 = proplists:get_value(prefix, State),
    SrcObjectKey0 = proplists:get_value(src_object_key, State),
    DstObjectName0 = proplists:get_value(dst_object_name, State),
    PrefixedDstDirectoryName = proplists:get_value(prefixed_dst_directory_name, State),
    User = proplists:get_value(user, State),
    T0 = erlang:round(utils:timestamp()/1000),
    SrcObjectKey1 = utils:to_list(SrcObjectKey0),
    case utils:ends_with(SrcObjectKey1, <<"/">>) of
	true ->
	    DstDirectoryName0 =
		case rename_pseudo_directory(BucketId, Prefix0, SrcObjectKey1, DstObjectName0,
					     PrefixedDstDirectoryName, false) of
		    lock -> js_handler:too_many(Req0);
		    {accepted, {RenameErrors1, RenameErrors2}} ->
			%% Rename is not complete, as Riak CS was busy.
			%% Return names of objects that were not copied.
			Req1 = cowboy_req:reply(202, #{
			    <<"content-type">> => <<"application/json">>
			}, jsx:encode([{dir_errors, RenameErrors1}, {object_errors, RenameErrors2}]), Req0),
			{true, Req1, []};
		    {error, Number} -> js_handler:bad_request(Req0, Number);
		    {dir_name, renamed, DstDirectoryName2} ->
			SrcObjectKey2 = filename:basename(SrcObjectKey1),
			SrcObjectKey3 = utils:unhex(erlang:list_to_binary(SrcObjectKey2)),
			T1 = utils:timestamp(), %% measure time of request
			Summary = <<"Renamed \"", SrcObjectKey3/binary, "\" to \"", DstDirectoryName2/binary, "\"">>,
			audit_log:log_operation(
			    BucketId,
			    Prefix0,
			    rename,
			    200,
			    [SrcObjectKey3],
			    [{status_code, 200},
			     {request_id, null},
			     {time_to_response, utils:to_float(T1-T0)/1000},
			     {user_id, User#user.id},
			     {user_name, utils:unhex(erlang:list_to_binary(User#user.name))},
			     {actor, user},
			     {environment, null},
			     {compliance_metadata, [{summary, Summary}]}]
			),
			DstDirectoryName2
		end,
	    sqlite_server:rename_pseudo_directory(BucketId, Prefix0, filename:basename(SrcObjectKey1), DstDirectoryName0),
	    Req2 = cowboy_req:set_resp_body(jsx:encode([{dir_name, DstDirectoryName0}]), Req0),
	    {true, Req2, []};
	false ->
	    case rename_object(BucketId, Prefix0, SrcObjectKey1, DstObjectName0, User, IndexContent) of
		{error, Number} -> js_handler:bad_request(Req0, Number);
		lock -> js_handler:too_many(Req0);
		not_found -> js_handler:not_found(Req0);
		{NewObjKey, NewObj, SQLDelete} ->
		    OrigName = proplists:get_value("orig-filename", NewObj),
		    UploadTime = utils:to_integer(proplists:get_value("upload-time", NewObj)),
		    IsLocked =
			case proplists:get_value(is_locked, NewObj) of
			    undefined -> false;
			    L -> L
			end,
		    TotalBytes = utils:to_integer(proplists:get_value("bytes", NewObj)),
		    Obj = #object{
			key = NewObjKey,
			orig_name = OrigName,
			bytes = TotalBytes,
			guid = proplists:get_value("guid", NewObj),
			version = proplists:get_value("version", NewObj),
			upload_time = UploadTime,
			is_deleted = false,
			author_id = proplists:get_value("author-id", NewObj),
			author_name = proplists:get_value("author-name", NewObj),
			author_tel = proplists:get_value("author-tel", NewObj),
			is_locked = IsLocked,
			lock_user_id = proplists:get_value(lock_user_id, NewObj),
			lock_user_name = proplists:get_value(lock_user_name, NewObj),
			lock_user_tel = proplists:get_value(lock_user_tel, NewObj),
			lock_modified_utc = proplists:get_value(lock_modified_utc, NewObj)
		    },
		    SQLAdd = sql_lib:add_object(Prefix0, Obj),
		    sqlite_server:exec_sql(BucketId, SQLDelete, SQLAdd),
		    Req1 = cowboy_req:set_resp_body(jsx:encode([{orig_name, OrigName}]), Req0),
		    {true, Req1, []}
	    end
    end.

%%
%% Serializes response to json
%%
to_json(Req0, State) ->
    {<<"{\"status\": \"ok\"}">>, Req0, State}.

%%
%% Called first
%%
allowed_methods(Req, State) ->
    {[<<"POST">>], Req, State}.

%%
%% Checks if provided token is correct.
%% Extracts token from request headers and looks it up in "security" bucket.
%% ( called after 'allowed_methods()' )
%%
is_authorized(Req0, _State) ->
    case utils:get_token(Req0) of
	undefined -> js_handler:unauthorized(Req0, 28, stop);
	Token -> login_handler:get_user_or_error(Req0, Token)
    end.

%%
%% ( called after 'is_authorized()' )
%%
forbidden(Req0, User) ->
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
    {false, Req0, [
		{user, User},
		{bucket_id, BucketId},
		{prefix, Prefix},
		{parsed_qs, ParsedQs}
	    ]}.
