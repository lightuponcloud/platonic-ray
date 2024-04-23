-module(riak_api).

-export([list_buckets/0, create_bucket/1, create_bucket/2, delete_bucket/1, head_bucket/1,
	 list_objects/1, list_objects/2, get_object/2, get_object/3, delete_object/2, head_object/2,
	 put_object/4, put_object/5, copy_object/4, copy_object/5,
	 get_object_metadata/2, get_object_metadata/3,
	 start_multipart/2, start_multipart/4,
	 upload_part/5,
	 complete_multipart/4,
	 abort_multipart/3,
	 get_object_url/2,
	 s3_xml_request/8,
	 validate_upload_id/3,
	 increment_filename/1,
	 pick_object_key/6,
	 s3_request/8,
	 request_httpc/6,
	 recursively_list_pseudo_dir/2,
	 mark_filename_conflict/2
        ]).

-include("riak.hrl").
-include("general.hrl").
-include("entities.hrl").
-include_lib("xmerl/include/xmerl.hrl").

-type s3_bucket_acl() :: private
                       | public_read
                       | public_read_write
                       | authenticated_read
                       | bucket_owner_read
                       | bucket_owner_full_control.

-define(XMLNS_S3, "http://s3.amazonaws.com/doc/2006-03-01/").
-define(LIST_OBJECTS_MAX_KEYS, 10000).
-define(DEFAULT_TIMEOUT, 10000).

-spec copy_object(DestBucketId, DestKeyName, SrcBucketId, SrcKeyName) -> proplist() when
    DestBucketId :: string(),
    DestKeyName :: string(),
    SrcBucketId :: string(),
    SrcKeyName :: string().

copy_object(DestBucketId, DestKeyName, SrcBucketId, SrcKeyName) ->
    copy_object(DestBucketId, DestKeyName, SrcBucketId, SrcKeyName, []).

-spec copy_object(DestBucketId, DestKeyName, SrcBucketId, SrcKeyName, Options) -> proplist() when
    DestBucketId :: string(),
    DestKeyName :: string(),
    SrcBucketId :: string(),
    SrcKeyName :: string(),
    Options :: proplist().

copy_object(DestBucketId, DestKeyName, SrcBucketId, SrcKeyName, Options) ->
    SrcVersion =
	case proplists:get_value(version_id, Options) of
            undefined -> "";
            VersionID -> ["?versionId=", VersionID]
        end,
    RequestHeaders =
        [{"x-amz-copy-source", [SrcBucketId, $/, SrcKeyName, SrcVersion]},
         {"x-amz-metadata-directive", proplists:get_value(metadata_directive, Options)},
         {"x-amz-copy-source-if-match", proplists:get_value(if_match, Options)},
         {"x-amz-copy-source-if-none-match", proplists:get_value(if_none_match, Options)},
         {"x-amz-copy-source-if-unmodified-since", proplists:get_value(if_unmodified_since, Options)},
         {"x-amz-copy-source-if-modified-since", proplists:get_value(if_modified_since, Options)},
         {"x-amz-acl", encode_acl(proplists:get_value(acl, Options))}],
    Config = #riak_api_config{timeout=480000},  % 480000 == 8 minutes
    case s3_request(put, DestBucketId, [$/|DestKeyName], "", [], <<>>, RequestHeaders, Config) of
	{ok, {_Status, Headers, _Body}} ->
	    [{content_length, proplists:get_value("content-length", Headers, "0")}];
	{error, {Reason,_,_,_,_}} -> {error, Reason}
    end.


-spec list_buckets() -> proplist().

list_buckets() ->
    Options = [],
    Params = [{"delimiter", proplists:get_value(delimiter, Options, "/")},
              {"marker", proplists:get_value(marker, Options)},
              {"max-keys", proplists:get_value(max_keys, Options, ?LIST_OBJECTS_MAX_KEYS)},
              {"prefix", proplists:get_value(prefix, Options)}],
    Config = #riak_api_config{},
    case s3_xml_request(get, "", "/", "", Params, <<>>, [], Config) of
	{ok, Doc} ->
	    Attributes = [{prefix, "Bucket", text},
                  {marker, "Marker", text},
                  {next_marker, "NextMarker", text},
                  {delimiter, "Delimiter", text},
                  {max_keys, "MaxKeys", integer},
                  {is_truncated, "IsTruncated", boolean},
                  {contents, "Contents", fun extract_contents/1}],
	    erlcloud_xml:decode(Attributes, Doc);
	not_found -> not_found
    end.

-spec create_bucket(string()) -> ok.

create_bucket(BucketId) ->
    create_bucket(BucketId, private).

-spec create_bucket(string(), s3_bucket_acl()) -> ok.

create_bucket(BucketId0, ACL) when erlang:is_list(BucketId0), erlang:is_atom(ACL) ->
    Headers = case ACL of
                  private -> [];  %% private is the default
                  _       -> [{"x-amz-acl", encode_acl(ACL)}]
              end,
    POSTData = <<>>,
    BucketId1 = string:to_lower(BucketId0),
    s3_simple_request(put, BucketId1, "/", "", [], POSTData, Headers).

encode_acl(undefined)                 -> undefined;
encode_acl(private)                   -> "private";
encode_acl(public_read)               -> "public-read";
encode_acl(public_read_write)         -> "public-read-write";
encode_acl(authenticated_read)        -> "authenticated-read";
encode_acl(bucket_owner_read)         -> "bucket-owner-read";
encode_acl(bucket_owner_full_control) -> "bucket-owner-full-control".

-spec delete_bucket(string()) -> ok.

delete_bucket(BucketId) ->
    s3_simple_request(delete, BucketId, "/", "", [], <<>>, []).

-spec delete_object(string(), string()) -> proplist().

delete_object(BucketId, Key) when erlang:is_list(BucketId), erlang:is_list(Key) ->
    Config = #riak_api_config{},
    case s3_request(delete, BucketId, [$/|Key], "", [], <<>>, [], Config) of
	{error, {Reason,_,_,_,_}} -> {error, Reason};
	{ok, {_Status, Headers, _Body}} ->
	    Marker = proplists:get_value("x-amz-delete-marker", Headers, "false"),
	    Id = proplists:get_value("x-amz-version-id", Headers, "null"),
	    {ok, [{delete_marker, list_to_existing_atom(Marker)}, {version_id, Id}]}
    end.


-spec list_objects(string()) -> proplist().

list_objects(BucketId) ->
    list_objects(BucketId, []).

-spec list_objects(string(), proplist()) -> proplist().

list_objects(BucketId, Options) when erlang:is_list(BucketId), erlang:is_list(Options) ->
    Params = [{"delimiter", proplists:get_value(delimiter, Options, "/")},
              {"marker", proplists:get_value(marker, Options)},
              {"max-keys", proplists:get_value(max_keys, Options, ?LIST_OBJECTS_MAX_KEYS)},
              {"prefix", proplists:get_value(prefix, Options)}],
    Config = #riak_api_config{},
    case s3_xml_request(get, BucketId, "/", "", Params, <<>>, [], Config) of
	{ok, Doc} ->
	    Attributes = [{name, "Name", text},
                  {prefix, "Prefix", text},
                  {marker, "Marker", text},
                  {next_marker, "NextMarker", text},
                  {delimiter, "Delimiter", text},
                  {max_keys, "MaxKeys", integer},
                  {is_truncated, "IsTruncated", boolean},
                  {common_prefixes, "CommonPrefixes", fun extract_prefixes/1},
                  {contents, "Contents", fun extract_contents/1}],
	    erlcloud_xml:decode(Attributes, Doc);
	not_found -> not_found
    end.

-spec recursively_list_pseudo_dir(string(), string()) -> list().

recursively_list_pseudo_dir(BucketId, Prefix) ->
    RiakResponse = list_objects(BucketId, [{prefix, Prefix}]),
    Contents = [proplists:get_value(key, I) || I <- proplists:get_value(contents, RiakResponse)],
    Dirs = [proplists:get_value(prefix, I) || I <- proplists:get_value(common_prefixes, RiakResponse)],
    lists:foldl(fun(X, Acc) -> X ++ Acc end, Contents, [recursively_list_pseudo_dir(BucketId, P) || P <- Dirs]).

extract_prefixes(Nodes) ->
    Attributes = [{prefix, "Prefix", text}],
    [erlcloud_xml:decode(Attributes, Node) || Node <- Nodes].

extract_contents(Nodes) ->
    Attributes = [{key, "Key", text},
                  {last_modified, "LastModified", time},
                  {etag, "ETag", text},
                  {size, "Size", integer},
                  {storage_class, "StorageClass", text},
                  {owner, "Owner", fun extract_user/1}],
    [erlcloud_xml:decode(Attributes, Node) || Node <- Nodes].

extract_user([]) ->
    [];
extract_user([Node]) ->
    Attributes = [{id, "ID", optional_text},
                  {display_name, "DisplayName", optional_text},
                  {uri, "URI", optional_text}
                 ],
    erlcloud_xml:decode(Attributes, Node).

%%
%% head_bucket function is used to check if bucket exists
%%
-spec head_bucket(string()) -> proplist() | not_found.

head_bucket(BucketId) when erlang:is_list(BucketId) ->
    Config = #riak_api_config{},
    case s3_xml_request(get, BucketId, "/", "acl", [], <<>>, [], Config) of
	{ok, Doc} ->
	    Attributes = [{owner, "Owner", fun extract_user/1}],
	    erlcloud_xml:decode(Attributes, Doc);
	not_found -> not_found
    end.

-spec head_object(string(), string()) -> proplist()|not_found.

head_object(BucketId, Key) when erlang:is_list(BucketId), erlang:is_list(Key) ->
    fetch_object(head, BucketId, Key, []).

-spec get_object(string(), string()) -> proplist().

get_object(BucketId, Key) when erlang:is_list(BucketId), erlang:is_list(Key) ->
    fetch_object(get, BucketId, Key, []).

%%
%% Download object by chunks, sending them to PID
%%
-spec get_object(string(), string(), atom()|list()) -> proplist().

get_object(BucketId, Key, stream)
	when erlang:is_list(BucketId), erlang:is_list(Key) ->
    fetch_object(get, BucketId, Key, [{stream, true}]);

%%
%% Download object by chunks, returning a big binary blob.
%%
get_object(BucketId, GUID, UploadId)
	when erlang:is_list(BucketId), erlang:is_list(GUID), erlang:is_list(UploadId) ->
    RealPrefix0 = utils:prefixed_object_key(?RIAK_REAL_OBJECT_PREFIX, GUID),
    RealPrefix1 = utils:prefixed_object_key(RealPrefix0, UploadId) ++ "/",
    MaxKeys = ?FILE_MAXIMUM_SIZE div ?FILE_UPLOAD_CHUNK_SIZE,
    case list_objects(BucketId, [{max_keys, MaxKeys}, {prefix, RealPrefix1}]) of
	not_found -> not_found;  %% bucket not found
	RiakResponse0 ->
	    Contents = proplists:get_value(contents, RiakResponse0),
	    erlang:iolist_to_binary(lists:map(
		fun(Meta) ->
		    Key = proplists:get_value(key, Meta),
		    Response = fetch_object(get, BucketId, Key, []),
		    proplists:get_value(content, Response)
		end, Contents))
    end.

-spec fetch_object(MethodName, BucketId, Key, Options) -> proplist()|not_found when
    MethodName :: atom(),
    BucketId :: string(),
    Key :: string(),
    Options :: proplist().

fetch_object(MethodName, BucketId, Key, Options0)
	when erlang:is_atom(MethodName), erlang:is_list(BucketId), erlang:is_list(Key) ->
    RequestHeaders = [{"Range", proplists:get_value(range, Options0)},
                      {"If-Modified-Since", proplists:get_value(if_modified_since, Options0)},
                      {"If-Unmodified-Since", proplists:get_value(if_unmodified_since, Options0)},
                      {"If-Match", proplists:get_value(if_match, Options0)},
                      {"If-None-Match", proplists:get_value(if_none_match, Options0)},
                      {"x-amz-server-side-encryption-customer-algorithm",
		       proplists:get_value(server_side_encryption_customer_algorithm, Options0)},
                      {"x-amz-server-side-encryption-customer-key",
		       proplists:get_value(server_side_encryption_customer_key, Options0)},
                      {"x-amz-server-side-encryption-customer-key-md5",
		       proplists:get_value(server_side_encryption_customer_key_md5, Options0)}],
    Subresource = case proplists:get_value(version_id, Options0) of
                      undefined -> "";
                      Version   -> ["versionId=", Version]
                  end,
    Config = #riak_api_config{},
    Response =
	case proplists:get_value(stream, Options0) of
	    undefined ->
		s3_request(MethodName, BucketId, [$/|Key], Subresource, [], <<>>, RequestHeaders, Config);
	    true ->
		Options1 = [{socket_opts, [{recbuf, 16#FFFFFF}, {sndbuf, 16#1FFFFFF}, {active, once}]},
			    {body_format, binary},
			    {sync, false},
			    {stream, {self, once}}],
		s3_request(MethodName, BucketId, [$/|Key], Subresource, [], <<>>, RequestHeaders, Config, Options1)
	end,
    case Response of
	{ok, {_Status, Headers, Body}} ->
	    [{last_modified, proplists:get_value("last-modified", Headers)},
	     {etag, proplists:get_value("etag", Headers)},
	     {content_length, proplists:get_value("content-length", Headers)},
	     {content_type, proplists:get_value("content-type", Headers)},
	     {content_encoding, proplists:get_value("content-encoding", Headers)},
	     {delete_marker, list_to_existing_atom(proplists:get_value("x-amz-delete-marker", Headers, "false"))},
	     {content, Body},
	     {version_id, proplists:get_value("x-amz-version-id", Headers, "null")}|extract_metadata(Headers)
	    ];
	{ok, RequestId} -> {ok, RequestId};
	{error, _} -> not_found
    end.

%%
%% Returns filename-N, where N is added integer number
%%
-spec increment_filename(binary()) -> binary().

increment_filename(FileName) when erlang:is_binary(FileName) ->
    {RootName, Extension} = {filename:rootname(FileName), filename:extension(FileName)},

    case binary:matches(RootName, <<"-">>) of
	[] -> << RootName/binary,  <<"-1">>/binary, Extension/binary >>;
	HyphenPositions ->
	    {LastHyphenPos, _} = lists:last(HyphenPositions),
	    V = binary:part(RootName, size(RootName), -(size(RootName)-LastHyphenPos-1)),
	    try erlang:binary_to_integer(V) of
		N ->
		    NamePart = binary:part(RootName, 0, LastHyphenPos+1),
		    IncrementedValue = integer_to_binary(N+1),
		    << NamePart/binary, IncrementedValue/binary, Extension/binary >>
	    catch error:badarg ->
		<< RootName/binary,  <<"-1">>/binary, Extension/binary >>
	    end
    end.

increment_conflict_filename(G, UserName, Date) ->
    Bit0 = lists:nth(1, G),
    case binary:matches(Bit0, <<", conflicted copy">>) of
	[] -> lists:foldr(fun (F, S) -> <<F/binary, S/binary>> end, <<>>, G);
	Pos0 ->
	    {LastPos, Length} = lists:last(Pos0),
	    Bit1 = binary:part(Bit0, LastPos+Length, size(Bit0)-(LastPos+Length)),
	    case binary:matches(Bit1, <<" ">>) of
		[] -> << UserName/binary,
			 <<", conflicted copy-1 ">>/binary, Date/binary, <<")">>/binary >>;
		Pos1 ->
		    {SpacePos, _} = lists:nth(1, Pos1),
		    V = binary:part(Bit1, 1, SpacePos-1),
		    try erlang:binary_to_integer(V) of
			N ->
			    IncrementedValue = erlang:integer_to_binary(N+1),
			    << UserName/binary,
			       <<", conflicted copy-">>/binary, IncrementedValue/binary,
			       <<" ">>/binary, Date/binary, <<")">>/binary >>
		    catch error:badarg ->
			<< UserName/binary,
			   <<", conflicted copy-1 ">>/binary, Date/binary, <<")">>/binary >>
		    end
	    end
    end.

%%
%% Renames filename, by adding "conflicted copy", username and timestamp to the file name.
%%
-spec mark_filename_conflict(binary(), binary()) -> binary().

mark_filename_conflict(FileName, UserName) when erlang:is_binary(FileName), erlang:is_binary(UserName) ->
    {RootName0, Extension} = {filename:rootname(FileName), filename:extension(FileName)},
    Date = erlang:list_to_binary(utils:format_timestamp(utils:to_integer(erlang:round(utils:timestamp()/1000)))),
    ConflictName = << RootName0/binary, <<" (">>/binary, UserName/binary, <<", conflicted copy ">>/binary,
		      Date/binary, <<")">>/binary, Extension/binary >>,
    %% Check if file name is marked as confliect for user and date
    case binary:matches(RootName0, ConflictName) of
	[] ->
	    case binary:matches(RootName0, <<", conflicted copy">>) of
		[] -> ConflictName; %% no "conflicted copy" string found. Safe to add it
		_ ->
		    %% split filename by round brackets and try to find "conflicted copy" inside
		    Groups = re:split(RootName0, <<"([\(\)])">>,[{return,binary},group]),
		    RootName1 = [increment_conflict_filename(G, UserName, Date) || G <- Groups],
		    lists:foldr(fun (F, S) -> <<F/binary, S/binary>> end, <<>>, RootName1++[Extension])
	    end;
	_ -> ConflictName  %% the name contains "conflicted copy" text already
    end.

%%
%% Checks if version of existing object is older than new version.
%%
is_new_version(undefined, _NewVersion) -> true;
is_new_version(_OldVersion, undefined) -> false;
is_new_version(OldVersion, NewVersion) ->
    %% Sync discards outdated values, while merging all causal histories,
    %% before check for conflict ( split history scenario ).
    MergedHistory = dvvset:sync([OldVersion, NewVersion]),
    case dvvset:values(MergedHistory) of
	[_] ->
	    %% Casual history is linear
	    dvvset:less(OldVersion, NewVersion);
	_ -> conflict  %% multiple branches of history
    end.

%%
%% Returns unique object name for provided bucket/prefix/object name.
%% It takes into account existing pseudo-directory names.
%%
%% 1. It slugifies name of object and checks
%%    if object with that name exists in storage.
%%
%% 3. If object do not exist, it checks if pseudo-directory
%%    with that name exists. In case pseudo-directory exists
%%    it RENAMES object, -- adds -N, where N is incremented integer.
%%
%%    If object exists, it compares version of existing
%%    object with a new one. If an existing object is older than
%%    a new one, returns unchanged name, so upload function rewrites
%%    old object with contents of the new one.
%%
%% Returns the following tuple.
%%	{
%%	    unique object key,
%%	    unique original name,
%%	    whether new object is a previous version flag
%%	}
%%
-spec pick_object_key(BucketId, Prefix, FileName, Version, UserName, IndexContent) ->
	{string(), binary(), boolean()} when
    BucketId :: string(),
    Prefix :: string(),
    FileName :: binary(),
    Version :: term()|undefined,
    UserName :: binary(),
    IndexContent :: proplist().

pick_object_key(BucketId, Prefix, FileName, Version, UserName, IndexContent)
    when erlang:is_list(BucketId), erlang:is_list(Prefix) orelse Prefix =:= undefined,
	 erlang:is_binary(FileName), erlang:is_list(Version) orelse Version =:= undefined,
	 erlang:is_binary(UserName) ->
    %% Lowercase directory names, used for comparision
    ExistingDirectoryNames = lists:map(
	fun(P0) ->
	    P1 = proplists:get_value(prefix, P0),
	    P2 = lists:last([T || T <- binary:split(P1, <<"/">>, [global]), erlang:byte_size(T) > 0]),
	    P3 = unicode:characters_to_list(utils:unhex(P2)),
	    light_unicode:to_lower(P3)
	end, proplists:get_value(dirs, IndexContent, [])),
    ExistingList = proplists:get_value(list, IndexContent, []),
    %% Lowercase original object names, used for comparison
    ExistingObjects = [
	begin
	    OrigName1 = proplists:get_value(orig_name, I),
	    OrigName2 = unicode:characters_to_list(OrigName1),
	    Object = indexing:to_object(I),
	    {light_unicode:to_lower(OrigName2), Object}
	end || I <- ExistingList,
	proplists:get_value(is_deleted, I) =:= false],
    pick_object_key(BucketId, Prefix, FileName, Version, UserName, ExistingDirectoryNames,
		    ExistingObjects, undefined, undefined, true).

pick_object_key(BucketId, Prefix, FileName0, Version, UserName, ExistingDirectoryNames,
		ExistingObjects, UniqKey0, UniqOrigName0, IsNewVersion0)
    when erlang:is_list(BucketId), erlang:is_list(Prefix) orelse Prefix =:= undefined,
	 erlang:is_binary(FileName0), erlang:is_list(Version) orelse Version =:= undefined,
	 erlang:is_binary(UserName), erlang:is_list(ExistingDirectoryNames),
	 erlang:is_list(ExistingObjects), erlang:is_boolean(IsNewVersion0),
	 erlang:is_list(UniqKey0) orelse UniqKey0 =:= undefined,
	 erlang:is_binary(UniqOrigName0) orelse UniqOrigName0 =:= undefined ->
    NewName0 =
	case UniqOrigName0 of
	    undefined -> FileName0;
	    _ -> UniqOrigName0
	end,
    NewName1 = light_unicode:to_lower(unicode:characters_to_list(NewName0)),  %% lowercase
    %% Transliterate filename
    ObjectKey0 =
	case UniqKey0 of
	    undefined ->
		case utils:slugify_object_key(NewName0) of
		    [] -> utils:hex(NewName0);
		    "." -> utils:hex(NewName0);
		    ".." -> utils:hex(NewName0);
		    Slug -> Slug
		end;
	    _ -> UniqKey0
	end,
    %% Check if object with such key OR name exists.
    ExistingObjectRecord = utils:firstmatch(ExistingObjects,
	fun(ExistingOne) ->
	    Object = element(2, ExistingOne),
	    NewName2 = element(1, ExistingOne),
	    Object#object.key =:= ObjectKey0 orelse NewName2 =:= NewName1
	end),
    case ExistingObjectRecord of
	[] ->
	    %% Check if pseudo-directory with this name exists.
	    %% Increment filename in that case
	    DirectoryName = light_unicode:to_lower(unicode:characters_to_list(NewName0)),
	    case lists:member(DirectoryName, ExistingDirectoryNames) of
		true ->
		    %% Directory exists, new object name required
		    pick_object_key(BucketId, Prefix, FileName0, Version, UserName,
				    ExistingDirectoryNames, ExistingObjects,
				    erlang:binary_to_list(increment_filename(erlang:list_to_binary(ObjectKey0))),
				    increment_filename(NewName0), IsNewVersion0);
		false -> {ObjectKey0, NewName0, IsNewVersion0, undefined, false}
	    end;
	{ObjectName, Object} ->
	    case ObjectName =:= NewName1 of
		false ->
		    %% Increment key only, as it could be a different object.
		    %% Slug ( key ) is not a reliable encoding method, it has collisions.
		    pick_object_key(BucketId, Prefix, FileName0, Version, UserName,
				    ExistingDirectoryNames, ExistingObjects,
				    erlang:binary_to_list(increment_filename(erlang:list_to_binary(ObjectKey0))),
				    NewName0, IsNewVersion0);
		true ->
		    %% Most probably the same object
		    IsNewVersion1 = is_new_version(Object#object.version, Version),
		    case Version of
			undefined ->
			    %% Let caller (rename or copy function) to decide what to do next
			    {ObjectKey0, NewName0, IsNewVersion1, Object, false};
			_ ->
			    %% If stored object is older, it should be replaced with a newer version.
			    %% But in case client have used previous version of object before he started
			    %% editing, it should be marked as such that have conflict.
			    case IsNewVersion1 of
				false ->
				    %% Client could have edited file offline, based on old version
				    ConflictName = mark_filename_conflict(FileName0, UserName),
				    ConflictKey = utils:slugify_object_key(ConflictName),
				    {ConflictKey, ConflictName, false, Object, true};
				true ->
				    %% A modified version of file has arrived.
				    {ObjectKey0, NewName0, true, Object, false};
				conflict ->
				    %% Split history has been detected
				    {ObjectKey0, NewName0, false, Object, true}
			    end
		    end
	    end
    end.

-spec get_object_metadata(string(), string()) -> proplist().

get_object_metadata(BucketId, Key) ->
    get_object_metadata(BucketId, Key, []).

-spec get_object_metadata(BucketId, Key, Options) -> proplist() when
    BucketId :: string(),
    Key :: string(),
    Options :: proplist().

get_object_metadata(BucketId, Key, Options)
	when erlang:is_list(BucketId), erlang:is_list(Key), erlang:is_list(Options) ->
    RequestHeaders = [{"If-Modified-Since", proplists:get_value(if_modified_since, Options)},
                      {"If-Unmodified-Since", proplists:get_value(if_unmodified_since, Options)},
                      {"If-Match", proplists:get_value(if_match, Options)},
                      {"If-None-Match", proplists:get_value(if_none_match, Options)}],
    Subresource =
	case proplists:get_value(version_id, Options) of
	    undefined -> "";
	    Version   -> ["versionId=", Version]
        end,
    Config = #riak_api_config{},
    case s3_request(head, BucketId, [$/|Key], Subresource, [], <<>>, RequestHeaders, Config) of
	{error, _} -> [];
	{ok, {_Status, Headers, _Body}} ->
	    [{last_modified, proplists:get_value("last-modified", Headers)},
	     {etag, proplists:get_value("etag", Headers)},
	     {content_length, proplists:get_value("content-length", Headers)},
	     {content_type, proplists:get_value("content-type", Headers)},
	     {content_encoding, proplists:get_value("content-encoding", Headers)},
	     {delete_marker, list_to_existing_atom(proplists:get_value("x-amz-delete-marker", Headers, "false"))},
	     {version_id, proplists:get_value("x-amz-version-id", Headers, "false")}|extract_metadata(Headers)]
    end.


extract_metadata(Headers) ->
    [{Key, Value} || {Key = "x-amz-meta-" ++ _, Value} <- Headers].

%%
%% put_object function should be used for uploading small objects
%%
-spec put_object(BucketId, Prefix, ObjectKey, BinaryData) -> string() when
    BucketId :: string(),
    Prefix :: string(),
    ObjectKey :: string(),
    BinaryData :: binary().

put_object(BucketId, Prefix, ObjectKey, BinaryData)
	when erlang:is_list(BucketId),
	     erlang:is_list(Prefix) orelse Prefix =:= undefined,
	     erlang:is_list(ObjectKey), erlang:is_binary(BinaryData) ->
    Options = [{acl, public_read}],
    put_object(BucketId, Prefix, ObjectKey, BinaryData, Options).

-spec put_object(BucketId, Prefix, ObjectKey, BinaryData, Options) -> string() when
    BucketId :: string(),
    Prefix :: string(),
    ObjectKey :: string(),
    BinaryData :: binary(),
    Options :: proplist().

put_object(BucketId, Prefix, ObjectKey, BinaryData, Options)
	when erlang:is_list(BucketId),
	     erlang:is_list(Prefix) orelse Prefix =:= undefined,
	     erlang:is_list(ObjectKey), erlang:is_binary(BinaryData),
	     erlang:is_list(Options) ->
    PrefixedObjectKey = utils:prefixed_object_key(Prefix, ObjectKey),
    %% No need to guess mime type for service objects
    MimeType =
	case ObjectKey of
	    ?DB_VERSION_KEY -> "application/vnd.sqlite3";
	    ?DB_VERSION_LOCK_FILENAME -> "application/vnd.lightup";
	    ?WATERMARK_OBJECT_KEY -> "image/png";
	    ?RIAK_ACTION_LOG_FILENAME -> "application/xml";
	    ?RIAK_LOCK_DVV_INDEX_FILENAME -> "application/vnd.lightup";
	    ?RIAK_DVV_INDEX_FILENAME -> "application/vnd.lightup";
	    ?RIAK_LOCK_INDEX_FILENAME -> "application/vnd.lightup";
	    ?RIAK_INDEX_FILENAME -> "application/vnd.lightup";
	    _ -> utils:mime_type(ObjectKey)
	end,
    HTTPHeaders = [{"content-type", MimeType}],

    RequestHeaders = [{"x-amz-acl", encode_acl(proplists:get_value(acl, Options))}|HTTPHeaders]
        ++ [{"x-amz-meta-" ++ string:to_lower(MKey), MValue} ||
               {MKey, MValue} <- proplists:get_value(meta, Options, [])],
    Config = #riak_api_config{},
    Response = s3_request(put, BucketId, [$/|PrefixedObjectKey], "", [], BinaryData, RequestHeaders, Config),
    case Response of
	{ok, {_Status, _Headers, _Body}} -> ok;
	{error, Reason} ->
	    lager:error("[riak_api] Failed to put object ~p/~p/~p: ~p",
			[BucketId, Prefix, ObjectKey, Reason]),
	    {error, Reason}
    end.

-spec get_object_url(string(), string()) -> string().

get_object_url(BucketId, Key) ->
    Config = #riak_api_config{},
    lists:flatten([Config#riak_api_config.s3_scheme, BucketId, ".", Config#riak_api_config.s3_host, port_spec(Config), "/", Key]).

-spec start_multipart(BucketId, Key) -> {ok, proplist()} | {error, any()} when
    BucketId :: string(),
    Key :: string().

start_multipart(BucketId, Key) when erlang:is_list(BucketId), erlang:is_list(Key) ->
    start_multipart(BucketId, Key, [], []).

-spec start_multipart(BucketId, Key, Options, HTTPHeaders) -> {ok, proplist()} | {error, any()} when
    BucketId :: string(),
    Key :: string(),
    Options :: proplist(),
    HTTPHeaders :: [{string(), string()}].

start_multipart(BucketId, Key, Options, HTTPHeaders)
	when erlang:is_list(BucketId), erlang:is_list(Key),
	     erlang:is_list(Options), erlang:is_list(HTTPHeaders) ->
    RequestHeaders = [{"x-amz-acl", encode_acl(proplists:get_value(acl, Options))}|HTTPHeaders]
        ++ [{"x-amz-meta-" ++ string:to_lower(MKey), MValue} ||
               {MKey, MValue} <- proplists:get_value(meta, Options, [])],
    POSTData = <<>>,
    Config = #riak_api_config{},
    case s3_xml_request2(post, BucketId, [$/|Key], "uploads", [], POSTData, RequestHeaders, Config) of
        {ok, Doc} ->
            Attributes = [{uploadId, "UploadId", text}],
            {ok, erlcloud_xml:decode(Attributes, Doc)};
        Error -> Error
    end.

%%
%% Queries Riak CS on a subject of provided upload id.
%%
-spec validate_upload_id(BucketId, ObjectKey0, UploadId0) -> {ok, proplist()} | not_found | {error, any()} when
    BucketId :: string(),
    ObjectKey0 :: string(),
    UploadId0 :: string().

validate_upload_id(BucketId, ObjectKey0, UploadId0)
	when erlang:is_list(BucketId), erlang:is_list(ObjectKey0),
	     erlang:is_list(UploadId0) ->
    Config = #riak_api_config{},
    case s3_xml_request2(get, BucketId, [$/|ObjectKey0], [], [{"uploadId", UploadId0}], <<>>, [], Config) of
        {ok, Doc} ->
            Attributes = [{uploadId, "UploadId", text}],
            [{uploadId, UploadId1}] = erlcloud_xml:decode(Attributes, Doc),
	    case UploadId1 =:= UploadId0 of
		true -> ok;
		false -> not_found
	    end;
	{error, {http_error,_,_,_,_}} -> not_found;
	{error, Reason} -> {error, Reason}
    end.

-spec upload_part(BucketId, Key, UploadId, PartNumber, Value) -> {ok, proplist()} | {error, any()} when
    BucketId :: string(),
    Key :: string(),
    UploadId :: string(),
    PartNumber :: integer(),
    Value :: iodata().

upload_part(BucketId, Key, UploadId, PartNumber, Value) ->
    upload_part(BucketId, Key, UploadId, PartNumber, Value, []).

-spec upload_part(BucketId, Key, UploadId, PartNumber, Value, HTTPHeaders) -> {ok, proplist()} | {error, any()} when
    BucketId :: string(),
    Key :: string(),
    UploadId :: string(),
    PartNumber :: integer(),
    Value :: iodata(),
    HTTPHeaders :: [{string(), string()}].

upload_part(BucketId, Key, UploadId, PartNumber, Value, HTTPHeaders)
  when erlang:is_list(BucketId), erlang:is_list(Key), erlang:is_list(UploadId),
       erlang:is_integer(PartNumber), erlang:is_binary(Value), erlang:is_list(HTTPHeaders) ->
    POSTData = erlang:iolist_to_binary(Value),
    Config = #riak_api_config{},
    case s3_request(put, BucketId, [$/|Key], [], [{"uploadId", UploadId},
                    {"partNumber", integer_to_list(PartNumber)}],
                    POSTData, HTTPHeaders, Config) of
        {ok, {_Status, Headers, _Body}} ->
            {ok, [{etag, proplists:get_value("etag", Headers)}]};
        Error -> Error
    end.

-spec complete_multipart(BucketId, Key, UploadId, ETags) -> {ok, proplist()} | {error, any()} when
    BucketId :: string(),
    Key :: string(),
    UploadId :: string(),
    ETags :: [{binary(), binary()}].

complete_multipart(BucketId, Key, UploadId, ETags)
	when erlang:is_list(BucketId), erlang:is_list(Key), erlang:is_list(UploadId), erlang:is_list(ETags) ->
    complete_multipart(BucketId, Key, UploadId, ETags, []).

-spec complete_multipart(BucketId, Key, UploadId, ETags, HTTPHeaders) -> {ok, proplist()} | {error, any()} when
    BucketId :: string(),
    Key :: string(),
    UploadId :: string(),
    ETags :: [{binary(), binary()}],
    HTTPHeaders :: [{string(), string()}].

complete_multipart(BucketId, Key, UploadId, ETags, HTTPHeaders)
  when erlang:is_list(BucketId), erlang:is_list(Key), erlang:is_list(UploadId),
       erlang:is_list(ETags), erlang:is_list(HTTPHeaders) ->

    POSTData = list_to_binary(xmerl:export_simple([{'CompleteMultipartUpload',
                                                    [{'Part',
                                                      [{'PartNumber', [integer_to_list(Num)]},
                                                       {'ETag', [ETag]}] } || {Num, ETag} <- ETags]}], xmerl_xml)),
    Config = #riak_api_config{},
    case s3_request(post, BucketId, [$/|Key], [], [{"uploadId", UploadId}],
                     POSTData, HTTPHeaders, Config) of
        {ok, {_Status, _Headers, _Body}} ->
            ok;
        Error -> Error
    end.

-spec abort_multipart(BucketId, Key, UploadId) -> ok | {error, any()} when
    BucketId :: string(),
    Key :: string(),
    UploadId :: string().

abort_multipart(BucketId, Key, UploadId)
	when erlang:is_list(BucketId), erlang:is_list(Key), erlang:is_list(UploadId) ->
    abort_multipart(BucketId, Key, UploadId, [], []).

-spec abort_multipart(BucketId, Key, UploadId, Options, HTTPHeaders) -> ok | {error, any()} when
    BucketId :: string(),
    Key :: string(),
    UploadId :: string(),
    Options :: proplist(),
    HTTPHeaders :: [{string(), string()}].

abort_multipart(BucketId, Key, UploadId, Options, HTTPHeaders)
	when erlang:is_list(BucketId), erlang:is_list(Key), erlang:is_list(UploadId),
	     erlang:is_list(Options), erlang:is_list(HTTPHeaders) ->
    Config = #riak_api_config{},
    case s3_request(delete, BucketId, [$/|Key], [], [{"uploadId", UploadId}],
                     <<>>, HTTPHeaders, Config) of
        {ok, _} -> ok;
        Error -> Error
    end.

s3_simple_request(Method, Host, Path, Subresource, Params, POSTData, Headers) ->
    Config = #riak_api_config{},
    case s3_request(Method, Host, Path, Subresource, Params, POSTData, Headers, Config) of
        {ok, {_Status, _Headers, <<>>}} -> ok;
        {ok, {_Status, _Headers, Body}} ->
            XML = element(1,xmerl_scan:string(binary_to_list(Body))),
            case XML of
                #xmlElement{name='Error'} ->
                    ErrCode = erlcloud_xml:get_text("/Error/Code", XML),
                    ErrMsg = erlcloud_xml:get_text("/Error/Message", XML),
                    erlang:error({s3_error, ErrCode, ErrMsg});
                _ ->
                    ok
            end
    end.

s3_xml_request(Method, Host, Path, Subresource, Params, POSTData, Headers, Config) ->
    case s3_request(Method, Host, Path, Subresource, Params, POSTData, Headers, Config) of
	{ok, {_Status, _Headers, Body}} ->
	    XML = element(1,xmerl_scan:string(binary_to_list(Body))),
	    case XML of
		#xmlElement{name='Error'} ->
		    ErrCode = erlcloud_xml:get_text("/Error/Code", XML),
		    ErrMsg = erlcloud_xml:get_text("/Error/Message", XML),
		    erlang:error({s3_error, ErrCode, ErrMsg});
		_ -> {ok, XML}
	    end;
	{error, {http_error, 404,_,_,_}} -> not_found;
	{error, {http_error, 503,_,_,_}} -> erlang:error({s3_error, failed_connect, "Connection Failed"});
	{error, {failed_connect,_}} -> erlang:error({s3_error, failed_connect, "Connection Failed"});
	{error, timeout} -> erlang:error({s3_error, timeout, "Timeout"})
    end.

-spec s3_request(Method, Bucket, Path, Subresource, Params, POSTData, Headers, Config) ->
	{ok, {proplist(), binary()}} | {atom(), {atom(), integer(), string(), binary(), proplist()}} when
    Method :: atom(),
    Bucket :: string(),
    Path :: string(),
    Subresource :: string(),
    Params :: proplist(),
    POSTData :: binary(),
    Headers :: proplist(),
    Config :: riak_api_config().

s3_request(Method, Bucket, Path, Subresource, Params, POSTData, Headers, Config) ->
    Options = [{body_format, binary}],
    s3_request(Method, Bucket, Path, Subresource, Params, POSTData, Headers, Config, Options).

s3_request(Method, Bucket, Path, Subresource, Params, POSTData, Headers, Config, Options) ->
    %% s3_request returns {ok, Body} or {error, Reason}
    ContentType = proplists:get_value("content-type", Headers, ""),
    FParams = [Param || {_, Value} = Param <- Params, Value =/= undefined],
    FHeaders = [Header || {_, Val} = Header <- Headers, Val =/= undefined],

    QueryParams = case Subresource of
        "" -> FParams;
        _ -> [{Subresource, ""} | FParams]
    end,
    S3Host = Config#riak_api_config.s3_host,
    Region = Config#riak_api_config.s3_region,
    EscapedPath = erlcloud_http:url_encode_loose(Path),
    HostName = lists:flatten(
	[case Bucket of "" -> ""; _ -> [Bucket, $.] end, S3Host]),

    RequestHeaders = riak_crypto:sign_v4(
        Method, EscapedPath,
        [{"host", HostName} | FHeaders ],
        POSTData,
        Region,
        "s3", QueryParams),

    RequestURI = lists:flatten([
        Config#riak_api_config.s3_scheme,
        HostName, port_spec(Config),
        EscapedPath,
        case Subresource of "" -> ""; _ -> [$?, Subresource] end,
        if
            FParams =:= [] -> "";
            Subresource =:= "" ->
              [$?, erlcloud_http:make_query_string(FParams, no_assignment)];
            true ->
              [$&, erlcloud_http:make_query_string(FParams, no_assignment)]
        end]),

    {RequestHeaders2, RequestBody} = case Method of
                                         M when M =:= get orelse M =:= head orelse M =:= delete ->
                                             {RequestHeaders, <<>>};
                                         _ ->
                                             Headers2 = case lists:keyfind("content-type", 1, RequestHeaders) of
                                                            false ->
                                                                [{"content-type", ContentType} | RequestHeaders];
                                                            _ ->
                                                                RequestHeaders
                                                        end,
                                             {Headers2, POSTData}
                                     end,
    request_httpc(RequestURI, Method, RequestHeaders2, RequestBody, Config, Options).


s3_xml_request2(Method, Host, Path, Subresource, Params, POSTData, Headers, Config) ->
    case s3_request(Method, Host, Path, Subresource, Params, POSTData, Headers, Config) of
        {ok, {_Status, _Headers, Body}} ->
            XML = element(1,xmerl_scan:string(binary_to_list(Body))),
            case XML of
                #xmlElement{name='Error'} ->
                    ErrCode = erlcloud_xml:get_text("/Error/Code", XML),
                    ErrMsg = erlcloud_xml:get_text("/Error/Message", XML),
                    {error, {s3_error, ErrCode, ErrMsg}};
                _ ->
                    {ok, XML}
            end;
        Error ->
            Error
    end.

port_spec(#riak_api_config{s3_port=80}) -> "";
port_spec(#riak_api_config{s3_port=Port}) -> [":", erlang:integer_to_list(Port)].

%% Guard clause protects against empty bodied requests from being
%% unable to find a matching httpc:request call.
request_httpc(URL, Method, Hdrs, <<>>, Config, Options)
    when (Method =:= options) orelse
         (Method =:= get) orelse
         (Method =:= head) orelse
         (Method =:= delete) orelse
         (Method =:= trace) ->
    HdrsStr = [{utils:to_list(K), utils:to_list(V)} || {K, V} <- Hdrs],
    Timeout =
	case proplists:is_defined(stream, Options) of
	    true -> infinity;
	    false -> get_timeout(Config)
	end,
    maybe_set_proxy(Config),
    response_httpc(httpc:request(Method, {URL, HdrsStr},
	[{timeout, Timeout}, {connect_timeout, 5000}, {version, "HTTP/1.0"}], Options));

request_httpc(URL, Method, Hdrs0, Body, Config, Options) ->
    Hdrs1 =
	case lists:keyfind("content-type", 1, Hdrs0) of
            false -> [{"content-type", "*/*"} | Hdrs0];
            _ -> Hdrs0
        end,
    Hdrs2 = [{utils:to_list(K), utils:to_list(V)} || {K, V} <- Hdrs1],
    Hdrs3 = [{"connection", "close"} | Hdrs2],

    {"content-type", ContentType} = lists:keyfind("content-type", 1, Hdrs2),
    Timeout = get_timeout(Config),
    maybe_set_proxy(Config),
    response_httpc(httpc:request(Method,
                                 {URL, Hdrs3, ContentType, Body},
                                 [{timeout, Timeout}, {connect_timeout, 5000}], Options)).

response_httpc({ok, {{_HTTPVer, Status, StatusLine}, Headers, Body}}) ->
    case Status of
	_Status when _Status >= 500
		orelse _Status =:= 400
		orelse _Status =:= 409
		orelse _Status =:= 404
		orelse _Status =:= 405 ->
	    {error, {http_error, _Status, StatusLine, Body, Headers}};
	_ ->
	    {ok, {{Status, StatusLine}, [{string:to_lower(H), V} || {H, V} <- Headers], Body}}
    end;
response_httpc({ok, PID}) -> {ok, PID};  %% In case stream was requested
response_httpc({error, _} = Error) ->
    Error.

get_timeout(#riak_api_config{timeout = undefined}) ->
    ?DEFAULT_TIMEOUT;
get_timeout(#riak_api_config{timeout = Timeout}) ->
    Timeout.

httpc_reset_proxy() ->
  httpc_manager:set_options([{proxy, {undefined, []}}], httpc:profile_name(default)).

maybe_set_proxy(Config) ->
    ProxyHost = Config#riak_api_config.s3_proxy_host,
    ProxyPort = Config#riak_api_config.s3_proxy_port,
    case ProxyHost of
	undefined -> httpc_reset_proxy();
	_ ->
	    case ProxyPort of
		undefined -> httpc_reset_proxy();
		_ -> httpc:set_options([{proxy, {{ProxyHost, ProxyPort}, ["localhost"]}}])
	    end
    end.
