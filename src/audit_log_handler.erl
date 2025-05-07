%%
%% Retrieves logged actions from S3.
%%
-module(audit_log_handler).
-behavior(cowboy_handler).

-export([init/2]).

-include("storage.hrl").
-include("entities.hrl").

%% Filter specification
-record(filter, {
    day :: undefined | integer(), % e.g., 24
    event_id :: undefined | list()
}).

%%
%% Returns list of actions in pseudo-directory. If object_key specified, returns object history.
%%
init(Req0, _Opts) ->
    T0 = utils:timestamp(), %% measure time of request
    cowboy_req:cast({set_options, #{idle_timeout => infinity}}, Req0),

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
		P = utils:join_binary_with_separator(lists:nthtail(1, PathInfo), <<"/">>),
		object_handler:validate_prefix(BucketId, P)
	end,
    OperationName = validate_operation_name(proplists:get_value(<<"operation">>, ParsedQs)),
    EventId =
	case proplists:get_value(<<"event_id">>, ParsedQs) of
	    undefined -> undefined;
	    GUID -> crypto_utils:validate_guid(GUID)
	end,
    {Year, Month, Day} = validate_date(
	proplists:get_value(<<"year">>, ParsedQs, undefined),
	proplists:get_value(<<"month">>, ParsedQs, undefined),
	proplists:get_value(<<"day">>, ParsedQs, undefined)
    ),
    case lists:keyfind(error, 1, [Prefix, OperationName, Year, Month, Day]) of
	{error, Number0} -> js_handler:bad_request(Req0, Number0);
	false ->
	    Bits = string:tokens(BucketId, "-"),
	    TenantId = string:to_lower(lists:nth(2, Bits)),
	    LogPrefix0 = [
		 ?AUDIT_LOG_PREFIX,
		 TenantId,
		 "buckets",
		 BucketId
	    ],
	    LogPrefix1 =
		case Year of
		    undefined -> utils:prefixed_object_key(LogPrefix0, Prefix);
		    _ ->
			case Month of
			    undefined ->
				utils:prefixed_object_key(LogPrefix0 ++ [Prefix], lists:flatten(io_lib:format("~4.10.0B", [Year])));
			    _ ->
				LogPrefix2 = lists:flatten(LogPrefix0 ++ [Prefix, io_lib:format("~4.10.0B", [Year])]),
				utils:prefixed_object_key(LogPrefix2, lists:flatten(io_lib:format("~2.10.0B", [Month])))
			end
		end,
	    Filters = #filter{
		day = Day,
		event_id = EventId
	    },
	    case utils:get_token(Req0) of
		undefined -> js_handler:unauthorized(Req0, 28, stop);
		_Token -> stream_logs(Req0, BucketId, LogPrefix1, Filters, OperationName, T0)
	    end
    end.


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
	<<"lock">> -> lock;
	<<"unlock">> -> unlock;
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
validate_year(Year) when is_binary(Year) ->
    case utils:to_ingeger(Year) of
	Y when Y >= 1970 andalso Y =< 9999 -> Y;
	_ -> {error, 56}
    end;
validate_year(_) -> {error, 56}.

validate_month(undefined) -> {ok, undefined};
validate_month(null) -> {ok, undefined};
validate_month(<<>>) -> {ok, undefined};
validate_month(Month) when is_binary(Month) ->
    case utils:to_ingeger(Month) of
	M when M >= 1 andalso M =< 12 -> M;
	_ -> {error, 54}
    end;
validate_month(_) -> {error, 54}.

validate_day(undefined) -> {ok, undefined};
validate_day(null) -> {ok, undefined};
validate_day(<<>>) -> {ok, undefined};
validate_day(Day) when is_binary(Day) ->
    case utils:to_ingeger(Day) of
	D when D >= 1 andalso D =< 31 -> D;
	_ -> {error, 55}
    end;
validate_day(_) -> {error, 55}.


% Check if an object matches the filters
matches_filters(ObjectKey, #filter{event_id = EventId, day = FD}) ->
    case parse_key(ObjectKey) of
	{ok, Day, GUID} -> (FD =:= undefined orelse FD =:= Day orelse GUID =:= EventId);
        error -> false
    end.

%% Parse object key to extract date
parse_key(Key) ->
    Filename = filename:rootname(filename:rootname(filename:basename(Key))),
    case string:tokens(Filename, "_") of
        [Day, EventId] ->
            try
                {ok, utils:to_integer(Day), EventId}
            catch
                _:_ -> error
            end;
        _ -> error
    end.

%%
%% Downloads JSONL logs and streams them to client after filtering.
%%
stream_logs(Req0, BucketId0, Prefix, Filters, OperationName, T0) when OperationName =:= undefined ->
    BucketId1 = utils:to_binary(BucketId0),
    ContentDisposition = << <<"attachment;filename=\"">>/binary, BucketId1/binary, <<".jsonl\"">>/binary >>,
    Headers0 = #{
	<<"content-type">> => << "application/json" >>,
	<<"content-disposition">> => ContentDisposition,
	<<"start-time">> => io_lib:format("~.2f", [utils:to_float(T0)/1000])
    },
    Req1 = cowboy_req:stream_reply(200, Headers0, Req0),
    List0 = s3_api:recursively_list_pseudo_dir(?SECURITY_BUCKET_NAME, Prefix),
    FilteredObjects =
	lists:filter(fun(I) -> matches_filters(I, Filters) end, List0),
    lists:foreach(
	fun(ObjectKey) ->
	    case s3_api:get_object(?SECURITY_BUCKET_NAME, ObjectKey) of
		{error, _Reason} -> ok;
		not_found -> ok;
		Response ->
		    try
			BinBodyPart = audit_log:decompress_data(proplists:get_value(content, Response)),
			cowboy_req:stream_body(BinBodyPart, nofin, Req1)
		    catch
			_:Reason ->
			    lager:error("[audit_log_handler] failed to decompress ~p/~p: ~p",
					[?SECURITY_BUCKET_NAME, ObjectKey, Reason])
		    end
	    end
	end, FilteredObjects),

    cowboy_req:stream_body(<<>>, fin, Req1),
    {ok, Req1, []}.
