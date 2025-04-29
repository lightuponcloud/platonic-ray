%%
%% Video preview generator.
%%
-module(video_sup).
-behaviour(gen_server).

-export([start_link/1, ffmpeg/2, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("log.hrl").
-include("storage.hrl").

-define(QUEUE_CHECK_INTERVAL, 5_000).  % 5 seconds
-define(PMAP_WORKERS, 4).              % Parallel workers for video processing
-define(MAX_RETRIES, 3).               % Max retry attempts for failed transcoding
-define(RATE_LIMIT_PER_SECOND, 10).    % Requests per second per bucket
-define(BUCKET_CAPACITY, 100).         % Token bucket capacity
-define(WEBM_OUTPUT_KEY, "preview.webm"). % Output key for WebM file

-record(state, {
    os_pid = undefined :: undefined | pos_integer(),
    num :: pos_integer(),
    queue_check_timer = undefined :: undefined | reference(),
    rate_limits = #{} :: #{binary() => {integer(), integer()}}, % {Tokens, LastRefill}
    retries = #{} :: #{binary() => integer()} % Track retry attempts
}).

%%% API
start_link(Number) ->
    Name = list_to_atom(lists:flatten(io_lib:format("video_sup_~p", [Number]))),
    gen_server:start_link({local, Name}, ?MODULE, [Number], []).

ffmpeg(BucketId, ObjectKey) ->
    Number = rand:uniform(?VIDEO_WORKERS) - 1,
    Name = list_to_atom(lists:flatten(io_lib:format("video_sup_~p", [Number]))),
    gen_server:cast(Name, {ffmpeg, BucketId, ObjectKey}).

stop(Name) ->
    gen_server:stop(Name).

%%% gen_server callbacks
init([Number]) ->
    process_flag(trap_exit, true),
    {ok, Tref} = timer:send_after(?QUEUE_CHECK_INTERVAL, check_queue),
    {ok, #state{num = Number, queue_check_timer = Tref}}.

handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast({ffmpeg, BucketId, ObjectKey}, State) ->
    case check_rate_limit(BucketId, State) of
        {error, rate_limited} ->
            ?WARNING("[video_sup] Rate limit exceeded for bucket ~p", [BucketId]),
            {noreply, State};
        {ok, NewRateLimits} ->
            light_ets:enqueue_transcode(BucketId, ObjectKey),
            {noreply, State#state{rate_limits = NewRateLimits}}
    end;

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(check_queue, #state{retries = Retries} = State) ->
    case light_ets:get_transcode_queue_size() of
        0 ->
            {ok, Tref} = timer:send_after(?QUEUE_CHECK_INTERVAL, check_queue),
            {noreply, State#state{queue_check_timer = Tref}};
        _Size ->
            Items = light_ets:dequeue_transcode(?PMAP_WORKERS),
            case Items of
                [] ->
                    {ok, Tref} = timer:send_after(?QUEUE_CHECK_INTERVAL, check_queue),
                    {noreply, State#state{queue_check_timer = Tref}};
                Batch ->
                    {NewItems, NewRetries} = process_queue(Batch, Retries),
                    [light_ets:requeue_transcode(Item) || Item <- NewItems],
                    {ok, Tref} = timer:send_after(?QUEUE_CHECK_INTERVAL, check_queue),
                    {noreply, State#state{
                        queue_check_timer = Tref,
                        retries = NewRetries
                    }}
            end
    end;

handle_info({'EXIT', _Pid, _Reason}, State) ->
    {noreply, State};

handle_info(Info, State) ->
    ?ERROR("[video_sup] Unexpected info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, #state{queue_check_timer = Timer}) ->
    case Timer of
        undefined -> ok;
        _ -> timer:cancel(Timer)
    end,
    lager:info("[video_sup] Terminated"),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%% Internal functions
check_rate_limit(BucketId, #state{rate_limits = Limits} = State) ->
    Now = erlang:system_time(millisecond),
    {Tokens, LastRefill} = maps:get(BucketId, Limits, {?BUCKET_CAPACITY, Now}),
    TokensAvailable = min(?BUCKET_CAPACITY, Tokens + tokens_to_add(LastRefill, Now)),

    case TokensAvailable >= 1 of
        true ->
            NewLimits = Limits#{BucketId => {TokensAvailable - 1, Now}},
            {ok, NewLimits};
        false ->
            {error, rate_limited}
    end.

tokens_to_add(LastRefill, Now) ->
    TimeDiff = (Now - LastRefill) div 1000,
    TimeDiff * ?RATE_LIMIT_PER_SECOND.

process_queue(Items, Retries) ->
    Results = pmap:pmap(fun({BucketId, ObjectKey, RetryCount}) ->
        Key = <<BucketId/binary, "/", ObjectKey/binary>>,
        case process_video(BucketId, ObjectKey) of
            ok -> {ok, Key};
            {error, Reason} when RetryCount < ?MAX_RETRIES ->
                {retry, {BucketId, ObjectKey, RetryCount + 1}, Reason};
            {error, Reason} ->
                {error, {crash, Reason}}
        end
    end, Items, ?PMAP_WORKERS),

    lists:foldl(fun
        ({ok, _Key}, {QueueAcc, RetriesAcc}) ->
            {QueueAcc, RetriesAcc};
        ({retry, {BucketId, ObjectKey, RetryCount}, _Reason}, {QueueAcc, RetriesAcc}) ->
            Key = <<BucketId/binary, "/", ObjectKey/binary>>,
            {[{BucketId, ObjectKey, RetryCount} | QueueAcc], RetriesAcc#{Key => RetryCount}};
        ({error, {crash, Reason}}, {QueueAcc, RetriesAcc}) ->
            Key = <<BucketId/binary, "/", ObjectKey/binary>>,
            ?ERROR("[video_sup] Failed processing ~p after retries: ~p", [Key, Reason]),
            {QueueAcc, maps:remove(Key, RetriesAcc)}
    end, {[], Retries}, Results).

process_video(BucketId, ObjectKey) ->
    case download_file(BucketId, ObjectKey) of
        {error, Reason} ->
            ?ERROR("[video_sup] Download failed: ~p/~p: ~p", [BucketId, ObjectKey, Reason]),
            {error, Reason};
        {RealPrefix, TempFn} ->
            TempDir = string:trim(os:cmd("/bin/mktemp -d")),
            TempOutput = filename:join(TempDir, ?WEBM_OUTPUT_KEY),
            try
                FffmpegCmd = io_lib:format(
                    "cd ~s;/usr/bin/ffmpeg -ss 00:00:05 -i ~s -an -c:v libvpx-vp9 -crf 30 -b:v 0 "
                    "-vf \"scale=1920:-1,crop=1920:478:(iw-1920)/2:(ih-478)/2\" -deadline good "
                    "-cpu-used 2 -auto-alt-ref 1 -lag-in-frames 25 -f webm ~s",
                    [TempDir, TempFn, TempOutput]),
                case os:cmd(lists:flatten(FffmpegCmd)) of
                    CmdOutput when is_list(CmdOutput), CmdOutput /= "" ->
                        case upload_webm_file(BucketId, RealPrefix, TempOutput) of
                            ok -> ok;
                            Error -> Error
                        end;
                    _ ->
                        {error, ffmpeg_failed}
                end
            after
                file:delete(TempFn),
                file:delete(TempOutput),
                file:del_dir_r(TempDir)
            end
    end.

upload_webm_file(BucketId, RealPrefix, TempOutput) ->
    case file:read_file(TempOutput) of
        {ok, Data} ->
            OutputKey = filename:join(RealPrefix, ?WEBM_OUTPUT_KEY),
            case s3_api:put_object(BucketId, OutputKey, Data) of
                {error, Reason} ->
                    ?ERROR("[video_sup] S3 upload failed: ~p/~p: ~p",
                           [BucketId, OutputKey, Reason]),
                    {error, Reason};
                _ -> ok
            end;
        {error, Reason} ->
            ?ERROR("[video_sup] Failed to read WebM file ~p: ~p", [TempOutput, Reason]),
            {error, Reason}
    end.

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
                {error, Reason} ->
                    {error, Reason};
                ok ->
                    case filelib:is_regular(TempFn) of
                        true -> {utils:dirname(RealPrefix), TempFn};
                        false ->
                            ?ERROR("[video_sup] Download failed: ~p/~p, no file", [BucketId, ObjectKey]),
                            {error, file_not_found}
                    end
            end
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
				    lager:error("[video_sup] error starting stream: ~p", [Msg]),
				    {error, stream_error}
			    end
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
	    lager:error("[video_sup] cant receive stream body: ~p", [Msg]),
	    {error, stream_error}
    end.
