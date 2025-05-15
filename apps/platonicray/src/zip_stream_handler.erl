-module(zip_stream_handler).

-export([init/2, terminate/3]).
-export([encode_datetime/1]).

-include_lib("common_lib/include/log.hrl").
-include_lib("common_lib/include/storage.hrl").
-include_lib("common_lib/include/zip.hrl").

init(Req0, _Opts) ->
    T0 = utils:timestamp(), %% measure time of request
    cowboy_req:cast({set_options, #{idle_timeout => infinity}}, Req0),

    PathInfo = cowboy_req:path_info(Req0),
    BucketId0 =
	case lists:nth(1, PathInfo) of
	    undefined -> undefined;
	    <<>> -> undefined;
	    BV -> erlang:binary_to_list(BV)
	end,
    Prefix0 =
	case length(PathInfo) < 2 of
	    true -> undefined;
	    false ->
		%% prefix should go just after bucket id
		erlang:binary_to_list(utils:join_binary_with_separator(lists:nthtail(1, PathInfo), <<"/">>))
	end,
    ParsedQs = cowboy_req:parse_qs(Req0),
    PresentedSignature =
	case proplists:get_value(<<"signature">>, ParsedQs) of
	    undefined -> undefined;
	    Signature -> unicode:characters_to_list(Signature)
	end,
    case download_handler:has_access(Req0, BucketId0, Prefix0, undefined, PresentedSignature) of
	{error, Number} ->
	    Req1 = cowboy_req:reply(403, #{
		<<"content-type">> => <<"application/json">>,
                <<"start-time">> => io_lib:format("~.2f", [utils:to_float(T0)/1000])
	    }, jsx:encode([{error, Number}]), Req0),
	    {ok, Req1, []};
	{BucketId1, Prefix1, _, _User} ->
	    TempFile = utils:get_temp_path(platonicray),
	    case file:open(TempFile, [write, read, raw, binary]) of
		{ok, TempFd} ->
		    Headers = #{
			<<"content-type">> => <<"application/zip">>,
			<<"content-disposition">> => <<"attachment; filename=\"archive.zip\"">>
		    },
		    State0 = [
			{current_offset, 0},
			{temp_file, TempFile},
			{temp_fd, TempFd},
			{cd_size, 0},
			{total_entries, 0}
		    ],
		    Req2 = cowboy_req:stream_reply(200, Headers, Req0),

		    List = fetch_full_list_recursively(BucketId1, Prefix1),
		    State1 = stream_files(Req2, BucketId1, proplists:get_value(list, List), State0),
		    FinalState = write_central_directory(Req2, State1),
		    cleanup_resources(TempFile, TempFd),

		    %% Add log record with time it took to download ZIP
		    T1 = utils:timestamp(),
		    ?INFO("[zip_stream_handler] download finished in ~p", [
			  io_lib:format("~.2f", [utils:to_float(T1-T0)/1000])]),
		    {stop, Req2, FinalState};
		{error, Reason} ->
		    ?ERROR("[zip_stream_handler] Failed to create temporary file: ~p", [Reason]),
		    Req1 = cowboy_req:reply(500, #{}, <<"Internal Server Error">>, Req0),
		    {ok, Req1, []}
	    end
    end.

%%
%% Receives stream from httpc and passes it to cowboy
%%
receive_streamed_body(Req0, RequestId0, Pid0, BucketId, NextObjectKeys0, OldCrc) ->
    httpc:stream_next(Pid0),
    receive
	{http, {RequestId0, stream, BinBodyPart}} ->
	    ok = cowboy_req:stream_body(BinBodyPart, nofin, Req0),
	    Crc32 =
		case OldCrc of
		    undefined -> erlang:crc32(BinBodyPart);
		    _ -> erlang:crc32(OldCrc, BinBodyPart)
		end,
	    receive_streamed_body(Req0, RequestId0, Pid0, BucketId, NextObjectKeys0, Crc32);
	{http, {RequestId0, stream_end, _Headers0}} ->
	    case NextObjectKeys0 of
		[] ->
		    ok = cowboy_req:stream_body(<<>>, nofin, Req0),
		    OldCrc;  %% nofin, as we are streaming zip
		[CurrentObjectKey|NextObjectKeys1] ->
		    %% Stream next chunk
		    case s3_api:get_object(BucketId, CurrentObjectKey, stream) of
			not_found ->
			    ok = cowboy_req:stream_body(<<>>, fin, Req0),
			    throw(lists:flatten(io_lib:format("Failed to fetch part: ~p/~p", [BucketId, CurrentObjectKey])));
			{ok, RequestId1} ->
			    receive
				{http, {RequestId1, stream_start, _Headers1, Pid1}} ->
				    receive_streamed_body(Req0, RequestId1, Pid1, BucketId, NextObjectKeys1, OldCrc);
				{http, Msg} -> throw(lists:flatten(io_lib:format("Failed to fetch part: ~p", [Msg])))
			    end
		    end
	    end;
	{http, Msg} ->
	    ok = cowboy_req:stream_body(<<>>, fin, Req0),
	    throw(lists:flatten(io_lib:format("Error receiving stream body: ~p", [Msg])))
    end.


%%
%% Lists objects in 'real' prefix ( "~object/" ), sorts them and streams them to client.
%%
stream_chunks(Req0, BucketId, RealPrefix, Bytes, OldCrc) ->
    MaxKeys = ?FILE_MAXIMUM_SIZE div ?FILE_UPLOAD_CHUNK_SIZE,
    PartNumStart = 1,
    PartNumEnd = (Bytes div ?FILE_UPLOAD_CHUNK_SIZE) + 1,
    %% list chunks of object
    case s3_api:list_objects(BucketId, [{max_keys, MaxKeys}, {prefix, RealPrefix ++ "/"}]) of
	not_found -> throw(lists:flatten(io_lib:format("Part not found: ~p", [RealPrefix])));
	RiakResponse0 ->
	    Contents = proplists:get_value(contents, RiakResponse0),
	    List0 = lists:filtermap(
		fun(K) ->
		    ObjectKey = proplists:get_value(key, K),
		    case utils:ends_with(ObjectKey, erlang:list_to_binary(?THUMBNAIL_KEY)) of
			true -> false;
			false ->
			    Tokens = lists:last(string:tokens(ObjectKey, "/")),
			    [N,_] = string:tokens(Tokens, "_"),
			    case utils:to_integer(N) of
				I when I >= PartNumStart, I =< PartNumEnd -> {true, ObjectKey};
				_ -> false
			    end
		    end
		end, Contents),
	    List1 = lists:sort(
		fun(K1, K2) ->
		    T1 = lists:last(string:tokens(K1, "/")),
		    [N1,_] = string:tokens(T1, "_"),
		    T2 = lists:last(string:tokens(K2, "/")),
		    [N2,_] = string:tokens(T2, "_"),
		    utils:to_integer(N1) < utils:to_integer(N2)
		end, List0),
	    case List1 of
		[] -> throw("No file chunks found");
		[PrefixedObjectKey | NextKeys] ->
		    case s3_api:get_object(BucketId, PrefixedObjectKey, stream) of
			not_found ->
			    throw(lists:flatten(io_lib:format("Chunk not found: ~p/~p", [BucketId, PrefixedObjectKey])));
			{ok, RequestId} ->
			    receive
				{http, {RequestId, stream_start, _Headers, Pid}} ->
				    receive_streamed_body(Req0, RequestId, Pid, BucketId, NextKeys, OldCrc);
				{http, Msg} ->
				    throw(lists:flatten(io_lib:format("Error starting stream: ~p", [Msg])))
			    end
		    end
	    end
    end.


fetch_full_list_recursively(BucketId, Prefix0) ->
    Prefix1 =
	case utils:ends_with(Prefix0, <<"/">>) of
	    true -> Prefix0;
	    false ->
		case Prefix0 of
		    undefined -> false;
		    _ -> Prefix0 ++ "/"
		end
	end,
    DirPath0 = utils:unhex_path(Prefix1),
    DirPath1 = unicode:characters_to_binary(lists:flatten(DirPath0)),
    IsDeleted = lists:any(fun(S) -> string:str(S, "-deleted-") =/= 0 end, DirPath0),
    case IsDeleted of
	false ->
	    List = indexing:fetch_full_list(BucketId, Prefix1),

	    Prefixes = proplists:get_value(dirs, List, []),
	    Objects = proplists:get_value(list, List, []),
	    Acc = [{dirs, [DirPath1]}, {list, Objects}],
	    fetch_full_list_recursively(BucketId, Prefixes, Acc);
	true -> [{dirs, []}, {list, []}]
    end.

fetch_full_list_recursively(_BucketId, [], Acc) -> Acc;
fetch_full_list_recursively(BucketId, [Prefix|Rest], Acc0) ->
    %% Check if directory is marked as deleted
    DirPath0 = utils:unhex_path(Prefix),
    DirPath1 = unicode:characters_to_binary(lists:flatten(DirPath0)),
    IsDeleted = lists:any(fun(S) -> string:str(S, "-deleted-") =/= 0 end, DirPath0),
    case IsDeleted of
	false ->
	    List = indexing:fetch_full_list(BucketId, Prefix),

	    Prefixes = proplists:get_value(dirs, List, []),
	    Objects = proplists:get_value(list, List, []),

	    Acc1 = [{dirs, [DirPath1] ++ proplists:get_value(dirs, Acc0, [])},
		   {list, Objects ++ proplists:get_value(list, Acc0, [])}],

	    fetch_full_list_recursively(BucketId, Prefixes ++ Rest, Acc1);
	true ->
	    fetch_full_list_recursively(BucketId, Rest, Acc0)
    end.


stream_files(_Req, _BucketId, [], State) -> State;
stream_files(Req0, BucketId, [Object|Rest], State0) ->
    Prefix = utils:dirname(element(1, Object)),
    ObjectKey = filename:basename(element(1, Object)),
    DateTime = element(2, Object),
    DirPath = unicode:characters_to_binary(lists:flatten(utils:unhex_path(Prefix))),

    case download_handler:get_object_metadata(BucketId, Prefix, ObjectKey) of
	not_found -> State0;  %% Ignore
	{OldBucketId, RealPrefix, _ContentType, OrigName, Bytes, _Version} ->
	    Offset = proplists:get_value(current_offset, State0),
	    TempFd = proplists:get_value(temp_fd, State0),
	    TotalEntries = proplists:get_value(total_entries, State0),
	    CdSize = proplists:get_value(cd_size, State0),

	    Name = unicode:characters_to_binary(<<DirPath/binary, "/", OrigName/binary>>, utf8),
	    {DosDate, DosTime} = encode_datetime(DateTime),
	    %% Local header with ZIP64 and data descriptor flags
	    LocalHeader = <<
		?LOCAL_FILE_HEADER_SIGNATURE:32/little,
		?VERSION_ZIP64:16/little,
		(?USE_UTF8 bor ?USE_DATA_DESCRIPTOR):16/little,         %%  Using data descriptor
		?COMPRESSION_STORE:16/little,
		DosTime:16/little,                      %%  Time
		DosDate:16/little,                      %%  Date
		0:32/little,                            %%  CRC32 (will be in descriptor)
		16#FFFFFFFF:32/little,                  %%  Compressed size
		16#FFFFFFFF:32/little,                  %%  Uncompressed size
		(byte_size(Name)):16/little,
		0:16/little,                            %%  No extra field needed here
		Name/binary
	    >>,
	    ok = cowboy_req:stream_body(LocalHeader, nofin, Req0),
	    FileSize = utils:to_integer(Bytes),
	    Crc32 = stream_chunks(Req0, OldBucketId, RealPrefix, FileSize, undefined),

	    %% Data descriptor (ZIP64)
	    DataDescriptor = <<
		?DATA_DESCRIPTOR_SIGNATURE:32/little,
		Crc32:32/little,
		FileSize:64/little,                     %%  Compressed size
		FileSize:64/little                      %%  Uncompressed size
	    >>,
	    ok = cowboy_req:stream_body(DataDescriptor, nofin, Req0),

	    %% Central directory entry (ZIP64)
	    CentralEntry = <<
		?CENTRAL_DIR_SIGNATURE:32/little,
		?VERSION_ZIP64:16/little,
		?VERSION_ZIP64:16/little,
		(?USE_UTF8 bor ?USE_DATA_DESCRIPTOR):16/little,
		?COMPRESSION_STORE:16/little,
		DosTime:16/little,                      %%  Time
		DosDate:16/little,                      %%  Date
		Crc32:32/little,
		16#FFFFFFFF:32/little,                  %%  Compressed size
		16#FFFFFFFF:32/little,                  %%  Uncompressed size
		(byte_size(Name)):16/little,
		28:16/little,                           %%  Extra field length
		0:16/little,                            %%  Comment length
		0:16/little,                            %%  Disk number start
		0:16/little,                            %%  Internal attrs
		16#81B60000:32/little,                  %%  External attrs (Unix file)
		16#FFFFFFFF:32/little,                  %%  Offset to local header
		Name/binary,
		16#0001:16/little,                      %%  ZIP64 extra field header ID
		24:16/little,                           %%  Extra field size
		FileSize:64/little,                     %%  Uncompressed size
		FileSize:64/little,                     %%  Compressed size
		Offset:64/little                        %%  Local header offset
	    >>,
	    ok = file:write(TempFd, CentralEntry),

	    NewOffset = Offset + byte_size(LocalHeader) + FileSize + byte_size(DataDescriptor),

	    State1 = lists:keystore(current_offset, 1, 
		lists:keystore(total_entries, 1,
		    lists:keystore(cd_size, 1, State0,
			{cd_size, CdSize + byte_size(CentralEntry)}),
		    {total_entries, TotalEntries + 1}),
		{current_offset, NewOffset}),
	    stream_files(Req0, BucketId, Rest, State1)
    end.


%% Date/time encoding for ZIP format
encode_datetime({{Year, Month, Day}, {Hour, Minute, Second}}) ->
    %%  MS-DOS Date Format:
    %%  Bits 0-4: Day (1-31)
    %%  Bits 5-8: Month (1-12)
    %%  Bits 9-15: Year offset from 1980
    DosDate = (((Year - 1980) band 16#7F) bsl 9) bor
              ((Month band 16#0F) bsl 5) bor
              (Day band 16#1F),

    %%  MS-DOS Time Format:
    %%  Bits 0-4: Second divided by 2 (0-29)
    %%  Bits 5-10: Minute (0-59)
    %%  Bits 11-15: Hour (0-23)
    DosTime = ((Hour band 16#1F) bsl 11) bor
              ((Minute band 16#3F) bsl 5) bor
              ((Second div 2) band 16#1F),

    {DosDate, DosTime}.


%% Stream temp file content in chunks
stream_file_content(Req0, File) ->
    case file:read(File, ?CHUNK_SIZE) of
        {ok, Chunk} ->
            ok = cowboy_req:stream_body(Chunk, nofin, Req0),
            stream_file_content(Req0, File);
        eof -> ok
    end.

write_central_directory(Req0, State) ->
    Offset = proplists:get_value(current_offset, State),
    TempFd = proplists:get_value(temp_fd, State),
    CdSize = proplists:get_value(cd_size, State),
    TotalEntries = proplists:get_value(total_entries, State),

    %% Stream central directory entries from temp file
    {ok, 0} = file:position(TempFd, 0),
    stream_file_content(Req0, TempFd),

    %% ZIP64 end of central directory record
    Zip64EndRecord = <<
        ?ZIP64_END_OF_CENTRAL_DIR_SIGNATURE:32/little,
        44:64/little,                          %%  Size of record
        ?VERSION_ZIP64:16/little,              %%  Version made by
        ?VERSION_ZIP64:16/little,              %%  Version needed
        0:32/little,                           %%  Number of this disk
        0:32/little,                           %%  Disk with CD start
        TotalEntries:64/little,                %%  Number of entries this disk
        TotalEntries:64/little,                %%  Total number of entries
        CdSize:64/little,                      %%  Size of central directory
        Offset:64/little                       %%  Offset of central directory
    >>,
    ok = cowboy_req:stream_body(Zip64EndRecord, nofin, Req0),

    %%  ZIP64 end of central directory locator
    Zip64EndLocator = <<
        ?ZIP64_END_OF_CENTRAL_DIR_LOCATOR_SIGNATURE:32/little,
        0:32/little,                           %%  Disk number with ZIP64 EOCD
        (Offset + CdSize):64/little,           %%  Offset of ZIP64 EOCD record
        1:32/little                            %%  Total number of disks
    >>,
    ok = cowboy_req:stream_body(Zip64EndLocator, nofin, Req0),

    %%  End of central directory record
    EndRecord = <<
        ?END_OF_CENTRAL_DIR_SIGNATURE:32/little,
        0:16/little,                           %%  Number of this disk
        0:16/little,                           %%  Disk where CD starts
        16#FFFF:16/little,                     %%  Number of entries this disk
        16#FFFF:16/little,                     %%  Total number of entries
        16#FFFFFFFF:32/little,                 %%  Size of central directory
        16#FFFFFFFF:32/little,                 %%  Offset of central directory
        0:16/little                            %%  ZIP comment length
    >>,
    ok = cowboy_req:stream_body(EndRecord, fin, Req0),
    State.

cleanup_resources(TempFile, TempFd) ->
    file:close(TempFd),
    file:delete(TempFile).

terminate(_Reason, _Req, State) ->
    TempFile = proplists:get_value(temp_file, State),
    TempFd = proplists:get_value(temp_fd, State),
    cleanup_resources(TempFile, TempFd),
    ok.
