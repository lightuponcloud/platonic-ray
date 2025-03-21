%%
%% Video preview generator.
%%
-module(video_transcoding).
-behaviour(gen_server).

-export([start_link/1, ffmpeg/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-include("log.hrl").
-include("storage.hrl").

%%
%% Queue -- List of queued video transcoding requests
%%
-record(state, {os_pid :: undefined | pos_integer(),
		num :: pos_integer(),
		queue = [], queue_check_timer = []}).

-define(QUEUE_CHECK_INTERVAL, 5000).  %% every 5 seconds

%%
%% Starts N servers for video transcoding
%%
start_link(Number) ->
    Name = list_to_atom(
	lists:flatten(io_lib:format("video_sup_~p", [Number]))),
    gen_server:start_link({local, Name}, ?MODULE, [Number], []).

ffmpeg(BucketId, ObjectKey) ->
    Number = rand:uniform(?VIDEO_WORKERS)-1,
    Name = list_to_atom(
	lists:flatten(io_lib:format("video_sup_~p", [Number]))),
    gen_server:cast(Name, {ffmpeg, BucketId, ObjectKey}).

init([Number]) ->
    process_flag(trap_exit, true),
    {ok, Tref0} = timer:send_after(?QUEUE_CHECK_INTERVAL, check_queue),
    {ok, #state{queue_check_timer = Tref0, num = Number}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast({ffmpeg, BucketId, ObjectKey}, #state{queue = Queue0} = State) ->
    %% Adds record for periodic task processor
    Queue1 =
	case proplists:is_defined(BucketId, Queue0) of
	    false ->
		%% Add to queue
		BQ0 = [{BucketId, [ObjectKey]}],
		Queue0 ++ BQ0;
	    true ->
		%% Change bucket queue
		lists:map(
		    fun(I) ->
			case element(1, I) of
			    BucketId ->
				BQ1 = element(2, I),
				{BucketId, BQ1 ++ [ObjectKey]};
			    _ -> I
			end
		    end, Queue0)
	end,
    {noreply, State#state{queue = Queue1}};


handle_cast(_Msg, State) ->  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages. Called by send_after() call.
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(check_queue, #state{queue = Queue0} = State) ->
    %% Go over per-bucket queues of tasks, transcode vides
    Queue1 =
	lists:map(
	    fun(I) ->
		BucketId = element(1, I),
		BucketQueue0 = element(2, I),
		BucketQueue1 =
		    case length(BucketQueue0) of
			0 -> [];  %% do nothing, try later
			_ ->
			    lists:filter(
				fun(ObjectKey) ->
				    case process_video(BucketId, ObjectKey) of
					{error, _} -> true;
					_ -> false
				    end
				end, BucketQueue0)
		    end,
		{BucketId, BucketQueue1}
	    end, Queue0),
    {ok, Tref0} = timer:send_after(?QUEUE_CHECK_INTERVAL, check_queue),
    {noreply, State#state{queue_check_timer = Tref0, queue = Queue1}};

handle_info(Info, State) ->
    ?ERROR("[video_transcoding] got unexpected info: ~p", [Info]),
    {noreply, State}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(Reason, _State) ->
    lager:warning("[video_transcoding] terminating. Reason: ~p~n", [Reason]),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%
%% Download video and launch transcoding process
%%
process_video(BucketId, ObjectKey) ->
    case download_file(BucketId, ObjectKey) of
	{error, Reason} ->
	    ?ERROR("[video_transcoding] can't download file: ~p/~p: ~p", [BucketId, ObjectKey, Reason]),
	    {error, Reason};
	{RealPrefix, TempFn} ->
	    %% Create temporary directory for HLS output
	    TempDir = string:trim(os:cmd("/bin/mktemp -d")),

	    FfmpegCmd = io_lib:format("cd ~s;/usr/bin/ffmpeg -i ~s -an -c:v libvpx-vp9 -crf 30 -b:v 0 -vf \"scale=1280:-1\" -deadline good -cpu-used 2 -auto-alt-ref 1 -lag-in-frames 25 -f hls -hls_segment_type fmp4 -hls_time 4 -hls_playlist_type vod -hls_flags single_file+independent_segments+split_by_time+temp_file ~s",
		[TempDir, TempFn, ?HLS_720p_OBJECT_KEY]),
	    os:cmd(lists:flatten(FfmpegCmd)),

	    %% Upload HLS
	    case file:list_dir_all(TempDir) of
		{ok, List} ->
		    lists:foreach(
			fun(I) ->
			    Path = filename:join([TempDir, I]),
			    case file:read_file(Path) of
				{error, enoent} ->
				    ?ERROR("[video_transcoding] file disappeared: ~p video: ~p/~p",
					   [I, BucketId, ObjectKey]),
				    ok;
				{ok, BinaryData} ->
				    Response = s3_api:put_object(BucketId, RealPrefix, I, BinaryData),
				    case Response of
					{error, Reason} ->
					    ?ERROR("[video_transcoding] Can't put object ~p/~p: ~p",
						   [BucketId, RealPrefix, Reason]),
					    {error, Reason};
					_ -> file:delete(I)
				    end
			    end
			end, List),
		    file:delete(TempFn),
		    file:del_dir(TempDir),
		    ok;
		{error, enoent} ->
		    ?ERROR("[video_transcoding] can't transcode video ~p/~p: no playlist in ~p",
			   [BucketId, ObjectKey, TempDir]),
		    file:delete(TempFn),
		    {error, enoent}
	    end
    end.

%%
%% Download object from Riak CS
%%
download_file(BucketId, ObjectKey) ->
    case s3_api:head_object(BucketId, ObjectKey) of
	{error, Reason} ->
	    lager:error("[video_transcoding] head_object failed ~p/~p: ~p", [BucketId, ObjectKey, Reason]),
	    {error, Reason};
	not_found -> {error, not_found};
	undefined -> {error, not_found};
	Metadata ->
	    %% Create a temporary file, write data there
	    Ext = filename:extension(ObjectKey),
	    TempFn = string:trim(os:cmd(io_lib:format("/bin/mktemp --suffix=~p", [Ext]))),

	    {RealBucketId, _, _, RealPrefix} = utils:real_prefix(BucketId, Metadata),
	    case save_file(RealBucketId, RealPrefix, TempFn) of
		{error, Reason} -> {error, Reason};
		ok ->
		    case filelib:is_regular(TempFn) of
			true -> {utils:dirname(RealPrefix), TempFn};
			false ->
			    lager:error("[video_transcoding] failed to transcode video ~p, no file ~p",
					[ObjectKey, TempFn]),
			    {error, file_not_found}
		    end
	    end
    end.

%%
%% Receives stream from httpc and writes it to file
%%
receive_streamed_body(RequestId0, Pid0, BucketId, NextObjectKeys0, OutputFileName) ->
    httpc:stream_next(Pid0),
    receive
	{http, {RequestId0, stream, BinBodyPart}} ->
	    file:write_file(OutputFileName, BinBodyPart, [append]),
	    receive_streamed_body(RequestId0, Pid0, BucketId, NextObjectKeys0, OutputFileName);
	{http, {RequestId0, stream_end, _Headers0}} ->
	    case NextObjectKeys0 of
		[] -> ok;
		[CurrentObjectKey|NextObjectKeys1] ->
		    %% stream next chunk
		    case s3_api:get_object(BucketId, CurrentObjectKey, stream) of
			not_found ->
			    lager:error("[video_transcoding] part not found: ~p/~p", [BucketId, CurrentObjectKey]),
			    {error, not_found};
			{ok, RequestId1} ->
			    receive
				{http, {RequestId1, stream_start, _Headers1, Pid1}} ->
				    receive_streamed_body(RequestId1, Pid1, BucketId, NextObjectKeys1, OutputFileName);
				{http, Msg} ->
				    lager:error("[video_transcoding] stream error: ~p", [Msg]),
				    {error, stream_error}
			    end
		    end
	    end;
	{http, Msg} ->
	    lager:error("[video_transcoding] cant receive stream body: ~p", [Msg]),
	    {error, stream_error}
    end.

%%
%% Goes over chunks of object and saves them on local filesystem
%%
save_file(BucketId, RealPrefix, OutputFileName) ->
    MaxKeys = ?FILE_MAXIMUM_SIZE div ?FILE_UPLOAD_CHUNK_SIZE,
    case s3_api:list_objects(BucketId, [{max_keys, MaxKeys}, {prefix, RealPrefix ++ "/"}]) of
	not_found -> {error, not_found};
	RiakResponse0 ->
	    Contents = proplists:get_value(contents, RiakResponse0),
	    %% We take into account 'range' header, by taking all parts from specified one
	    List0 = lists:filtermap(
		fun(K) ->
		    ObjectKey = proplists:get_value(key, K),
		    case utils:ends_with(ObjectKey, erlang:list_to_binary(?THUMBNAIL_KEY)) of
			true -> false;
			false -> {true, ObjectKey}
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
		 [] -> ok;
		 [PrefixedObjectKey | NextKeys] ->
		    case s3_api:get_object(BucketId, PrefixedObjectKey, stream) of
			not_found -> {error, not_found};
			{ok, RequestId} ->
			    receive
				{http, {RequestId, stream_start, _Headers, Pid}} ->
				    receive_streamed_body(RequestId, Pid, BucketId, NextKeys, OutputFileName);
				{http, Msg} ->
				    lager:error("[video_transcoding] error starting stream: ~p", [Msg]),
				    {error, stream_error}
			    end
		    end
	    end
    end.
