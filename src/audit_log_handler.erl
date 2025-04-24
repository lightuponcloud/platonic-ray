%%
%% Retrieves logged actions from S3.
%%
-module(audit_log_handler).
-behavior(cowboy_handler).

-export([init/2, content_types_provided/2, to_json/2, allowed_methods/2,
	 forbidden/2, resource_exists/2, previously_existed/2]).

-include("storage.hrl").
-include("entities.hrl").

%% Filter specification
-record(filter, {
    year :: undefined | integer(), % e.g., 2025
    month :: undefined | integer(), % e.g., 4
    day :: undefined | integer() % e.g., 24
}).


init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

%%
%% Called first
%%
allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>], Req, State}.


content_types_provided(Req, State) ->
    {[
	{{<<"application">>, <<"json">>, '*'}, to_json}
    ], Req, State}.

validate_operation_name(OpName) ->
    case OpName of
        <<"upload">> -> upload;
        <<"download">> -> download;
        <<"delete">> -> delete;
        <<"undelete">> -> undelete;
        <<"copy">> -> copy;
        <<"move">> -> move;
        <<"mkdir">> -> mkdir;
        <<"rename">> -> rename;
        <<"restored">> -> restored;
	[] -> undefined;
	<<>> -> undefined;
	null -> undefined;
	undefined -> undefined;
        _ -> {error, 41}
    end.


validate_date(Year, Month, Day) ->
    case {validate_year(Year), validate_month(Month), validate_day(Day)} of
        {{ok, ValidYear}, {ok, ValidMonth}, {ok, ValidDay}} ->
            {ValidYear, ValidMonth, ValidDay};
        {{error, Reason}, _, _} ->
            {error, Reason};
        {_, {error, Reason}, _} ->
            {error, Reason};
        {_, _, {error, Reason}} ->
            {error, Reason}
    end.

validate_year(undefined) -> {ok, undefined};
validate_year(null) -> {ok, undefined};
validate_year(<<>>) -> {ok, undefined};
validate_year(Year)  ->
    case utils:to_ingeger(Year) of
	Y when Y >= 1970 andalso Y =< 9999 -> Y;
	_ -> {error, 56}
    end;
validate_year(_) -> {error, 56}.

validate_month(undefined) -> {ok, undefined};
validate_month(null) -> {ok, undefined};
validate_month(<<>>) -> {ok, undefined};
validate_month(Month) ->
    case utils:to_ingeger(Month) of
	M when M >= 1 andalso M =< 12 -> M;
	_ -> {error, 54}
    end;
validate_month(_) -> {error, 54}.

validate_day(undefined) -> {ok, undefined};
validate_day(null) -> {ok, undefined};
validate_day(<<>>) -> {ok, undefined};
validate_day(Day) ->
    case utils:to_ingeger(Day) of
	D when D >= 1 andalso D =< 31 -> D;
	_ -> {error, 55}
    end;
validate_day(_) -> {error, 55}.

%%
%% Returns list of actions in pseudo-directory. If object_key specified, returns object history.
%%
to_json(Req0, State) ->
    BucketId = proplists:get_value(bucket_id, State),
    Prefix = list_handler:validate_prefix(BucketId, proplists:get_value(prefix, State)),
    Qs = proplists:get_value(parsed_qs, State),
    OperationName = validate_operation_name(proplists:get_value(<<"operation">>, Qs)),
    {Year, Month, Day} = validate_date(
	proplists:get_value(<<"year">>, Qs, undefined),
	proplists:get_value(<<"month">>, Qs, undefined),
	proplists:get_value(<<"day">>, Qs, undefined)
    ),

    case lists:keyfind(error, 1, [Prefix, OperationName, Year, Month, Day]) of
	{error, Number0} -> js_handler:bad_request(Req1, Number0);
	false ->
	    Bits = string:tokens(BucketId, "-"),
	    TenantId = string:to_lower(lists:nth(2, Bits)),
	    RealPrefix = io_lib:format("~s/~s/buckets/~s/~4.10.0B/~2.10.0B/~2.10.0B_~s.jsonl.gz",
				       [?AUDIT_LOG_PREFIX, TenantId]),
	    Filters = #s3_fetch:filter{
		bucket_id = BucketId,
		year = Year,
		month = Month,
		day = Day
	    },
	    stream_logs(Req0, BucketId, Prefix, Filters, OperationName)
    end.


    case s3_api:get_object(?AUDIT_LOG_PREFIX, LogPath) of
	{error, Reason} ->
	    lager:error("[admin_tenants_handler] get_object error ~p/~p: ~p",
			[?SECURITY_BUCKET_NAME, PrefixedTenantId, Reason]),
	    not_found;
	not_found -> not_found;
	Response ->
	    %% TODO
    end.

% Filter objects by date and bucket_id
filter_objects(Objects, Filters) ->
    lists:filter(fun(Object) -> matches_filters(Object, Filters) end, Objects).

% Check if an object matches the filters
matches_filters(ObjectKey, #filter{year = FY, month = FM, day = FD}) ->
    case parse_key(ObjectKey) of
        {ok, Year, Month, Day} -> matches_date(Year, Month, Day, FY, FM, FD);
        error -> false
    end.

%% Parse object key to extract date
parse_key(Key) ->
    Filename = filename:basename(Key),
    case binary:split(Filename, <<"_">>) of
        [DatePart, _UUID] ->
            case binary:split(DatePart, <<"/">>, [global]) of
                [Y, M, D] ->
                    try
                        Year = binary_to_integer(Y),
                        Month = binary_to_integer(M),
                        Day = binary_to_integer(D),
                        {ok, Year, Month, Day}
                    catch
                        _:_ -> error
                    end;
                _ -> error
            end;
        _ -> error
    end.

%% Match date filters (undefined means no filter)
matches_date(Year, Month, Day, FY, FM, FD) ->
    (FY =:= undefined orelse FY =:= Year) andalso
    (FM =:= undefined orelse FM =:= Month) andalso
    (FD =:= undefined orelse FD =:= Day).

%%
%% Downloads JSONL logs and streams them to client after filtering.
%%
stream_logs(Req0, BucketId0, Prefix, Filters, OperationName) when OperationName =:= undefined ->
    BucketId1 = utils:to_binary(BucketId0),
    ContentDisposition = << <<"attachment;filename=\"">>/binary, BucketId1/binary, <<"\"">>/binary >>,
    Headers0 = #{
	<<"content-type">> => << "application/json" >>,
	<<"content-disposition">> => ContentDisposition
    },
    Req1 = cowboy_req:stream_reply(200, Headers0, Req0),

    LogPath = io_lib:format("~s/buckets/~s", [?AUDIT_LOG_PREFIX, utils:prefixed_object_key(BucketId0, Prefix)]),
    List0 = s3_api:recursively_list_pseudo_dir(?SECURITY_BUCKET_NAME, LogPath),
    FilteredObjects = filter_objects(List0, Filters),
    lists:foreach(
	fun(ObjectKey) ->
	    case s3_api:get_object(BucketId0, ObjectKey, stream) of
		not_found ->
		    %% Object could have disappeared
		    Req2 = cowboy_req:set_resp_body(<<>>, Req1),
		    {ok, Req2, []};
		{ok, RequestId} ->
		    receive
			{http, {RequestId, stream_start, _Headers, Pid}} ->
			    version_handler:receive_streamed_body(Req1, RequestId, Pid);
			{http, Msg} -> ?ERROR("[audit_log_handler] error starting stream: ~p", [Msg])
		    end,
		    {ok, Req1, []}
	    end
	end, FilteredObjects),

%%
%% Checks if provided token is correct.
%% ( called after 'allowed_methods()' )
%%
forbidden(Req0, _State) ->
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
    PresentedSignature =
	case proplists:get_value(<<"signature">>, ParsedQs) of
	    undefined -> undefined;
	    Signature -> unicode:characters_to_list(Signature)
	end,
    case download_handler:has_access(Req0, BucketId, Prefix, undefined, PresentedSignature) of
	{error, Number} -> js_handler:unauthorized(Req0, Number, stop);
	{BucketId, Prefix, _ObjectKey, User} ->
	    {false, Req0, [
		{bucket_id, BucketId},
		{prefix, Prefix},
		{parsed_qs, ParsedQs},
		{user, User}
	    ]}
    end.

%%
%% Validates request parameters
%% ( called after 'content_types_provided()' )
%%
resource_exists(Req0, State) ->
    {true, Req0, State}.

previously_existed(Req0, _State) ->
    {false, Req0, []}.
