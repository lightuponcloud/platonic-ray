%%
%% Allows to copy objects and pseudo-directories.
%%
-module(copy_handler).
-behavior(cowboy_handler).

-export([init/2, content_types_provided/2, content_types_accepted/2,
	 to_json/2, allowed_methods/2, is_authorized/2, forbidden/2,
	 handle_post/2, copy_forbidden/2, validate_copy_parameters/1,
	 validate_dst_prefix/1]).

-include("riak.hrl").
-include("entities.hrl").
-include("action_log.hrl").

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

%%
%% Returns callback 'handle_post()'
%% ( called after 'resource_exists()' )
%%
content_types_accepted(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, handle_post}], Req, State}.

%%
%% Returns callback 'to_json()'
%% ( called after 'forbidden()' )
%%
content_types_provided(Req, State) ->
    {[
	{{<<"application">>, <<"json">>, []}, to_json}
    ], Req, State}.

%%
%% Checks if source object exists.
%%
-spec validate_src_object_key(list(), list(), list()) -> tuple()|{error, integer()}.

validate_src_object_key(SrcPrefix, DstPrefix, ObjectKey0)
	when erlang:is_list(SrcPrefix) orelse SrcPrefix =:= undefined,
	     erlang:is_list(DstPrefix) orelse DstPrefix =:= undefined, erlang:is_tuple(ObjectKey0) ->
    case size(ObjectKey0) of
	2 ->
	    ObjectKey1 = element(1, ObjectKey0),
	    DstName = element(2, ObjectKey0),
	    case utils:ends_with(ObjectKey1, <<"/">>) of
		true ->
		    %% Check if valid hex prefix provided
		    try utils:unhex(ObjectKey1) of
			_Value -> validate_dst_name(DstPrefix, ObjectKey1, DstName)
		    catch error:badarg ->
			{error, 14}
		    end;
		false -> validate_dst_name(DstPrefix, ObjectKey1, DstName)
	    end;
	_ -> {error, 15}
    end;
validate_src_object_key(_SrcPrefix, _DstPrefix, _ObjectKey) -> {error, 15}.

validate_dst_name(_DstPrefix, null, _DstName) -> {error, 30};
validate_dst_name(_DstPrefix, <<>>, _DstName) -> {error, 30};
validate_dst_name(_DstPrefix, ObjectKey0, <<>>) -> {ObjectKey0, undefined};
validate_dst_name(_DstPrefix, ObjectKey0, null) -> {ObjectKey0, undefined};
validate_dst_name(DstPrefix, ObjectKey0, DstName0) ->
    case utils:trim_spaces(ObjectKey0) of
	<<>> -> {error, 30};
	_ ->
	    %% In case destination name ends with "/", try to 'unhex'.
	    %% if not hex, remove trailing "/"
	    DstName1 =
		case utils:ends_with(DstName0, <<"/">>) of
		    false -> DstName0;
		    true ->
			try utils:unhex(DstName0) of
			    Value -> Value
			catch error:badarg ->
			    Size0 = byte_size(DstName0)-1,
			    <<DstName2:Size0/binary, _/binary>> = DstName0,
			    DstName2
			end
		end,
	    case utils:is_valid_object_key(DstName1) of
		false -> {error, 12};
		true ->
		    %% Someone could have changed default real object prefix to hex value
		    case utils:starts_with(DstName1, erlang:list_to_binary(?RIAK_REAL_OBJECT_PREFIX))
			    andalso DstPrefix =:= undefined of
			true -> {error, 10};
			false -> {ObjectKey0, DstName1}
		    end
	    end
    end.

%%
%% Checks if every key in src_object_keys exists and ther'a no duplicates
%%
validate_src_object_keys(_SrcPrefix, _DstPrefix, null) -> {error, 15};
validate_src_object_keys(_SrcPrefix, _DstPrefix, undefined) -> {error, 15};
validate_src_object_keys(_SrcPrefix, _DstPrefix, <<>>) -> {error, 15};
validate_src_object_keys(_SrcPrefix, _DstPrefix, []) -> {error, 15};
validate_src_object_keys(SrcPrefix, DstPrefix, SrcObjectMap0)
	when erlang:is_list(SrcObjectMap0), erlang:is_list(SrcPrefix) orelse SrcPrefix =:= undefined,
	     erlang:is_list(DstPrefix) orelse DstPrefix =:= undefined ->
    SrcObjectMap1 = [validate_src_object_key(SrcPrefix, DstPrefix, I) || I <- SrcObjectMap0],
    Error = lists:keyfind(error, 1, SrcObjectMap1),
    case Error of
	{error, Number} -> {error, Number};
	_ ->
	    case utils:has_duplicates(SrcObjectMap1) of
		true -> {error, 31};
		false ->
		    %% Check if destination names list do not have duplicates,
		    %% as that would copy objects over each other
		    LowecaseList = [light_unicode:to_lower(unicode:characters_to_list(element(2, I)))
				    || I <- SrcObjectMap1],
		    UniqSet = sets:to_list(sets:from_list(LowecaseList)),
		    case length(UniqSet) =:= length(SrcObjectMap1) of
			true -> SrcObjectMap1;  %% No duplicates
			false -> {error, 31}
		    end
	    end
    end.

-spec validate_copy_parameters(proplist()) -> any().

validate_copy_parameters(State0) ->
    SrcBucketId = proplists:get_value(src_bucket_id, State0),
    DstBucketId = proplists:get_value(dst_bucket_id, State0),
    SrcPrefix0 = proplists:get_value(src_prefix, State0),
    DstPrefix0 = proplists:get_value(dst_prefix, State0),
    SrcObjectKeys0 = proplists:get_value(src_object_keys, State0),

    SrcPrefix1 = list_handler:validate_prefix(SrcBucketId, SrcPrefix0),
    DstPrefix1 = list_handler:validate_prefix(DstBucketId, DstPrefix0),
    Error = lists:keyfind(error, 1, [SrcPrefix1, DstPrefix1]),
    case Error of
	{error, Number0} -> {error, Number0};
	_ ->
	    SrcObjectKeys1 = validate_src_object_keys(SrcPrefix1, DstPrefix1, SrcObjectKeys0),
	    case SrcObjectKeys1 of
		{error, Number1} -> {error, Number1};
		_ ->
		    %% The destination directory might be subdirectory of the source directory.
		    SrcObjectKeys2 = lists:filter(
			fun(N) ->
			    SrcPrefix2 =
				case SrcPrefix1 of
				    undefined -> undefined;
				    _ -> erlang:list_to_binary(SrcPrefix1)
				end,
			    PN0 = utils:prefixed_object_key(SrcPrefix2, element(1, N)),
			    case utils:starts_with(DstPrefix1, PN0) of
				false -> true;
				true -> false
			    end
			end, SrcObjectKeys1),
		    case length(SrcObjectKeys2) =:= 0 orelse (DstPrefix1 =:= SrcPrefix1 andalso length(SrcObjectKeys0) > 1) of
			true -> {error, 13};
			false ->
			    User = proplists:get_value(user, State0),
			    [{src_bucket_id, SrcBucketId},
			     {dst_bucket_id, DstBucketId},
			     {src_prefix, SrcPrefix1},
			     {dst_prefix, DstPrefix1},
			     {src_object_keys, SrcObjectKeys2},
			     {user, User}]
		    end
	    end
    end.

%%
%% Validates POST request and sends request to Riak CS to copy object or pseudo-directory
%%
handle_post(Req0, State0) ->
    case cowboy_req:method(Req0) of
	<<"POST">> ->
	    case validate_copy_parameters(State0) of
		{error, Number} -> js_handler:bad_request(Req0, Number);
		State1 -> copy(Req0, State1)
	    end;
	_ -> js_handler:bad_request(Req0, 16)
    end.

validate_dst_prefix(undefined) -> undefined;
validate_dst_prefix(null) -> undefined;
validate_dst_prefix(<<>>) -> undefined;
validate_dst_prefix(Prefix) when erlang:is_list(Prefix) -> Prefix.


copy(Req0, State) ->
    SrcBucketId = proplists:get_value(src_bucket_id, State),
    SrcPrefix = proplists:get_value(src_prefix, State),
    SrcObjectKeys = proplists:get_value(src_object_keys, State),
    DstBucketId = proplists:get_value(dst_bucket_id, State),
    DstPrefix =
	case proplists:get_value(dst_prefix, State) of
	    undefined -> undefined;
	    P -> validate_dst_prefix(P)
	end,
    User = proplists:get_value(user, State),

    copy_server:copy(SrcBucketId, DstBucketId, SrcPrefix, DstPrefix, SrcObjectKeys, User),

    Req1 = cowboy_req:reply(200, #{
	<<"content-type">> => <<"application/json">>
    }, <<"{\"status\": \"ok\"}">>, Req0),
    {stop, Req1, []}.

%%
%% Serializes response to json
%%
to_json(Req0, State) ->
    {<<"{\"status\": \"ok\"}">>, Req0, State}.

%%
%% Called first
%%
allowed_methods(Req, State) ->
    {[<<"POST">>], Req, State}.

%%
%% Checks if provided token is correct.
%% ( called after 'allowed_methods()' )
%%
is_authorized(Req0, _State) ->
    case utils:get_token(Req0) of
	undefined -> js_handler:unauthorized(Req0, 28);
	Token -> login_handler:get_user_or_error(Req0, Token)
    end.

copy_forbidden(Req0, User0) ->
    SrcBucketId =
	case cowboy_req:binding(src_bucket_id, Req0) of
	    undefined -> undefined;
	    BV -> erlang:binary_to_list(BV)
	end,
    TenantId = User0#user.tenant_id,
    IsCopyAllowed =
	case utils:is_valid_bucket_id(SrcBucketId, TenantId) of
	    false -> false;
	    true ->
		UserBelongsToSrcGroup = lists:any(fun(Group) ->
			utils:is_bucket_belongs_to_group(SrcBucketId, TenantId, Group#group.id) end,
			User0#user.groups),
		case UserBelongsToSrcGroup of
		    true -> true;
		    false ->
			IsSrcRestricted = utils:is_restricted_bucket_id(SrcBucketId),
			IsSrcPublic = utils:is_public_bucket_id(SrcBucketId),
			case IsSrcRestricted orelse IsSrcPublic of
			    true -> User0#user.staff;
			    false -> false
			end
		end
	end,
    case IsCopyAllowed of
	true ->
	    {ok, Body, Req1} = cowboy_req:read_body(Req0),
	    case jsx:is_json(Body) of
		{error, badarg} -> js_handler:bad_request(Req1, 21);
		false -> js_handler:bad_request(Req1, 21);
		true ->
		    FieldValues = jsx:decode(Body),
		    DstBucketId0 =
			case proplists:get_value(<<"dst_bucket_id">>, FieldValues) of
			    undefined -> undefined;
			    DstBucketId1 -> unicode:characters_to_list(DstBucketId1)
			end,
		    TenantId = User0#user.tenant_id,
		    DstBucketCanBeModified =
			case utils:is_valid_bucket_id(DstBucketId0, TenantId) of
			    false -> false;
			    true ->
				UserBelongsToDstGroup = lists:any(fun(Group) ->
				    utils:is_bucket_belongs_to_group(DstBucketId0, TenantId, Group#group.id) end,
				    User0#user.groups),
				case UserBelongsToDstGroup of
				    true -> true;
				    false ->
					IsDstRestricted = utils:is_restricted_bucket_id(DstBucketId0),
					IsDstPublic = utils:is_public_bucket_id(DstBucketId0),
					case IsDstRestricted orelse IsDstPublic of
					    true -> User0#user.staff;  %% Only staff user can copy to public bucket
					    false -> false
					end
				end
			end,
		    case DstBucketCanBeModified of
			false -> js_handler:forbidden(Req1, 26, stop);
			true -> {false, Req1, [
				    {user, User0},
				    {src_bucket_id, SrcBucketId},
				    {dst_bucket_id, DstBucketId0},
				    {src_prefix, proplists:get_value(<<"src_prefix">>, FieldValues)},
				    {dst_prefix, proplists:get_value(<<"dst_prefix">>, FieldValues)},
				    {src_object_keys, proplists:get_value(<<"src_object_keys">>, FieldValues)}
				]}
		    end
	    end;
	false ->
	    User1 = admin_users_handler:user_to_proplist(User0),
	    js_handler:forbidden(Req0, 27, proplists:get_value(groups, User1), stop)
    end.

%%
%% Checks if user has access
%% - To source bucket
%% - To destination bucket
%%
%% ( called after 'is_authorized()' )
%%
forbidden(Req0, State) ->
    copy_forbidden(Req0, State).
