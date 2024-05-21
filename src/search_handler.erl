%%
%% Provides basic interface to Solr.
%%
-module(search_handler).
-behavior(cowboy_handler).

-export([init/2, content_types_provided/2, to_json/2, allowed_methods/2,
	 is_authorized/2, forbidden/2]).

-include("riak.hrl").
-include("entities.hrl").
-include("log.hrl").

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

%% Returns Bucket Name, Prefix and Object Name
parse_url(RiakURL) ->
    FirstSlashOccurrence = string:chr(RiakURL, $/),
    LastSlashOccurrence = string:rchr(RiakURL, $/),
    BucketId = string:substr(RiakURL, 1, FirstSlashOccurrence-1),
    Prefix =
	case FirstSlashOccurrence =/= LastSlashOccurrence of
	    true ->
		string:substr(RiakURL, FirstSlashOccurrence+1, LastSlashOccurrence-FirstSlashOccurrence);
	    false ->
		undefined
	    end,
    ObjectKey = string:substr(RiakURL, LastSlashOccurrence+1),
    [{bucket_id, BucketId}, {prefix, Prefix}, {object_key, ObjectKey}].

get_riak_object(RiakURL) ->
    URLInfo = parse_url(RiakURL),
    BucketId = proplists:get_value(bucket_id, URLInfo),
    Prefix = proplists:get_value(prefix, URLInfo),
    ObjectKey = proplists:get_value(object_key, URLInfo),

    PrefixedObjectKey = utils:prefixed_object_key(Prefix, ObjectKey),
    Metadata = riak_api:get_object_metadata(BucketId, PrefixedObjectKey),

    OrigName =
	case proplists:get_value("x-amz-meta-orig-filename", Metadata, ObjectKey) of
	    undefined -> ObjectKey;
	    Name -> utils:unhex(erlang:list_to_binary(Name))
	end,
    Bytes =
	case proplists:get_value(content_length, Metadata, undefined) of
	    undefined -> 0;
	    Value -> utils:to_integer(Value)
	end,
    ContentType = proplists:get_value(content_type, Metadata, 0),
    Etag = proplists:get_value(etag, Metadata, ""),
    Md5 = string:strip(Etag, both, $"),

    [{object_key, ObjectKey},
     {orig_name,  unicode:characters_to_list(list_to_binary(OrigName))},
     {bytes, Bytes},
     {content_type, ContentType},
     {md5, Md5}].

content_types_provided(Req, State) ->
    {[
	{{<<"application">>, <<"json">>, []}, to_json}
    ], Req, State}.


search(BucketId, Term) ->
    search(BucketId, undefined, Term).
%% todo: take into account prefix and bucket name
search(_BucketId, _Prefix, Term0) ->
    Term1 = erlcloud_http:url_encode_loose(Term0),
    %% Solr do not scale the same way as Riak CS, -- search query should be made to external URL
    SolrURL = lists:flatten(io_lib:format("http://127.0.0.1:8093/internal_solr/binary_objects/select?q=~s&wt=json&indent=false", [Term1])),
    Config = #riak_api_config{s3_proxy_host=undefined, s3_proxy_port=undefined},
    case riak_api:request_httpc(SolrURL, get, [], <<>>, Config) of
	{ok, {_,_,ResponseBody}} ->
	    SearchResult = proplists:get_value(<<"response">>, jsx:decode(ResponseBody)),
	    RiakURLs = [binary_to_list(proplists:get_value(<<"_yz_id">>, I, <<"">>)) || I <- proplists:get_value(<<"docs">>, SearchResult)],
	    [get_riak_object(URL) || URL <- RiakURLs,
		utils:is_hidden_object(URL) =/= true];
	{error, {http_error, _, StatusLine,Body,_}} ->
	    lager:warning("[search_handler] Riak ~p: ~p~n", [StatusLine, Body]),
	    [];
	_ ->
	    lager:warning("[search_handler] Riak request failed", []),
	    []
    end.

to_json(Req0, State) ->
    BucketId = proplists:get_value(bucket_id, State),
    ParsedQs = cowboy_req:parse_qs(Req0),
    case proplists:get_value(<<"q">>, ParsedQs) of
	undefined -> {[], Req0, State};
	Term ->
	    RiakResponse =
		case proplists:get_value(<<"prefix">>, ParsedQs) of
		    undefined -> search(BucketId, Term);
		    Prefix0 ->
			case list_handler:validate_prefix(BucketId, Prefix0) of
			    {error, _} -> [];
			    Prefix1 -> search(BucketId, Prefix1, Term)
			end
		end,
	    Output = jsx:encode([
		{list, RiakResponse},
		{dirs, []}
	    ]),
	    {Output, Req0, State}
    end.

%%
%% Called first
%%
allowed_methods(Req, State) ->
    {[<<"GET">>], Req, State}.

%%
%% Checks if provided token is correct.
%% ( called after 'allowed_methods()' )
%%
is_authorized(Req0, _State) ->
    case utils:get_token(Req0) of
	undefined -> js_handler:unauthorized(Req0, 28, stop);
	Token -> login_handler:get_user_or_error(Req0, Token)
    end.

%%
%% Checks if user has access
%% ( called after 'is_authorized()' )
%%
forbidden(Req0, User) ->
    BucketId =
	case cowboy_req:binding(bucket_id, Req0) of
	    undefined -> undefined;
	    BV -> erlang:binary_to_list(BV)
	end,
    case utils:is_valid_bucket_id(BucketId, User#user.tenant_id) of
	true ->
	    UserBelongsToGroup = lists:any(fun(Group) ->
		utils:is_bucket_belongs_to_group(BucketId, User#user.tenant_id, Group#group.id) end,
		User#user.groups),
	    case UserBelongsToGroup orelse utils:is_bucket_belongs_to_tenant(BucketId, User#user.tenant_id) of
		false ->
		    PUser = admin_users_handler:user_to_proplist(User),
		    js_handler:forbidden(Req0, 37, proplists:get_value(groups, PUser), stop);
		true -> {false, Req0, [{user, User}, {bucket_id, BucketId}]}
	    end;
	false -> js_handler:forbidden(Req0, 7, stop)
    end.
