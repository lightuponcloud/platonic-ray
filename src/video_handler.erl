%%
%% HLS video server ( for previews )
%%
-module(video_handler).
-behavior(cowboy_handler).

-export([init/2, content_types_provided/2, allowed_methods/2, to_json/2,
	 is_authorized/2, forbidden/2, resource_exists/2, previously_existed/2,
	 to_response/2]).

-include("general.hrl").
-include("storage.hrl").
-include("entities.hrl").
-include("media.hrl").

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
%% Adds URL prefixes to HLS
%%
prefix_chunks([<< Tag:8/binary, Time/binary >>, Name | T], Prefix, Acc) when Tag =:= <<"#EXTINF:">> ->
    Line = [<< <<"#EXTINF:">>/binary, Time/binary, <<"\n">>/binary, Prefix/binary, Name/binary, <<"\n">>/binary >>],
    prefix_chunks(T, Prefix, [Line | Acc]);
prefix_chunks([<<>>|T], Prefix, Acc) ->
    prefix_chunks(T, Prefix, [<<>> | Acc]);
prefix_chunks([H|T], Prefix, Acc) ->
    prefix_chunks(T, Prefix, [<< H/binary, <<"\n">>/binary >> | Acc]);
prefix_chunks([], _Prefix, Acc) -> Acc.

%%
%% Returns HLS playlist
%%
get_playlist(BucketId, RealPrefix, Prefix, ObjectKey0) ->
    PrefixedPlaylist = utils:prefixed_object_key(utils:dirname(RealPrefix), ?HLS_720p_OBJECT_KEY),
    BinaryData =
	case s3_api:get_object(BucketId, PrefixedPlaylist) of
	    {error, _} -> <<>>;
	    not_found -> <<>>;
	    PlaylistBinary -> proplists:get_value(content, PlaylistBinary)
	end,
    Lines = binary:split(BinaryData, <<"\n">>, [global]),
    ObjectKey1 = erlang:list_to_binary(ObjectKey0),
    HLSPrefix =
	case Prefix of
	    undefined -> << "?object_key=", ObjectKey1/binary, "&hls_part=" >>;
	    _ -> << "?prefix=", Prefix, "&object_key=", ObjectKey1/binary, "&hls_part=" >>
	end,
    erlang:list_to_binary(lists:reverse(prefix_chunks(Lines, HLSPrefix, []))).

%%
%% Downloads HLS part from Riak CS
%%
get_hls_part(BucketId, RealPrefix, Name) ->
    PrefixedPart = utils:prefixed_object_key(utils:dirname(RealPrefix), Name),
    case s3_api:get_object(BucketId, PrefixedPart) of
	{error, _} -> <<>>;
	not_found -> <<>>;
	Data -> proplists:get_value(content, Data)
    end.


to_response(Req0, State) ->
    T0 = utils:timestamp(),
    BucketId = proplists:get_value(bucket_id, State),
    ParsedQs = cowboy_req:parse_qs(Req0),
    Prefix = list_handler:validate_prefix(BucketId, proplists:get_value(<<"prefix">>, ParsedQs)),
    ObjectKey0 =
	case proplists:get_value(<<"object_key">>, ParsedQs) of
	    undefined -> {error, 8};
	    ObjectKey1 -> unicode:characters_to_list(ObjectKey1)
	end,
    HLSPart =
	case proplists:get_value(<<"hls_part">>, ParsedQs) of
	    undefined -> undefined;
	    Part -> unicode:characters_to_list(Part)
	end,
    case lists:keyfind(error, 1, [Prefix, ObjectKey0]) of
	{error, Number} -> js_handler:bad_request(Req0, Number);
	false ->
	    PrefixedObjectKey = utils:prefixed_object_key(Prefix, ObjectKey0),
	    case s3_api:head_object(BucketId, PrefixedObjectKey) of
		{error, Reason} ->
		    lager:error("[video_handler] head_object failed ~p/~p: ~p",
				[BucketId, PrefixedObjectKey, Reason]),
		    {<<>>, Req0, []};
		not_found -> {<<>>, Req0, []};
		Metadata ->
		    {RealBucketId, _, _, RealPrefix} = utils:real_prefix(BucketId, Metadata),
		    BinaryData =
			case HLSPart of
			    undefined -> get_playlist(RealBucketId, RealPrefix, Prefix, ObjectKey0);
			    _ -> get_hls_part(RealBucketId, RealPrefix, HLSPart)
			end,
		    T1 = utils:timestamp(),
		    Req1 = cowboy_req:stream_reply(200, #{
			<<"elapsed-time">> => io_lib:format("~.2f", [utils:to_float(T1-T0)/1000])
		    }, Req0),
		    cowboy_req:stream_body(BinaryData, fin, Req1),
		    {stop, Req1, []}
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
