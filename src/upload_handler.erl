%%
%% Differential synchronization API endpoint.
%% Allows to upload objects to the Riak CS.
%%
-module(upload_handler).
-behavior(cowboy_handler).

-export([init/2, resource_exists/2, content_types_accepted/2, handle_post/2,
	 allowed_methods/2, previously_existed/2, allow_missing_post/2,
	 content_types_provided/2, is_authorized/2, forbidden/2]).

-export([to_json/2, extract_rfc2231_filename/1, validate_version/1, validate_md5/1,
	 acc_multipart/2, stream_body/2, validate_integer_field/1]).

-include("riak.hrl").
-include("entities.hrl").
-include("action_log.hrl").
-include("media.hrl").
-include("log.hrl").

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

%%
%% Returns callback 'handle_post()'
%% ( called after 'resource_exists()' )
%%
content_types_accepted(Req, State) ->
    {[{{<<"multipart">>, <<"form-data">>, '*'}, handle_post}], Req, State}.

%%
%% Returns callback 'to_json()'
%% ( called after 'forbidden()' )
%%
content_types_provided(Req, State) ->
    {[
	{{<<"application">>, <<"json">>, []}, to_json}
    ], Req, State}.

%%
%% Serializes response to json
%%
to_json(Req0, State) ->
    {<<>>, Req0, State}.

%%
%% Called first
%%
allowed_methods(Req, State) ->
    {[<<"POST">>], Req, State}.

%%
%% Checks if content-range header matches size of uploaded data
%%
validate_data_size(0, _StartByte, _EndByte, _TotalBytes) ->
    true;  % empty requests are accepted for checks
validate_data_size(_DataSize, _StartByte, EndByte, TotalBytes)
	when TotalBytes < ?FILE_UPLOAD_CHUNK_SIZE andalso EndByte =/= (TotalBytes - 1) ->
    {error, 53}; %% User should not be allowed to split small files to multiple chunks
validate_data_size(DataSize, StartByte, EndByte, _TotalBytes) ->
    case (EndByte - StartByte + 1 =/= DataSize) of
	true -> {error, 1};
	false -> true
    end.

%%
%% Values of Dotted Version Vector are supposed to be timestamps.
%% Make sure the list of timestamps is not empty and all values are integers.
%%
validate_timestamp_list([], _DVV) -> {error, 22};
validate_timestamp_list(List, DVV) ->
    TimeValid = lists:all(
	fun(I) ->
	    try utils:to_integer(I) of
		_ -> true
	    catch error:undef -> false end
	    end, List),
    case TimeValid of
	true -> DVV;
	false -> {error, 22}
    end.

%%
%% Checks if dotted version vector is valid ( base64-encoded JSON )
%%
validate_version(undefined) -> {error, 44};
validate_version(null) -> {error, 44};
validate_version(<<>>) -> {error, 44};
validate_version(Base64DVV) ->
    JSON = base64:decode(Base64DVV),
    case jsx:is_json(JSON) of
	{error, badarg} -> {error, 21};
	false -> {error, 21};
	true ->
	    DVV = jsx:decode(JSON),
	    case DVV of
		[_, _] -> validate_timestamp_list(dvvset:values(DVV), DVV);
		_ -> {error, 22}
	    end
    end.

%%
%% Returns error, if filename contains prohibited characters.
%% Otherwise returns the same provided filename.
%%
validate_filename(undefined) -> {error, 47};
validate_filename(<<>>) -> {error, 47};
validate_filename(<<Bit:2/binary, _Rest/binary>>) when Bit =:= <<"~$">> -> {error, 47};
validate_filename(<<Bit:2/binary, _Rest/binary>>) when Bit =:= <<".~">> -> {error, 47};
validate_filename(FileName)
        when FileName =:= <<"desktop.ini">> orelse
             FileName =:= <<"thumbs.db">> orelse
             FileName =:= <<"ehthumbs.db">> orelse
             FileName =:= <<".ds_store">> orelse
             FileName =:= <<".ds_store?">> orelse
             FileName =:= <<".dropbox">> orelse
             FileName =:= <<".appledouble">> orelse
             FileName =:= <<".spotlight-v100">> orelse
             FileName =:= <<".documentrevisions-v100">> orelse
             FileName =:= <<".temporaryitems">> orelse
             FileName =:= <<".trashes">> orelse
             FileName =:= <<".fseventsd">> orelse
             FileName =:= <<"hiberfil.sys">> orelse
             FileName =:= <<"pagefile.sys">> orelse
             FileName =:= <<"$recycle.bin">> orelse
             FileName =:= <<".pcloud">> orelse
             FileName =:= <<".dropbox.attr">> ->
    {error, 47};
validate_filename(FileName) ->
    %% Test if service object name is used
    case utils:is_hidden_object([{key, unicode:characters_to_list(FileName)}]) of
	true -> {error, 47};
	false ->
	    %% Test if it contains prohibited characters
	    ProhibitedChrs = [<<"<">>, <<">">>, <<":">>, <<$">>, <<"|">>, <<"?">>, <<"*">>],
	    NoProhibitedChrs = lists:all(
		fun(C) ->
		    binary:matches(FileName, C) =:= []
		end, ProhibitedChrs),
	    case NoProhibitedChrs of
		false -> {error, 47};
		true ->
		    case length(unicode:characters_to_list(FileName)) > 260 of
			true -> {error, 48};
			false ->
			    %% Test if it ends with prohibited character
			    ProhibitedTrailingChrs = [<<".">>, <<" ">>,
				erlang:list_to_binary(?RIAK_LOCK_SUFFIX)],
			    NoProhibitedTrailingChrs = lists:all(
				fun(C) ->
				    utils:ends_with(FileName, C) =:= false
				end, ProhibitedTrailingChrs),
			    case NoProhibitedTrailingChrs of
				false -> {error, 47};
				true -> FileName
			    end
		    end
	    end
    end.

%%
%% Returns undefined, in case not an integer provided.
%% Otherwise returns integer value.
%%
validate_integer_field(undefined) -> undefined;
validate_integer_field(Value) when erlang:is_binary(Value) ->
    try utils:to_integer(Value) of
	V -> V
    catch error:badarg ->
	undefined
    end.

validate_md5(undefined) -> {error, 40};
validate_md5(null) -> {error, 40};
validate_md5(<<>>) -> {error, 40};
validate_md5(Value) ->
    try utils:unhex(Value) of
	_Md5 -> Value
    catch
	error:_ -> {error, 40}
    end.

validate_guid(undefined) -> undefined;
validate_guid(<<>>) -> undefined;
validate_guid(null) -> undefined;
validate_guid(GUID) ->
    case byte_size(GUID) of
	36 ->
	    %% the third group of characters must start with the number 4
	    %% fourth group of characters must start with 8, 9, a or b
	    << _:14/binary, Char0:1/binary, _:4/binary, Char1:1/binary, _/binary >> = GUID,
	    case Char0 of
		<<"4">> ->
		    case Char1 of
			<<"8">> -> unicode:characters_to_list(GUID);
			<<"9">> -> unicode:characters_to_list(GUID);
			<<"a">> -> unicode:characters_to_list(GUID);
			<<"b">> -> unicode:characters_to_list(GUID);
			_ -> {error, 42}
		    end;
		_ -> {error, 42}
	    end;
	_ -> {error, 42}
    end.

parse_etags([K,V | T]) -> [{
	utils:to_integer(K),
	utils:to_list(V)
    } | parse_etags(T)];
parse_etags([]) -> [].

%%
%% Checks if etags field contains valid md5 
%%
validate_etags(undefined) -> undefined;  %% Client is testing if last chunk should be uploaded
validate_etags(Etags) ->
    try parse_etags(binary:split(Etags, <<$,>>, [global])) of
	Value -> Value
    catch error:_Error -> {error, 51} end.

%%
%% Checks if upload id is specified for parts > 1
%% as only first chunk is not required to have upload_id.
%%
validate_upload_id(undefined) -> undefined;
validate_upload_id([]) -> undefined;
validate_upload_id(<<>>) -> undefined;
validate_upload_id(null) -> undefined;
validate_upload_id(Value) -> erlang:binary_to_list(Value).

validate_upload_id(Value, 1) -> validate_upload_id(Value);
validate_upload_id(Value, _) ->
    case validate_upload_id(Value) of
	undefined -> {error, 25};
	V -> V
    end.

validate_content_range(Req) ->
    PartNumber =
	try utils:to_integer(cowboy_req:binding(part_num, Req)) of
	    N -> N
	catch error:_ -> 1
	end,
    UploadId0 = validate_upload_id(cowboy_req:binding(upload_id, Req), PartNumber),
    case cowboy_req:header(<<"content-range">>, Req) of
	undefined -> {error, 52};
	null -> {error, 52};
	Value ->
	    try cow_http_hd:parse_content_range(Value) of
		{bytes, Start, End, Total} ->
		    case (Total > ?FILE_MAXIMUM_SIZE) orelse (End - Start > ?FILE_UPLOAD_CHUNK_SIZE) of
			true -> {error, 24};
			false ->
			    case UploadId0 of
				{error, Number} -> {error, Number};
				_ -> [{part_number, PartNumber}, {upload_id, UploadId0},
				      {start_byte, Start}, {end_byte, End},
				      {total_bytes, Total}]
			    end
		    end
	    catch error:function_clause ->
		{error, 25}
	    end
    end.


add_action_log_record(State) ->
    User = proplists:get_value(user, State),
    BucketId = proplists:get_value(bucket_id, State),
    Prefix = proplists:get_value(prefix, State),
    OrigName = proplists:get_value(orig_name, State),  %% generated name
    TotalBytes = proplists:get_value(total_bytes, State),
    UploadTime = proplists:get_value(upload_time, State),
    ActionLogRecord0 = #riak_action_log_record{
	action="upload",
	user_name=User#user.name,
	tenant_name=User#user.tenant_name,
	timestamp=UploadTime
    },
    UnicodeObjectKey = unicode:characters_to_list(OrigName),
    Summary = lists:flatten([["Uploaded \""], [UnicodeObjectKey],
	[io_lib:format("\" ( ~p B )", [TotalBytes])]]),
    ActionLogRecord1 = ActionLogRecord0#riak_action_log_record{details=Summary},
    action_log:add_record(BucketId, Prefix, ActionLogRecord1).

%%
%% .Net sends UTF-8 filename in "filename*" field, when "filename" contains garbage.
%%
%% Params:
%%
%% [{<<"name">>,<<"files[]">>},
%% {<<"filename">>,
%%  <<"Something.random">>},
%% {<<"filename*">>,
%%  <<"utf-8''Something.random">>}]
%%
extract_rfc2231_filename(FormDataParams) ->
    case proplists:get_value(<<"filename*">>, FormDataParams) of
	undefined -> proplists:get_value(<<"filename">>, FormDataParams);
	FileName2 ->
	    FileNameByteSize = byte_size(FileName2),
	    if FileNameByteSize < 8 -> undefined;
		true ->
		    case binary:part(FileName2, {0, 7}) of
			<<"utf-8''">> ->
			    FileName4 = binary:part(FileName2, {7, FileNameByteSize-7}),
			    cow_qs:urldecode(FileName4);
			_ -> undefined
		    end
	    end
    end.

%%
%% Parse POST fields.
%%
%% version -- base64-json-encoded dotted version vector
%% md5 -- chunk's checksum
%% etags[] -- list of MD5
%% prefix -- hex-encoded directory name
%% files[] -- binary blob
%%
acc_multipart(Req0, Acc) ->
    case cowboy_req:read_part(Req0) of
	{ok, Headers0, Req1} ->
	    {ok, Body, Req2} = stream_body(Req1, <<>>),
		Headers1 = maps:to_list(Headers0),
		{_, DispositionBin} = lists:keyfind(<<"content-disposition">>, 1, Headers1),
		{<<"form-data">>, Params} = cow_multipart:parse_content_disposition(DispositionBin),
		FieldName0 =
		    case lists:keyfind(<<"name">>, 1, Params) of
			false -> undefined;
			{_, FN} -> FN
		    end,
		FieldName1 =
		    case FieldName0 of
			<<"version">> -> version;
			<<"md5">> -> md5;        %% chunk md5
			<<"etags[]">> -> etags;  %% md5 checksums of all chunks
			<<"prefix">> -> prefix;
			<<"files[]">> -> blob;
			<<"guid">> -> guid;      %% for tracking history
			<<"width">> -> width;
			<<"height">> -> height;
			_ -> undefined
		    end,
		case FieldName1 of
		    blob ->
			Filename = extract_rfc2231_filename(Params),
			acc_multipart(Req2, [{blob, Body}, {filename, Filename}|Acc]);
		    undefined -> acc_multipart(Req2, Acc);
		    _ -> acc_multipart(Req2, [{FieldName1, Body}|Acc])
		end;
	{done, Req} -> {lists:reverse(Acc), Req}
    end.

%%
%% Reads HTTP request body.
%%
stream_body(Req0, Acc) ->
    case cowboy_req:read_part_body(Req0, #{length => ?FILE_UPLOAD_CHUNK_SIZE + 5000}) of
        {more, Data, Req} -> stream_body(Req, << Acc/binary, Data/binary >>);
        {ok, Data, Req} -> {ok, << Acc/binary, Data/binary >>, Req}
    end.

%%
%% Validates provided parameters and calls 'upload_to_riak()'
%%
handle_post(Req0, State) ->
    case cowboy_req:method(Req0) of
	<<"POST">> ->
	    {FieldValues, Req1} = acc_multipart(Req0, []),
	    FileName0 = validate_filename(proplists:get_value(filename, FieldValues)),
	    BucketId = proplists:get_value(bucket_id, State),
	    Prefix0 = list_handler:validate_prefix(BucketId, proplists:get_value(prefix, FieldValues)),
	    GUID = validate_guid(proplists:get_value(guid, FieldValues)),
	    UploadTime = erlang:round(utils:timestamp()/1000),
	    Version =
		try
		    validate_version(proplists:get_value(version, FieldValues))
		catch error:_ ->
		    {error, 22}
		end,
	    Blob = proplists:get_value(blob, FieldValues),
	    BlobSize = byte_size(Blob),
	    Md5 = validate_md5(proplists:get_value(md5, FieldValues)),
	    StartByte = proplists:get_value(start_byte, State),
	    EndByte = proplists:get_value(end_byte, State),
	    TotalBytes = proplists:get_value(total_bytes, State),
	    DataSizeOk =
		case Blob of
		    undefined -> true;
		    _ -> validate_data_size(BlobSize, StartByte, EndByte, TotalBytes)
		end,
	    Etags = validate_etags(proplists:get_value(etags, FieldValues)),
	    Width0 = validate_integer_field(proplists:get_value(width, FieldValues)),
	    Height0 = validate_integer_field(proplists:get_value(height, FieldValues)),
	    %% Both width and height of image must be specified
	    {Width1, Height1} =
		case lists:all(fun(I) -> I =/= undefined end, [Width0, Height0]) of
		    true -> {Width0, Height0};
		    false -> {undefined, undefined}
		end,
	    case lists:keyfind(error, 1, [FileName0, Prefix0, GUID, Version, DataSizeOk, TotalBytes, Md5, Etags]) of
		{error, Number} -> js_handler:bad_request(Req1, Number);
		false ->
		    NewState = [
			{etags, Etags},
			{prefix, Prefix0},
			{file_name, FileName0},
			{version, Version},
			{md5, Md5},
			{guid, GUID},
			{upload_time, UploadTime},
			{width, Width1},
			{height, Height1}
		    ] ++ State,
		    %% If object is locked and current user is not owner of the lock, return lock info
		    lock_check(Req0, NewState, Blob)
	    end;
	_ -> js_handler:bad_request(Req0, 2)
    end.

%%
%% Check if object is locked and returns JSON-serializable response.
%% Otherwise returns undefined.
%%
-spec get_object_lock(list()|undefined, list()) -> {list()|undefined}.

get_object_lock(undefined, _UserId) -> undefined;
get_object_lock(ExistingObject, UserId) when ExistingObject#object.is_locked =:= true ->
    LockUserId = ExistingObject#object.lock_user_id,
    case LockUserId =/= undefined andalso UserId =/= LockUserId of
	false -> undefined;
	true ->
	    LockUserName = ExistingObject#object.lock_user_name,
	    LockModifiedTime = ExistingObject#object.lock_modified_utc,
	    LockUserTel0 = ExistingObject#object.lock_user_tel,
	    LockUserTel1 =
                case LockUserTel0 of
                    undefined -> null;
                    V -> V
                end,
	    [{is_locked, <<"true">>},
	     {lock_user_id, erlang:list_to_binary(LockUserId)},
	     {lock_user_name, LockUserName},
	     {lock_user_tel, LockUserTel1},
	     {lock_modified_utc, LockModifiedTime}]
    end;
get_object_lock(_ExistingObject, _UserId) -> undefined.

%%
%% After we have picked the name for the upload object, we need GUID as well.
%% It will be used to track history of all operations on object: rename, replace, move, copy, etc.
%%
%% The destination object GUID can be different ( e.g. user could edit a conflicted copy ).
%% We need an original GUID, in order to keep track of changes and to remove previous version.
-spec get_guid(GUID, ExistingGUID, IsConflict) -> any() when
    GUID :: string(),         %% GUID provided in request
    ExistingGUID :: string(), %% GUID from existing object, found by pick_object_key()
    IsConflict :: boolean().  %% flag indicating a conflicted version

get_guid(undefined, undefined, false) -> erlang:binary_to_list(riak_crypto:uuid4());
get_guid(undefined, ExistingGUID, false) -> ExistingGUID;
get_guid(GUID, undefined, false) -> GUID;
get_guid(GUID, GUID, false) -> GUID;
%% For some reason client uploads file with a different GUID. Use an existing one.
get_guid(_GUID, ExistingGUID, false) -> ExistingGUID;

%% Conflict detected when client tried to upload file
get_guid(undefined, _ExistingGUID, true) -> erlang:binary_to_list(riak_crypto:uuid4());
get_guid(GUID, _ExistingGUID, true) -> GUID.

%%
%% Contents of the object storage could have canged since the list command was called.
%% Therefore we need to find a recent GUID.
%%
existing_guid(_BucketId, _Prefix, undefined) -> undefined;
existing_guid(BucketId, Prefix, ExistingObject) ->
    ObjectKey = ExistingObject#object.key,
    case riak_api:head_object(BucketId, utils:prefixed_object_key(Prefix, ObjectKey)) of
	{error, Reason} ->
	    lager:error("[upload_handler] head_object failed ~p/~p: ~p",
			[BucketId, utils:prefixed_object_key(Prefix, ObjectKey), Reason]),
	    undefined;
	not_found -> undefined;
	ConflictedMeta -> proplists:get_value("x-amz-meta-guid", ConflictedMeta)
    end.

%%
%% Returns "locked" response if object lock exists.
%% Otherwise proceeds to the next check.
%%
lock_check(Req0, State0, BinaryData) ->
    BucketId = proplists:get_value(bucket_id, State0),
    Prefix = proplists:get_value(prefix, State0),
    FileName = proplists:get_value(file_name, State0),
    Version = proplists:get_value(version, State0),
    IndexContent = indexing:get_index(BucketId, Prefix),
    User = proplists:get_value(user, State0),
    UserName = utils:unhex(erlang:list_to_binary(User#user.name)),
    {_ObjectKey, _OrigName, _IsNewVersion, ExistingObject, IsConflict} = riak_api:pick_object_key(
	BucketId, Prefix, FileName, Version, UserName, IndexContent),
    case get_object_lock(ExistingObject, User#user.id) of
	undefined ->
	    PartNumber = proplists:get_value(part_number, State0),
	    case PartNumber of
		1 ->
		    %% The GUID from client could be outdated for that object, so it has to be updated
		    ExistingGUID = existing_guid(BucketId, Prefix, ExistingObject),
		    GUID = get_guid(proplists:get_value(guid, State0), ExistingGUID, IsConflict),
		    State1 = lists:keyreplace(guid, 1, State0, {guid, GUID}),
		    check_part(Req0, BinaryData, State1 ++ [{object, ExistingObject}]);
		_ -> check_part(Req0, BinaryData, State0 ++ [{object, ExistingObject}])
	    end;
	LockData ->
	    Req1 = cowboy_req:reply(423, #{
		<<"content-type">> => <<"application/json">>
	    }, jsx:encode(LockData), Req0),
	{stop, Req1, []}
    end.

%%
%% Checks the following
%% - correct bucket and prefix were specified
%% - appropriate GUID specified for the upload id
%% - version corresponds to what is stored by upload id
%%
check_upload_id(undefined, State) -> State;
check_upload_id(null, State) -> State;
check_upload_id([], State) -> State;
check_upload_id(UploadId, State0) ->
    case riak_api:head_object(?UPLOADS_BUCKET_NAME, UploadId) of
	{error, _} -> {error, 5};
	not_found -> {error, 5};
	Meta ->
	    UploadObjectMeta = list_handler:parse_object_record(Meta, []),
	    BucketId = proplists:get_value(bucket_id, State0),
	    Prefix = proplists:get_value(prefix, State0),
	    GUID = proplists:get_value(guid, State0),
	    MetaGUID = proplists:get_value("x-amz-meta-guid", Meta),
	    IsCorrectBucketId =
		case proplists:get_value("x-amz-meta-bucket_id", Meta) of
		    BucketId -> true;
		    _ -> {error, 37}
		end,
	    IsCorrectPrefix =
		case proplists:get_value("x-amz-meta-prefix", Meta) of
		    Prefix -> true;
		    _ -> {error, 36}
		end,
	    IsCorrectGUID =
		case GUID of
		    undefined -> true;
		    _ ->
			case MetaGUID of
			    GUID -> true;
			    _ -> {error, 4}
			end
		end,
	    Version0 = proplists:get_value("version", UploadObjectMeta),
	    Version1 = jsx:decode(base64:decode(Version0)),
	    IsCorrectVersion =
		case proplists:get_value(version, State0) of
		    Version1 -> true;
		    _ -> {error, 22}
		end,
	    case lists:keyfind(error, 1, [IsCorrectBucketId, IsCorrectPrefix, IsCorrectVersion, IsCorrectGUID]) of
		{error, Number} -> {error, Number};
		false ->
		    State1 = lists:keyreplace(guid, 1, State0, {guid, MetaGUID}),
		    lists:keyreplace(version, 1, State1, {version, Version1})
	    end
    end.

%%
%% Adds an upload object, in order to register a new upload
%%
-spec create_upload_id(UploadId, State0) -> ok|any() when
    UploadId :: undefined|string(),
    State0 :: proplist().
create_upload_id(undefined, State0) ->
    ExistingObject = proplists:get_value(object, State0),
    Meta0 =
	case ExistingObject of
	    undefined -> [];
	    _ ->
		case ExistingObject#object.is_locked of
		    true ->
			[{is_locked, "true"},
			 {lock_user_id, ExistingObject#object.lock_user_id},
			 {lock_user_name, ExistingObject#object.lock_user_name},
			 {lock_user_tel, ExistingObject#object.lock_user_tel},
			 {lock_modified_utc, ExistingObject#object.lock_modified_utc}];
		    undefined -> [];
		    false -> []
		end
	end,
    FileName = proplists:get_value(file_name, State0),
    Version0 = proplists:get_value(version, State0),
    Version1 = base64:encode(jsx:encode(Version0)),
    UploadTime = proplists:get_value(upload_time, State0),
    GUID =
	case proplists:get_value(guid, State0) of
	    undefined -> erlang:binary_to_list(riak_crypto:uuid4());
	    G -> G
	end,
    User = proplists:get_value(user, State0),
    TotalBytes = proplists:get_value(total_bytes, State0),
    Meta1 = list_handler:parse_object_record([], Meta0 ++ [
	{orig_name, utils:hex(FileName)},
	{version, Version1},
	{upload_time, UploadTime},
	{guid, GUID},
	{author_id, User#user.id},
	{author_name, User#user.name},
	{author_tel, User#user.tel},
	{is_deleted, "false"},
	{bytes, utils:to_list(TotalBytes)},
	{width, proplists:get_value(width, State0)},
	{height, proplists:get_value(height, State0)}
    ]),
    BucketId = proplists:get_value(bucket_id, State0),
    Prefix = proplists:get_value(prefix, State0),
    Meta2 = [{"prefix", Prefix}, {"bucket_id", BucketId}],
    Options = [{meta, Meta1 ++ Meta2}],
    UploadId = erlang:binary_to_list(riak_crypto:uuid4()),
    Response = riak_api:put_object(?UPLOADS_BUCKET_NAME, undefined, UploadId, <<>>, Options),
    case Response of
	{error, Reason} ->
	    lager:error("[upload_handler] Can't put object ~p/~p: ~p",
			[?UPLOADS_BUCKET_NAME, UploadId, Reason]),
	    {error, Reason};
	_ -> {GUID, UploadId, Response}
    end;
create_upload_id(UploadId, State) ->
    GUID = proplists:get_value(guid, State),
    {GUID, UploadId, ok}.

%%
%% Check if we have file part with that md5 already. Copy that part in that case.
%%
check_part(Req0, <<>>, State0) ->
    case riak_api:head_bucket(?UPLOADS_BUCKET_NAME) of
    	not_found -> riak_api:create_bucket(?UPLOADS_BUCKET_NAME);
	_ -> ok
    end,
    BucketId = proplists:get_value(bucket_id, State0),
    GUID0 = proplists:get_value(guid, State0),
    Md5 = proplists:get_value(md5, State0),
    PartNumber = proplists:get_value(part_number, State0),
    case PartNumber of
	1 ->
	    List0 = find_chunk(BucketId, GUID0, Md5),
	    upload_part(Req0, <<>>, List0, State0);
	_ ->
	    %% Check if a correct upload id was provided
	    UploadId = proplists:get_value(upload_id, State0),
	    case check_upload_id(UploadId, State0) of
		{error, Number} -> js_handler:bad_request(Req0, Number);
		State1 ->
		    GUID1 = proplists:get_value(guid, State1),
		    List1 = find_chunk(BucketId, GUID1, Md5),
		    upload_part(Req0, <<>>, List1, State1)
	    end
    end;
%%
%% Checks if provided upload ID exists first.
%% If not, then copy chunk internally.
%% Otherwise put `BinaryData` to Riak CS
%%
check_part(Req0, BinaryData, State0) ->
    IsCorrectMd5 =
	case proplists:get_value(md5, State0) of
	    undefined -> false;
	    Md5 ->
		Checksum = utils:hex(riak_crypto:md5(BinaryData)),
		erlang:list_to_binary(Checksum) =:= Md5
	end,
    case IsCorrectMd5 of
	false -> js_handler:bad_request(Req0, 40);
	true ->
	    PartNumber = proplists:get_value(part_number, State0),
	    case PartNumber of
		1 -> upload_part(Req0, BinaryData, State0);
		_ ->
		    UploadId = proplists:get_value(upload_id, State0),
		    case check_upload_id(UploadId, State0) of
			{error, Number} -> js_handler:bad_request(Req0, Number);
			State1 -> upload_part(Req0, BinaryData, State1)
		    end
	    end
    end.

%%
%% Looks up an existing chunk of data, by inspecting previous versions of object.
%%
find_chunk(_BucketId, undefined, _Md5) -> [];
find_chunk(BucketId, GUID, Md5) ->
    find_chunk(BucketId, GUID, <<>>, Md5).
find_chunk(BucketId, GUID, UploadId, Md5) ->
    PrefixedGUID = utils:prefixed_object_key(?RIAK_REAL_OBJECT_PREFIX, GUID) ++ "/",
    MaxKeys = ?FILE_MAXIMUM_SIZE div ?FILE_UPLOAD_CHUNK_SIZE,
    %% go through GUIDs ( object history history unique identifiers )
    case riak_api:list_objects(BucketId, [{max_keys, MaxKeys}, {prefix, PrefixedGUID}]) of
	not_found -> [];
	RiakResponse0 ->
	    lists:filtermap(
		fun(I) ->
		    Prefix = proplists:get_value(prefix, I),
		    Suffix = lists:last(string:tokens(Prefix, "/")),
		    case Suffix of
			UploadId -> false;  %% do not look at the current upload chunks
			_ ->
			    %% iterate through upload ids within history
			    RiakResponse1 = riak_api:list_objects(BucketId,
				    [{prefix, Prefix}, {max_keys, MaxKeys}]),
			    Contents =
				case RiakResponse1 of
				    not_found -> [];
				    _ -> proplists:get_value(contents, RiakResponse1)
				end,
			    Matches = lists:filtermap(
				fun(K) ->
				    ObjectKey = proplists:get_value(key, K),
				    case utils:ends_with(ObjectKey, Md5) of
					true -> {true, ObjectKey};
					false -> false
				    end
				end, Contents),
			    case Matches of
				[] -> false;
				[H|_T] -> {true, H}
			    end
		    end
		end, proplists:get_value(common_prefixes, RiakResponse0))
    end.

%%
%% If the final part provided, finalize the upload by updating index,
%% otherwise respond with ``RespCode`` http status code.
%%
upload_response(Req0, GUID, UploadId, RespCode, State0) ->
    Md5 = proplists:get_value(md5, State0),
    EndByte = proplists:get_value(end_byte, State0),
    TotalBytes = proplists:get_value(total_bytes, State0),
    Etags0 = proplists:get_value(etags, State0),
    case (EndByte+1 =:= TotalBytes) of
	true ->
	    case Etags0 of
		undefined -> js_handler:bad_request(Req0, 51);
		_ ->
		    State1 = lists:keyreplace(upload_id, 1, State0, {upload_id, UploadId}),
		    State2 = lists:keyreplace(guid, 1, State1, {guid, GUID}),
		    complete_upload(Req0, Etags0, RespCode, State2)
	    end;
	false ->
	    Req1 = cowboy_req:reply(RespCode, #{
		<<"content-type">> => <<"application/json">>
	    }, jsx:encode([
		{end_byte, EndByte},
		{guid, unicode:characters_to_binary(GUID)},
		{upload_id, unicode:characters_to_binary(UploadId)},
		{md5, Md5}
	    ]), Req0),
	    {stop, Req1, []}
    end.

%%
%% Final response, sent after last part uploaded
%%
upload_response(Req0, OrigName, IsLocked, LockModifiedTime, LockedUserId, LockedUserName, LockedUserTel, RespCode, State0) ->
    User = proplists:get_value(user, State0),
    BucketId = proplists:get_value(bucket_id, State0),
    Prefix = proplists:get_value(prefix, State0),
    Version = proplists:get_value(version, State0),
    UploadId = proplists:get_value(upload_id, State0),
    UploadTime = proplists:get_value(upload_time, State0),
    TotalBytes = proplists:get_value(total_bytes, State0),
    GUID = proplists:get_value(guid, State0),
    ObjectKey0 = proplists:get_value(object_key, State0),
    State1 = [
	{bucket_id, BucketId},
	{prefix, Prefix},
	{upload_time, erlang:integer_to_list(UploadTime)},
	{orig_name, OrigName},
	{total_bytes, TotalBytes},
	{user, proplists:get_value(user, State0)}
    ],
    add_action_log_record(State1),
    IsLocked1 =
	case IsLocked of
	    undefined -> false;
	    _ -> IsLocked
	end,
    AuthorTel =
	case User#user.tel of
	    undefined -> null;
	    [] -> null;
	    _ -> unicode:characters_to_binary(utils:unhex(erlang:list_to_binary(User#user.tel)))
	end,
    UploadId = proplists:get_value(upload_id, State0),
    case riak_api:delete_object(?UPLOADS_BUCKET_NAME, UploadId) of
	{error, Reason} -> lager:error("[upload_handler] failed to delete upload id ~p: ~p",
					[UploadId, Reason]);
	{ok, _} -> ok
    end,
    Req1 = cowboy_req:reply(RespCode, #{
	<<"content-type">> => <<"application/json">>
    }, jsx:encode([
	{guid, unicode:characters_to_binary(GUID)},
	{orig_name, OrigName},
	{version, base64:encode(jsx:encode(Version))},
	{object_key, erlang:list_to_binary(ObjectKey0)},
	{upload_id, erlang:list_to_binary(UploadId)},
	{end_byte, proplists:get_value(end_byte, State0, null)},
	{md5, proplists:get_value(md5, State0, null)},
	{upload_time, UploadTime},
	{author_id, erlang:list_to_binary(User#user.id)},
	{author_name, unicode:characters_to_binary(utils:unhex(erlang:list_to_binary(User#user.name)))},
	{author_tel, AuthorTel},
	{is_locked, IsLocked1},
	{lock_modified_utc, value_or_null(LockModifiedTime)},
	{lock_user_id, to_binary(LockedUserId)},
	{lock_user_name, to_binary(LockedUserName)},
	{lock_user_tel, to_binary(LockedUserTel)},
	{is_deleted, false},
	{bytes, TotalBytes},
	{width, value_or_null(proplists:get_value(width, State0))},
	{height, value_or_null(proplists:get_value(height, State0, null))}
    ]), Req0),
    {stop, Req1, []}.


%%
%% In case data was not provided and upload id has not been created, reply 200.
%%
upload_part(Req0, <<>>, [], State0) ->
    GUID =
	case proplists:get_value(guid, State0) of
	    undefined -> erlang:binary_to_list(riak_crypto:uuid4());
	    G -> G
	end,
    EndByte = proplists:get_value(end_byte, State0),
    Md5 = proplists:get_value(md5, State0),
    UploadId =
	case proplists:get_value(upload_id, State0) of
	    undefined -> null;
	    Id -> unicode:characters_to_binary(Id)
	end,
    %% Reply 200, -- "go ahead and upload that chunk"
    Req1 = cowboy_req:reply(200, #{
	<<"content-type">> => <<"application/json">>
    }, jsx:encode([
	{end_byte, EndByte},
	{guid, unicode:characters_to_binary(GUID)},
	{upload_id, UploadId},
	{md5, Md5}
    ]), Req0),
    {stop, Req1, []};

%%
%% Tries to copy an existing chunk to the destination path ( real obj prefix/guid/upload_id )
%%
upload_part(Req0, <<>>, [PrefixedSrcObjectKey|_], State0) ->
    case create_upload_id(proplists:get_value(upload_id, State0), State0) of
	{GUID, UploadId, ok} ->
	    BucketId = proplists:get_value(bucket_id, State0),
	    Md5 = proplists:get_value(md5, State0),
	    PartNumber = proplists:get_value(part_number, State0),

	    RealPrefix = utils:prefixed_object_key(?RIAK_REAL_OBJECT_PREFIX, GUID),
	    DstRealPrefix = utils:prefixed_object_key(RealPrefix, UploadId),
	    DstObjectKey = lists:concat([erlang:integer_to_list(PartNumber), "_", erlang:binary_to_list(Md5)]),
	    PrefixedDstObjectKey = utils:prefixed_object_key(DstRealPrefix, DstObjectKey),
	    CopyResult = riak_api:copy_object(BucketId, PrefixedDstObjectKey,
					      BucketId, PrefixedSrcObjectKey),
	    case CopyResult of
		[{content_length,_}] ->
		    %% Tell the client to not upload the chunk, as we have it
		    upload_response(Req0, GUID, UploadId, 206, State0);
		{error, _} ->
		    %% For some reason source object has disappeared, tell the client to upload
		    Req1 = cowboy_req:reply(200, #{
			<<"content-type">> => <<"application/json">>
		    }, jsx:encode([
			{guid, unicode:characters_to_binary(GUID)},
			{upload_id, UploadId},
			{md5, Md5}
		    ]), Req0),
		    {stop, Req1, []}
	    end;
	{error, Reason} -> js_handler:bad_request(Req0, Reason)
    end.

%%
%% Uploads binary chunk to Riak CS.
%%
upload_part(Req0, BinaryData, State0) ->
    BucketId = proplists:get_value(bucket_id, State0),
    Md5 = proplists:get_value(md5, State0),
    PartNumber = proplists:get_value(part_number, State0),
    case riak_api:head_bucket(BucketId) of
    	not_found -> riak_api:create_bucket(BucketId);
	_ -> ok
    end,
    case create_upload_id(proplists:get_value(upload_id, State0), State0) of
	{GUID, UploadId, ok} ->
	    ObjectKey = lists:concat([erlang:integer_to_list(PartNumber), "_", erlang:binary_to_list(Md5)]),
	    RealPrefix = utils:prefixed_object_key(?RIAK_REAL_OBJECT_PREFIX, GUID),
	    PrefixedUploadId = utils:prefixed_object_key(RealPrefix, UploadId),
	    case riak_api:put_object(BucketId, PrefixedUploadId, ObjectKey, BinaryData, []) of
		ok -> upload_response(Req0, GUID, UploadId, 200, State0);
		{error, Reason} ->
		    lager:error("[upload_handler] Can't put object ~p/~p/~p: ~p",
				[BucketId, PrefixedUploadId, ObjectKey, Reason]),
		    js_handler:too_many(Req0)
	    end;
	{error, Reason} -> js_handler:bad_request(Req0, Reason)
    end.

%%
%% Check MD5's and finalize upload by updating object
%%
complete_upload(Req0, Etags0, RespCode, State0) ->
    BucketId = proplists:get_value(bucket_id, State0),
    GUID = proplists:get_value(guid, State0),
    UploadId = proplists:get_value(upload_id, State0),
    PrefixedGUID = utils:prefixed_object_key(?RIAK_REAL_OBJECT_PREFIX, GUID),
    PrefixedUploadId = utils:prefixed_object_key(PrefixedGUID, UploadId) ++ "/",
    MaxKeys = ?FILE_MAXIMUM_SIZE div ?FILE_UPLOAD_CHUNK_SIZE,
    case riak_api:list_objects(BucketId, [{prefix, PrefixedUploadId}, {max_keys, MaxKeys}]) of
	not_found ->
	    lager:warning("[upload_handler] Upload id not found: ~p/~p", [BucketId, PrefixedUploadId]),
	    js_handler:too_many(Req0);
	RiakResponse ->
	    List0 = [lists:last(string:tokens(proplists:get_value(key, I), "/"))
		     || I <- proplists:get_value(contents, RiakResponse)],
	    List1 = lists:filtermap(
		fun(I) ->
		    case string:tokens(I, "_") of
			[PN, Checksum] -> {true, {erlang:list_to_integer(PN), Checksum}};
			_ -> false
		    end
		end, List0),
	    S0 = sets:from_list(List1),
	    S1 = sets:from_list(Etags0),
	    case sets:is_subset(S0, S1) andalso sets:is_subset(S1, S0) of
		false -> js_handler:bad_request(Req0, 51);
		true -> complete_upload(Req0, RespCode, State0)
	    end
    end.

complete_upload(Req0, RespCode, State0) ->
    BucketId = proplists:get_value(bucket_id, State0),
    Prefix = proplists:get_value(prefix, State0),
    FileName = proplists:get_value(file_name, State0),
    GUID = proplists:get_value(guid, State0),
    UploadId = proplists:get_value(upload_id, State0),
    User = proplists:get_value(user, State0),
    UserName = utils:unhex(erlang:list_to_binary(User#user.name)),
    TotalBytes = proplists:get_value(total_bytes, State0),
    Version0 = proplists:get_value(version, State0),
    ExistingObject = proplists:get_value(object, State0),

    IndexContent = indexing:get_index(BucketId, Prefix),
    {ObjectKey0, OrigName0, _IsNewVersion, _ExistingObject, IsConflict} = riak_api:pick_object_key(BucketId, Prefix,
	FileName, Version0, UserName, IndexContent),
    Meta0 = [
	{"orig-filename", utils:hex(OrigName0)},
	{"version", base64:encode(jsx:encode(Version0))},
	{"upload-time", proplists:get_value(upload_time, State0)},
	{"guid", GUID},
	{"author-id", User#user.id},
	{"author-name", User#user.name},
	{"author-tel", User#user.tel},
	{"is-deleted", false},
	{"bytes", utils:to_list(TotalBytes)},
	{"width", proplists:get_value(width, State0)},
	{"height", proplists:get_value(height, State0)},
	{"is-locked", false}
    ],
    Options = [{meta, Meta0}],
    case riak_api:put_object(BucketId, Prefix, ObjectKey0, <<>>, Options) of
	ok ->
	    case ExistingObject of
		undefined -> ok;
		_ ->
		    case IsConflict of
			true ->
			    %% delete older conflict
			    delete_previous_one(BucketId, GUID, ExistingObject#object.upload_id, Version0);
			false ->
			    case ExistingObject#object.guid of
				GUID -> delete_previous_one(BucketId,
							    ExistingObject#object.guid,
							    UploadId,
							    Version0);
				_ -> ok %% GUID has changed, do nothing
			    end
		    end
	    end,
	    State1 = lists:keyreplace(guid, 1, State0, {guid, GUID}),
	    update_index(Req0, OrigName0, RespCode, State1 ++ [{object_key, ObjectKey0}, {is_conflict, IsConflict}]);
	{error, Reason} ->
	    lager:error("[upload_handler] Can't put object ~p/~p/~p: ~p",
			[BucketId, Prefix, ObjectKey0, Reason]),
	    js_handler:incorrect_configuration(Req0, "Something's went horribly wrong.")
    end.

value_or_null(null) -> null;
value_or_null(undefined) -> null;
value_or_null(Value) -> Value.

to_binary(null) -> null;
to_binary(undefined) -> null;
to_binary(Value) when erlang:is_list(Value) -> erlang:list_to_binary(Value);
to_binary(Value) when erlang:is_binary(Value) -> Value.

hex_or_undefined(undefined) -> undefined;
hex_or_undefined(Value) -> utils:hex(Value).

%%
%% Creates link to actual object, updates index.
%%
update_index(Req0, OrigName0, RespCode, State0) ->
    User = proplists:get_value(user, State0),
    BucketId = proplists:get_value(bucket_id, State0),
    Prefix = proplists:get_value(prefix, State0),
    Version = proplists:get_value(version, State0),
    UploadId = proplists:get_value(upload_id, State0),
    UploadTime = proplists:get_value(upload_time, State0),
    TotalBytes = proplists:get_value(total_bytes, State0),
    GUID = proplists:get_value(guid, State0),
    ObjectKey0 = proplists:get_value(object_key, State0),
    IsConflict = proplists:get_value(is_conflict, State0),
    {IsLocked0, LockModifiedTime0, LockedUserId0, LockedUserName0, LockedUserTel0, LockedUserTime} =
	case proplists:get_value(object, State0) of
	    undefined -> {undefined, undefined, undefined, undefined, undefined, undefined};
	    ExistingObject ->
		case IsConflict of
		    true -> {undefined, undefined, undefined, undefined, undefined, undefined};
		    false -> {ExistingObject#object.is_locked,
			      ExistingObject#object.lock_modified_utc,
			      ExistingObject#object.lock_user_id,
			      ExistingObject#object.lock_user_name,
			      ExistingObject#object.lock_user_tel,
			      ExistingObject#object.lock_modified_utc}
		end
	end,
    LockedUserName1 = hex_or_undefined(LockedUserName0),
    LockedUserTel1 = hex_or_undefined(LockedUserTel0),
    EncodedVersion = erlang:binary_to_list(base64:encode(jsx:encode(Version))),
    %% Put link to the real object at the specified prefix
    Meta = list_handler:parse_object_record([], [
	    {orig_name, utils:hex(OrigName0)},
	    {version, EncodedVersion},
	    {upload_time, UploadTime},
	    {guid, GUID},
	    {upload_id, UploadId},
	    {author_id, User#user.id},
	    {author_name, User#user.name},
	    {author_tel, User#user.tel},
	    {is_locked, utils:to_list(IsLocked0)},
	    {lock_modified_utc, LockModifiedTime0},
	    {lock_user_id, LockedUserId0},
	    {lock_user_name, LockedUserName1},
	    {lock_user_tel, LockedUserTel1},
	    {is_deleted, "false"},
	    {bytes, utils:to_list(TotalBytes)}
	]),
    MimeType = light_ets:guess_content_type(ObjectKey0),
    %% get width and height of image, if it is less than 50 MB
    WidthHeight =
	case TotalBytes > ?MAXIMUM_IMAGE_SIZE_BYTES orelse utils:starts_with(MimeType, <<"image/">>) =:= false of
	    true ->
		[{"width", proplists:get_value(width, State0)},
		 {"height", proplists:get_value(height, State0)}];
	    false ->
		case riak_api:get_object(BucketId, GUID, UploadId) of
		    {error, Reason0} ->
			lager:error("[upload_handler] get_object error ~p/~p: ~p",
				    [BucketId, GUID, Reason0]),
			[{"width", proplists:get_value(width, State0)},
			 {"height", proplists:get_value(height, State0)}];
		    not_found ->
			[{"width", proplists:get_value(width, State0)},
			 {"height", proplists:get_value(height, State0)}];
		    RiakResponse ->
			Reply0 = img:scale([{from, RiakResponse}, {just_get_size, true}]),
			case Reply0 of
			    {error, _} ->
				[{"width", proplists:get_value(width, State0)},
				 {"height", proplists:get_value(height, State0)}];
			    {Width, Height} -> [{"width", Width}, {"height", Height}]
			end
		end
	end,
    case indexing:add_dvv(BucketId, GUID, UploadId, Version, User#user.id, User#user.name) of
	lock -> js_handler:too_many(Req0);
	_ ->
	    Options = [{meta, Meta++WidthHeight}],
	    case riak_api:put_object(BucketId, Prefix, ObjectKey0, <<>>, Options) of
		ok ->
		    %% Update pseudo-directory index for faster listing.
		    case indexing:update(BucketId, Prefix, [{modified_keys, [ObjectKey0]}]) of
			lock ->
			    lager:warning("[list_handler] Can't update index during upload, as lock exist: ~p/~p",
				       [BucketId, Prefix]),
			    js_handler:too_many(Req0);
			_ ->
			    %% Update Solr index if file type is supported
			    %% TODO: uncomment the following
			    %%gen_server:abcast(solr_api, [{bucket_id, BucketId},
			    %% {prefix, Prefix},
			    %% {total_bytes, TotalBytes}]),

			    %% Update SQLite db
			    Obj = #object{
				key = ObjectKey0,
				orig_name = unicode:characters_to_list(OrigName0),
				bytes = TotalBytes,
				guid = GUID,
				version = EncodedVersion,
				upload_time = UploadTime,
				is_deleted = false,
				author_id = User#user.id,
				author_name = User#user.name,
				author_tel = User#user.tel,
				is_locked = false,
				lock_user_id = LockedUserId0,
				lock_user_name = LockedUserName1,
				lock_user_tel = LockedUserTel1,
				lock_modified_utc = LockedUserTime
			    },
			    sqlite_server:add_object(BucketId, Prefix, Obj),

			    %% Start video transcoding
			    ObjExt = filename:extension(light_ets:to_lower(ObjectKey0)),
			    IsVideo = lists:member(ObjExt, ?VIDEO_EXTENSIONS),
			    case IsVideo of
				true -> video_transcoding:ffmpeg(BucketId, ObjectKey0);
				false -> ok
			    end,
			    upload_response(Req0, OrigName0, IsLocked0, LockModifiedTime0,
					    LockedUserId0, LockedUserName0, LockedUserTel0,
					    RespCode, State0)
		    end;
		{error, Reason1} ->
		    lager:error("[upload_handler] Can't put object ~p/~p/~p: ~p",
				[BucketId, Prefix, ObjectKey0, Reason1]),
		    js_handler:incorrect_configuration(Req0, 5)
	    end
    end.

%%
%% Deletes previous version of object for the same date,
%% if ther'a no links on previous version ( this is the case when .stop file exists )
%%
delete_previous_one(BucketId, GUID, UploadId, Version) ->
    %% Remove Upload id from local index. Even if ther's a link to that upload,
    %% created by copy operation, it remains accessible. We need to provide user
    %% with an expectable version history: one version of file per day, in order to
    %% exclude meaningless versions from history, that we show to user.
    RemovedUploadId = indexing:remove_previous_version(BucketId, GUID, UploadId, Version),
    case RemovedUploadId of
	undefined -> ok;  %% No previous upload was found
	_ ->
	    %% Check whether we can remove an old upload
	    PrefixedGUID = utils:prefixed_object_key(?RIAK_REAL_OBJECT_PREFIX, GUID),
	    StopObjectName = RemovedUploadId ++ ?STOP_OBJECT_SUFFIX,
	    PrefixedStopSignName = utils:prefixed_object_key(PrefixedGUID, StopObjectName),
	    case riak_api:head_object(BucketId, PrefixedStopSignName) of
		{error, Reason} ->
		    lager:error("[upload_handler] head_object failed ~p/~p: ~p",
				[BucketId, PrefixedStopSignName, Reason]),
		    ok;
		not_found ->
		    %% Delete previous upload for the same day
		    MaxKeys = ?FILE_MAXIMUM_SIZE div ?FILE_UPLOAD_CHUNK_SIZE,
		    PrefixedUploadId = utils:prefixed_object_key(PrefixedGUID, RemovedUploadId) ++ "/",
		    RiakResponse0 = riak_api:list_objects(BucketId, [{prefix, PrefixedUploadId}, {max_keys, MaxKeys}]),
		    List0 = [proplists:get_value(key, I) || I <- proplists:get_value(contents, RiakResponse0)],
		    lager:warning("Removing ~p~n", [PrefixedUploadId]),
		    [riak_api:delete_object(BucketId, I) || I <- List0];
		    %% Now delete thumbnails, if ther'a any
		    %% TODO
		_ -> ok
	    end
    end.

%%
%% Checks if provided token is correct.
%% ( called after 'allowed_methods()' )
%%
is_authorized(Req0, _State) ->
    case utils:get_token(Req0) of
	undefined -> js_handler:unauthorized(Req0, 28);
	Token -> login_handler:get_user_or_error(Req0, Token)
    end.

%%
%% Checks the following.
%% - User has access
%% - Bucket ID is correct
%% - Prefix is correct
%% - Part number is correct
%% - content-range request header is specified
%% - file size do not exceed the limit
%%
%% ( called after 'allowed_methods()' )
%%
forbidden(Req0, User) ->
    BucketId =
	case cowboy_req:binding(bucket_id, Req0) of
	    undefined -> undefined;
	    BV -> erlang:binary_to_list(BV)
	end,
    case utils:is_valid_bucket_id(BucketId, User#user.tenant_id) of
	true ->
	    IsRestricted = utils:is_restricted_bucket_id(BucketId),
	    IsPublic = utils:is_public_bucket_id(BucketId),
	    UserBelongsToGroup =
		case IsRestricted orelse IsPublic of
		    true -> User#user.staff;  %% only staff user can upload to the public bucket
		    false -> lists:any(fun(Group) ->
				utils:is_bucket_belongs_to_group(BucketId, User#user.tenant_id, Group#group.id) end,
				User#user.groups)
		end,
	    case UserBelongsToGroup of
		false ->
		    PUser = admin_users_handler:user_to_proplist(User),
		    js_handler:forbidden(Req0, 37, proplists:get_value(groups, PUser), stop);
		true ->
		    case validate_content_range(Req0) of
			{error, Reason} -> js_handler:forbidden(Req0, Reason, stop);
			State1 -> {false, Req0, State1++[{user, User}, {bucket_id, BucketId}]}
		    end
	    end;
	false -> js_handler:forbidden(Req0, 7, stop)
    end.

%%
%% Check if file size do not exceed the limit
%% ( called after 'content_types_provided()' )
%%
resource_exists(Req0, State) ->
    PartNumber = proplists:get_value(part_number, State),
    MaximumPartNumber = (?FILE_MAXIMUM_SIZE div ?FILE_UPLOAD_CHUNK_SIZE),
    case PartNumber < MaximumPartNumber andalso PartNumber >= 1 of
	true -> {true, Req0, State};
	false -> {false, Req0, []}
    end.

previously_existed(Req0, State) ->
    {false, Req0, State}.

allow_missing_post(Req0, State) ->
    {false, Req0, State}.
