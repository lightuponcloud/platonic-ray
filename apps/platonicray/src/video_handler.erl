%%
%% Video previews ( Webm )
%%
-module(video_handler).
-behavior(cowboy_handler).

-export([init/2, content_types_provided/2, allowed_methods/2, to_json/2,
	 is_authorized/2, forbidden/2, resource_exists/2, previously_existed/2,
	 to_response/2]).

-include_lib("common_lib/include/log.hrl").
-include_lib("common_lib/include/storage.hrl").
-include_lib("common_lib/include/entities.hrl").
-include_lib("common_lib/include/general.hrl").
-include_lib("common_lib/include/media.hrl").

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

content_types_provided(Req, State) ->
    {[
	{{<<"application">>, <<"x-mpegURL">>, '*'}, to_response}
    ], Req, State}.

%%
%% Called first
%%
allowed_methods(Req, State) ->
    {[<<"GET">>], Req, State}.

to_json(Req0, State) ->
    {<<>>, Req0, State}.

%%
%% Receives stream from httpc and passes it to cowboy
%%
receive_streamed_body(Req0, RequestId0, Pid0) ->
    httpc:stream_next(Pid0),
    receive
	{http, {RequestId0, stream, BinBodyPart}} ->
	    cowboy_req:stream_body(BinBodyPart, nofin, Req0),
	    receive_streamed_body(Req0, RequestId0, Pid0);
	{http, {RequestId0, stream_end, _Headers0}} ->
	    cowboy_req:stream_body(<<>>, fin, Req0);
	{http, Msg} ->
	    ?ERROR("[video_handler] error receiving stream body: ~p", [Msg]),
	    cowboy_req:stream_body(<<>>, fin, Req0)
    end.

%%
%% Streams WEBM preview.
%%
stream_webm(Req0, BucketId, Prefix, OrigName0, Bytes, StartByte0) ->
    PrefixedWebm = utils:prefixed_object_key(Prefix, ?WEBM_OBJECT_KEY),
    OrigName1 = utils:to_binary(filename:rootname(OrigName0)),
    OrigName2 = << OrigName1/binary, <<".webm">>/binary>>,
    ContentDisposition = << <<"attachment;filename=\"">>/binary, OrigName2/binary, <<"\"">>/binary >>,
    StartByte1 = erlang:integer_to_binary(StartByte0),
    Headers0 = #{
	<<"content-type">> => << "application/octet-stream" >>,
	<<"content-disposition">> => ContentDisposition,
	<<"content-length">> => erlang:integer_to_binary(Bytes),
	<<"range">> => << "bytes=", StartByte1/binary, "-" >>
    },
    Req1 = cowboy_req:stream_reply(200, Headers0, Req0),
    case s3_api:get_object(BucketId, PrefixedWebm, stream) of
	not_found ->
	    %% It could be preview isn't ready yet
	    Req2 = cowboy_req:set_resp_body(<<>>, Req1),
	    {ok, Req2, []};
	{ok, RequestId} ->
	    receive
	    {http, {RequestId, stream_start, _Headers, Pid}} ->
		receive_streamed_body(Req1, RequestId, Pid);
		{http, Msg} -> ?ERROR("[video_handler] error starting stream: ~p", [Msg])
	    end,
	    {ok, Req1, []}
    end.

to_response(Req0, State) ->
    BucketId = proplists:get_value(bucket_id, State),
    ParsedQs = cowboy_req:parse_qs(Req0),
    Prefix = object_handler:validate_prefix(BucketId, proplists:get_value(<<"prefix">>, ParsedQs)),
    ObjectKey0 =
	case proplists:get_value(<<"object_key">>, ParsedQs) of
	    undefined -> {error, 8};
	    ObjectKey1 -> unicode:characters_to_list(ObjectKey1)
	end,
    case lists:keyfind(error, 1, [Prefix, ObjectKey0]) of
	{error, Number} -> js_handler:bad_request(Req0, Number);
	false ->
	    PrefixedObjectKey = utils:prefixed_object_key(Prefix, ObjectKey0),
	    case s3_api:head_object(BucketId, PrefixedObjectKey) of
		{error, Reason} ->
		    ?ERROR("[video_handler] head_object failed ~p/~p: ~p", [BucketId, PrefixedObjectKey, Reason]),
		    {<<>>, Req0, []};
		not_found -> {<<>>, Req0, []};
		Metadata ->
		    Bytes =
			case proplists:get_value("x-amz-meta-bytes", Metadata) of
			    undefined -> 0;  %% It might be undefined in case of corrupted metadata
			    B -> utils:to_integer(B)
			end,
		    OrigName0 = proplists:get_value("orig-filename", Metadata),
		    OrigName1 = utils:unhex(erlang:list_to_binary(OrigName0)),
		    {RealBucketId, _, _, RealPrefix} = utils:real_prefix(BucketId, Metadata),
		    case download_handler:validate_range(cowboy_req:header(<<"range">>, Req0), Bytes) of
			undefined -> stream_webm(Req0, RealBucketId, RealPrefix, OrigName1, Bytes, 0);
			{error, Number} -> js_handler:bad_request_ok(Req0, Number);
			{StartByte, _EndByte} -> stream_webm(Req0, RealBucketId, RealPrefix, OrigName1, Bytes, StartByte)
		    end
	    end
    end.

%%
%% Checks if provided token is correct ( Token is optional here ).
%% ( called after 'allowed_methods()' )
%%
is_authorized(Req0, State) ->
    img_scale_handler:is_authorized(Req0, State).

%%
%% Checks if provided token ( or access token ) is valid.
%% ( called after 'allowed_methods()' )
%%
forbidden(Req0, State) ->
    img_scale_handler:forbidden(Req0, State).

%%
%% Validates request parameters
%% ( called after 'content_types_provided()' )
%%
resource_exists(Req0, State) ->
    {true, Req0, State}.

previously_existed(Req0, _State) ->
    {false, Req0, []}.
