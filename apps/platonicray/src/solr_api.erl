%%
%% This module sends data to Solr for indexation.
%%
-module(solr_api).
-behavior(gen_server).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, start_link/0]).

-include_lib("common_lib/include/log.hrl").
-include_lib("common_lib/include/storage.hrl").
-include_lib("common_lib/include/solr.hrl").

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, []}.

handle_cast(Message, State) ->
    BucketId = proplists:get_value(bucket_id, Message),
    Prefix = proplists:get_value(prefix, Message),
    ObjectKey = proplists:get_value(object_key, Message),
    TotalBytes = proplists:get_value(total_bytes, Message),
    ContentType = get_content_type(ObjectKey),
    case ContentType of
	undefined -> ok;
	_ ->
	    case (TotalBytes =< ?MAXIMUM_FILE_SIZE) of
		true ->
		    index(BucketId, Prefix, ObjectKey, ContentType);
		false -> ok
	    end
    end,
    {noreply, State}.

handle_info(Info, State) ->
    ?WARNING("unexpected info request ~p~n", [Info]),
    {noreply, State}.

handle_call(Req, _, S) ->
    ?WARNING("unexpected call request ~p~n", [Req]),
    {noreply, S}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_, S, _) ->
    {ok, S}.

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
terminate(_Reason, _S) ->
    ok.

-spec get_content_type(string()) -> boolean().

get_content_type(ObjectKey) when erlang:is_list(ObjectKey) ->
    case filename:extension(ObjectKey) of
	[] -> undefined;
	Extension ->
	    LookupKey = string:substr(Extension, 2),
	    case proplists:get_value(LookupKey, ?SOLR_MIME_TYPES) of
		undefined -> undefined;
		ContentType -> ContentType
	    end
    end.

%%
%% Retrieves file from object storage and submits it to Solr's extractor
%%
index(BucketId, Prefix, ObjectKey, ContentType) ->
    PrefixedObjectKey = utils:prefixed_object_key(Prefix, ObjectKey),
    EncodedPrefixedObjectKey = erlcloud_http:url_encode_loose(PrefixedObjectKey),
    UniqueId = lists:flatten(io_lib:format("~s/~s", [BucketId, EncodedPrefixedObjectKey])),
    ObjectURL = s3_api:get_object_url(BucketId, EncodedPrefixedObjectKey),
    Config0 = #api_config{},
    %% Download object from Riak CS
    Response = s3_api:request_httpc(ObjectURL, get, [{"content-type", "*/*"}], <<>>, Config0, []),
    case Response of
	{error, _} ->
	    {error, "Object not found"};
	{ok, {_Status, _Headers, RequestBody}} ->
	    Headers = [{"content-type", ContentType}],
	    %% Upload object to Solr
	    Config1 = #api_config{s3_proxy_host=undefined, s3_proxy_port=undefined},
	    Metadata = s3_api:get_object_metadata(BucketId, PrefixedObjectKey),
	    OrigName = 
		case erlcloud_http:url_encode(proplists:get_value("x-amz-meta-orig-filename", Metadata, ObjectKey)) of
		    undefined -> ObjectKey;
		    Name -> Name
		end,
	    SolrURL = lists:flatten(io_lib:format("http://127.0.0.1:~s~s/~s~s?wt=json&literal._yz_id=~s&literal.bucket_id=~s&literal.orig_name=~s&commit=true&resource.name=~s",
		[integer_to_list(?SOLR_PORT), ?SOLR_HOST_CONTEXT, ?SOLR_INDEX_NAME, "/update/extract", UniqueId, BucketId, OrigName, OrigName])),
	    case s3_api:request_httpc(SolrURL, post, Headers, RequestBody, Config1, []) of
		{ok, {_,_,ResponseBody}} ->
		    ?INFO("Solr response: ~p~n", [ResponseBody]);
		{error, {http_error, _, StatusLine,Body,_}} ->
		    ?INFO("Solr ~p: ~p~n", [StatusLine, Body]);
		_ ->
		    ?INFO("Solr request failed", [])
	    end
    end.
