%%
%% This handler allows to do the following
%%  - to list users
%%  - to create user
%%  - to edit user
%%
-module(admin_users_handler).
-behavior(cowboy_handler).

%% Cowboy callbacks
-export([init/2, content_types_accepted/2, content_types_provided/2,
    allowed_methods/2, forbidden/2, patch_resource/2, to_json/2, to_html/2,
    resource_exists/2, handle_post/2, delete_resource/2, delete_completed/2]).

%% Other methods
-export([get_full_users_list/0, get_user/1, edit_user/2, parse_user/1,
	 user_to_proplist/1, user_from_state/1]).

-include_lib("xmerl/include/xmerl.hrl").
-include("general.hrl").
-include("storage.hrl").
-include("entities.hrl").

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

%%
%% Called first
%%
allowed_methods(Req, State) ->
    {[<<"GET">>, <<"PATCH">>, <<"POST">>, <<"DELETE">>], Req, State}.

%%
%% Returns callback, corresponding to method
%%
%% (called after 'resource_exists()' )
%%
%% Only called for POST and PATCH methods.
%%
content_types_accepted(Req, State) ->
    case cowboy_req:method(Req) of
	<<"PATCH">> ->
	    {[{{<<"application">>, <<"json">>, []}, patch_resource}], Req, State};
	<<"POST">> ->
	    {[{{<<"application">>, <<"json">>, []}, handle_post}], Req, State}
    end.

%%
%% Returns callback 'to_json()'
%% ( called after 'forbidden()' )
%%
%% Only called for GET method.
%%
content_types_provided(Req, State) ->
    {[
	{{<<"application">>, <<"json">>, '*'}, to_json},
	{{<<"text">>, <<"html">>, '*'}, to_html}
    ], Req, State}.

%%
%% Transforms User record to proplist and adds
%% attibutes that are used in templates.
%%
-spec user_to_proplist(user()) -> proplist().

user_to_proplist(User) ->
    Tel =
	case User#user.tel of
	    undefined -> undefined;
	    V -> unicode:characters_to_binary(utils:unhex(erlang:list_to_binary(V)))
	end,
    [
	{id, erlang:list_to_binary(User#user.id)},
	{name, unicode:characters_to_binary(utils:unhex(erlang:list_to_binary(User#user.name)))},
	{tenant_id, erlang:list_to_binary(User#user.tenant_id)},
	{tenant_name, unicode:characters_to_binary(utils:unhex(erlang:list_to_binary(User#user.tenant_name)))},
	{tenant_enabled, utils:to_binary(User#user.tenant_enabled)},
	{login, unicode:characters_to_binary(utils:unhex(erlang:list_to_binary(User#user.login)))},
	{tel, Tel},
	{enabled, utils:to_binary(User#user.enabled)},
	{staff, utils:to_binary(User#user.staff)},
	{groups, [
	    [{id, erlang:list_to_binary(G#group.id)},
	     {name, unicode:characters_to_binary(utils:unhex(erlang:list_to_binary(G#group.name)))},
	     {available_bytes, -1},  %% TODO: to store and display used and available bytes
	     {bucket_id, erlang:list_to_binary(lists:concat([?BACKEND_PREFIX, "-", User#user.tenant_id, "-", G#group.id, "-", ?RESTRICTED_BUCKET_SUFFIX]))},
	     {bucket_suffix, erlang:list_to_binary(?RESTRICTED_BUCKET_SUFFIX)}
	    ] || G <- User#user.groups]}
    ].

%%
%% Returns JSON list of users
%%
to_json(Req0, State) ->
    case proplists:get_value(session_id, State) of
	undefined ->
	    %% Token should have been specified
	    User = proplists:get_value(user, State),
	    case User#user.staff of
		true ->
		    case proplists:get_value(path_user, State) of
			undefined ->
			    %% Return list of users
			    {jsx:encode(
				[user_to_proplist(U) || U <- get_full_users_list(), U =/= not_found]),
				Req0, State};
			PathUser0 ->
			    %% Return only requested one
			    PathUser1 = user_to_proplist(PathUser0),
			    {jsx:encode(PathUser1), Req0, State}
		    end;
		false ->
		    %% Only staff is allowed to access this API endpoint
		    Req1 = cowboy_req:reply(403, #{
			<<"content-type">> => <<"application/json">>
			}, Req0),
		    {stop, Req1, []}
	    end;
	_ ->
	    %% REST API accepts only bearer Tokens
	    Req1 = cowboy_req:reply(403, #{
		<<"content-type">> => <<"application/json">>
		}, Req0),
	    {stop, Req1, []}
    end.

to_html(Req0, State0) ->
    Settings0 = #general_settings{},
    StaticRoot =
	case os:getenv("STATIC_BASE_URL") of
	    false ->  Settings0#general_settings.static_root;
	    V -> V
	end,
    Settings1 = Settings0#general_settings{static_root = StaticRoot},
    SessionId0 = proplists:get_value(session_id, State0),
    SessionId1 =
	case SessionId0 of
	    [H|_] -> H;
	    _ -> SessionId0
	end,
    case login_handler:check_session_id(SessionId1) of
	false -> js_handler:redirect_to_login(Req0);
	{error, Code} -> js_handler:incorrect_configuration(Req0, Code);
	User ->
	    case User#user.staff of
		false -> js_handler:redirect_to_login(Req0);
		true ->
		    PathTenant0 = proplists:get_value(path_tenant, State0),
		    PathTenant1 =
			case PathTenant0 of
			    undefined -> undefined;
			    _ -> admin_tenants_handler:tenant_to_proplist(PathTenant0)
			end,
		    Users = get_full_users_list(PathTenant0),
		    UsersList = [user_to_proplist(U) || U <- Users, U =/= not_found], %% tenant might be deleted

		    TenantIDs = sets:to_list(sets:from_list(
			[erlang:binary_to_list(proplists:get_value(tenant_id, U)) || U <- UsersList])),
		    Tenants = admin_tenants_handler:get_tenants_by_ids(TenantIDs),

		    State1 = user_to_proplist(User),
		    {ok, Body} = admin_users_dtl:render([
			{brand_name, Settings1#general_settings.brand_name},
			{static_root, Settings1#general_settings.static_root},
			{root_path, Settings1#general_settings.root_path},
			{token, SessionId1},
			{users_list, UsersList},
			{users_count, length(UsersList)},
			{path_tenant, PathTenant1},
			{tenants, Tenants}
		    ] ++ State1),
		    {Body, Req0, []}
	    end
    end.

parse_user(RootElement) ->
    UserId = erlcloud_xml:get_text("/user/record/id", RootElement),
    UserName = erlcloud_xml:get_text("/user/record/name", RootElement),
    TenantId = erlcloud_xml:get_text("/user/record/tenant_id", RootElement),
    TenantName = erlcloud_xml:get_text("/user/record/tenant_name", RootElement),
    IsEnabled = erlcloud_xml:get_bool("/user/record/enabled", RootElement),
    IsStaff = erlcloud_xml:get_bool("/user/record/staff", RootElement),
    Login = erlcloud_xml:get_text("/user/record/login", RootElement),
    Tel = erlcloud_xml:get_text("/user/record/tel", RootElement),
    HashedPassword = erlcloud_xml:get_text("/user/record/password", RootElement),
    HashType = erlcloud_xml:get_text("/user/record/hash_type", RootElement),
    GetGroupAttrs = fun(N) ->
	#group{id = erlcloud_xml:get_text("/group/id", N),
	    name = erlcloud_xml:get_text("/group/name", N)} end,
    Groups = [GetGroupAttrs(I) ||
	I <- xmerl_xpath:string("/user/record/groups/group", RootElement)],
    Salt = erlcloud_xml:get_text("/user/record/salt", RootElement),
    #user{
	id = UserId,
	name = UserName,
	tenant_id = TenantId,
	tenant_name = TenantName,
	login = Login,
	tel = Tel,
	password = HashedPassword,
	salt = Salt,
	hash_type = HashType,
	enabled = IsEnabled,
	staff = IsStaff,
	groups = Groups
    }.

%%
%% Returns user record.
%% Adds only those user groups to the user record that are defined in tenant.
%% Sets "enabled" if tenant and user are both enabled
%%
-spec get_user(string()) -> user()|not_found.

get_user(UserId) when erlang:is_list(UserId) ->
    PrefixedUserId = utils:prefixed_object_key(?USER_PREFIX, UserId),
    case s3_api:get_object(?SECURITY_BUCKET_NAME, PrefixedUserId) of
	{error, Reason0} ->
	    lager:error("[admin_users_handler] get_object failed: ~p/~p: ~p",
			[?SECURITY_BUCKET_NAME, PrefixedUserId, Reason0]),
	    throw("[admin_users_handler] get_object failed");
	not_found -> not_found;
	UserObject ->
	    XMLDocument0 = utils:to_list(proplists:get_value(content, UserObject)),
	    {RootElement0, _} = xmerl_scan:string(XMLDocument0),
            User0 = parse_user(RootElement0),
	    PrefixedTenantId = utils:prefixed_object_key(?TENANT_PREFIX, User0#user.tenant_id),
	    case s3_api:get_object(?SECURITY_BUCKET_NAME, PrefixedTenantId) of
		{error, Reason1} ->
		    lager:error("[admin_users_handler] get_object failed: ~p/~p: ~p",
				[?SECURITY_BUCKET_NAME, PrefixedTenantId, Reason1]),
		    throw("[admin_users_handler] get_object failed");
		not_found -> not_found;
		TenantObject ->
		    XMLDocument1 = utils:to_list(proplists:get_value(content, TenantObject)),
		    {RootElement1, _} = xmerl_scan:string(XMLDocument1),
		    Tenant = admin_tenants_handler:parse_tenant(RootElement1),
		    IsEnabled =
			case Tenant#tenant.enabled andalso User0#user.enabled of
			    true -> true;
			    false -> false
			end,
		    User0#user{
			enabled = IsEnabled,
			tenant_enabled = Tenant#tenant.enabled,
			groups = [G || G <- User0#user.groups,
				  lists:member(G#group.id, [TG#group.id || TG <- Tenant#tenant.groups])]
		    }
	    end
    end.

get_full_users_list() ->
    get_full_users_list(undefined, [], undefined).

-spec get_full_users_list(tenant()|undefined) -> list().

get_full_users_list(Tenant) ->
    get_full_users_list(Tenant, [], undefined).

get_full_users_list(Tenant, UsersList0, Marker0) ->
    RiakResponse = s3_api:list_objects(?SECURITY_BUCKET_NAME, [{prefix, ?USER_PREFIX}, {marker, Marker0}]),
    case RiakResponse of
	not_found -> [];  %% bucket do not exist
	_ ->
	    Contents = proplists:get_value(contents, RiakResponse),
	    Marker1 = proplists:get_value(next_marker, RiakResponse),
	    %% Collect all the information about objects
	    UsersList1 = [get_user(filename:basename(proplists:get_value(key, R))) || R <- Contents],
	    UsersList2 =
		case Tenant of
		    undefined -> UsersList1;
		    _ -> [U || U <- UsersList1, U#user.tenant_id =:= Tenant#tenant.id]
		end,
	    case Marker1 of
		undefined -> UsersList0 ++ UsersList2;
		[] -> UsersList0 ++ UsersList2;
		NextMarker -> get_full_users_list(Tenant, UsersList0 ++ UsersList2, NextMarker)
	    end
    end.

%%
%% Checks if provided token is correct.
%% ( called after 'allowed_methods()' )
%%
forbidden(Req0, State) ->
    admin_tenants_handler:forbidden(Req0, State).

user_from_state(Req0) ->
    case cowboy_req:binding(user_id, Req0) of
	undefined -> undefined;
	UserId ->
	    case get_user(erlang:binary_to_list(UserId)) of
		not_found -> not_found;
		User -> User
	    end
    end.

%%
%% Validates tenant and user IDs, if they are specified
%% ( called after 'content_types_provided()' )
%%
resource_exists(Req0, State) ->
    case cowboy_req:binding(tenant_id, Req0) of
	undefined -> {true, Req0, State};
	TenantId0 ->
	    TenantId1 = erlang:binary_to_list(TenantId0),
	    case admin_tenants_handler:get_tenant(TenantId1) of
		not_found -> {false, Req0, []};
		Tenant ->
		    case user_from_state(Req0) of
			undefined -> {true, Req0, State ++ [{path_tenant, Tenant}]};
			not_found -> {false, Req0, []};
			User -> {true, Req0, State ++ [{path_tenant, Tenant}, {path_user, User}]}
		    end
	    end
    end.

%%
%% Users are stored using the following path
%% s3://security/users/user_id
%%
%% Usage example:
%%	User = #user{
%%		login = "if@example.com",
%%		name = "Іван Франко",
%%		tenant_id = Tenant#tenant.id,
%%		salt = PasswordSalt,
%%		password = HashedPassword,
%%		groups = [
%%			#group{
%%				name = "Письменники"
%%			}];
%%	}
%%	new_user(User).
%%
-spec new_user(any(), user()) -> any().

new_user(Req0, User0) ->
    PrefixedUserId = utils:prefixed_object_key(?USER_PREFIX, User0#user.id),
    case s3_api:head_object(?SECURITY_BUCKET_NAME, PrefixedUserId) of
	not_found ->
	    %% Create User
	    Timestamp = io_lib:format("~p", [utils:timestamp()]),
	    Groups = [{group, [
			    {id, [G#group.id]},
			    {name, [G#group.name]}
			]} || G <- User0#user.groups],
	    Tel =
		case User0#user.tel of
		    undefined -> "";
		    T -> T
		end,
	    User1 = {record, [
			{id, [User0#user.id]},
			{name, [User0#user.name]},
			{tenant_id, [User0#user.tenant_id]},
			{tenant_name, [User0#user.tenant_name]},
			{hash_type, [utils:to_list(User0#user.hash_type)]},
			{password, [utils:to_list(User0#user.password)]},
			{salt, [utils:to_list(User0#user.salt)]},
			{login, [User0#user.login]},
			{tel, [Tel]},
			{enabled, [utils:to_list(User0#user.enabled)]},
			{staff, [utils:to_list(User0#user.staff)]},
			{date_updated, Timestamp},
			{groups, Groups}
	    ]},
	    RootElement0 = #xmlElement{name=user, content=[User1]},
	    XMLDocument0 = xmerl:export_simple([RootElement0], xmerl_xml),
	    Response = s3_api:put_object(?SECURITY_BUCKET_NAME, ?USER_PREFIX, User0#user.id,
					   unicode:characters_to_binary(XMLDocument0)),
	    case Response of
		{error, Reason} ->
		    lager:error("[admin_users_handler] Can't put object ~p/~p/~p: ~p",
				[?SECURITY_BUCKET_NAME, ?USER_PREFIX, User0#user.id, Reason]),
		    js_handler:bad_request(Req0, "PUT failed");
		_ ->
		    ResponseBody = jsx:encode(user_to_proplist(User0)),
		    Req1 = cowboy_req:reply(200, #{
			<<"content-type">> => <<"application/json">>
		    }, ResponseBody, Req0),
		    {stop, Req1, []}
	    end;
	{error, Reason} ->
	    lager:error("[admin_users_handler] head_object failed ~p/~p: ~p",
			[?SECURITY_BUCKET_NAME, PrefixedUserId, Reason]),
	    Req1 = cowboy_req:reply(500, #{
		<<"content-type">> => <<"application/json">>
	    }, jsx:encode([{error, <<"Can't create user at the moment.">>}]), Req0),
	    {stop, Req1, []};
	_ ->
	    Req1 = cowboy_req:reply(400, #{
		<<"content-type">> => <<"application/json">>
	    }, jsx:encode([{error, <<"User exists.">>}]), Req0),
	    {stop, Req1, []}
    end.

%%
%% Allows changing user record
%% All fields are optional.
%%
-spec edit_user(any(), user()) -> any().

edit_user(Req0, User) ->
    Timestamp = io_lib:format("~p", [utils:timestamp()]),
    Groups = [{group, [{id, [G#group.id]},
		       {name, [G#group.name]}]} || G <- User#user.groups],
    Tel =
	case User#user.tel of
	    undefined -> "";
	    T -> T
	end,
    EditedUser =
	{record, [
	    {id, [User#user.id]},
	    {name, [User#user.name]},
	    {tenant_id, [User#user.tenant_id]},
	    {tenant_name, [User#user.tenant_name]},
	    {hash_type, [utils:to_list(User#user.hash_type)]},
	    {password, [utils:to_list(User#user.password)]},
	    {salt, [utils:to_list(User#user.salt)]},
	    {login, [User#user.login]},
	    {tel, [Tel]},
	    {enabled, [utils:to_list(User#user.enabled)]},
	    {staff, [utils:to_list(User#user.staff)]},
	    {date_updated, Timestamp},
	    {groups, Groups}
	]},
    RootElement0 = #xmlElement{name=user, content=[EditedUser]},
    XMLDocument0 = xmerl:export_simple([RootElement0], xmerl_xml),
    Response = s3_api:put_object(?SECURITY_BUCKET_NAME, ?USER_PREFIX, User#user.id,
	unicode:characters_to_binary(XMLDocument0)),
    case Response of
	{error, Reason} ->
	    lager:error("[admin_users_handler] Can't put object ~p/~p/~p: ~p",
			[?SECURITY_BUCKET_NAME, ?USER_PREFIX, User#user.id, Reason]),
	    js_handler:bad_request(Req0, "PUT failed");
	_ ->
	    Req1 = cowboy_req:set_resp_body(jsx:encode(user_to_proplist(User)), Req0),
	    {true, Req1, []}
    end.

%%
%% Returns { user ID, user name }
%%
validate_user_name(null, required) ->
    {error, {name, <<"User Name should be specified.">>}};
validate_user_name(undefined, required) ->
    {error, {name, <<"User Name should be specified.">>}};
validate_user_name(null, not_required) -> undefined;
validate_user_name(undefined, not_required) -> undefined;
validate_user_name(<<>>, _IsUserNameRequired) ->
    {error, {name, <<"User Name should be specified.">>}};
validate_user_name(UserName0, _IsUserNameRequired) when erlang:is_binary(UserName0) ->
    %% We don't expect names, longer than 50 characters
    case length(unicode:characters_to_list(UserName0)) > 50 of
	true -> {error, {name, <<"Incorrect User Name. It should be less than 50 characters.">>}};
	false -> utils:hex(utils:trim_spaces(UserName0))
    end.

%%
%% Checks the following
%%	- Login is specified
%%	- Length do not exceed limit
%%	- Login with the same name do not exist yet
%%
%% Returns User ID and hex representation of provided Login.
%%
validate_login(null, required) ->
    {error, {login, <<"Login must be specified.">>}};
validate_login(undefined, required) ->
    {error, {login, <<"Login must be specified.">>}};
validate_login(null, not_required) ->
    {undefined, undefined};
validate_login(undefined, not_required) ->
    {undefined, undefined};
validate_login(<<>>, _IsLoginRequired) ->
    {error, {login, <<"Login can not be empty.">>}};
validate_login(Login0, IsLoginRequired) when erlang:is_binary(Login0) ->
    %% We don't expect login, longer than 30 characters
    case length(unicode:characters_to_list(Login0)) > 30 of
	true -> {error, {login, <<"Login is easier to remember when it is less than 30 characters.">>}};
	false ->
	    UserId = utils:hex(erlang:md5(Login0)),  %% User ID is md5(login)
	    PrefixedLogin = utils:prefixed_object_key(?USER_PREFIX, UserId),
	    case s3_api:head_object(?SECURITY_BUCKET_NAME, PrefixedLogin) of
		not_found -> {UserId, utils:hex(Login0)};
		{error, Reason} ->
		    lager:error("[admin_users_handler] head_object failed ~p/~p: ~p",
				[?SECURITY_BUCKET_NAME, PrefixedLogin, Reason]),
		    {error, {login, <<"Try later">>}};
		_ ->
		    %% PATCH request
		    case IsLoginRequired of
			required -> {error, {login, <<"Login exists.">>}};
			not_required -> {UserId, utils:hex(Login0)}
		    end
	    end
    end.

validate_password(null) -> {undefined, undefined, undefined};
validate_password(undefined) -> {undefined, undefined, undefined};
validate_password(<<>>) -> {undefined, undefined, undefined};
validate_password(Password0) when erlang:is_binary(Password0) ->
    PasswordLength = byte_size(Password0),
    case PasswordLength > 30 orelse PasswordLength < 4 of
	true -> {error, {password, <<"Password length should be between 4 and 30 characters.">>}};
	false ->
	    {ok, Password1, Salt} = crypto_utils:hash_password(Password0),
	    {?AUTH_NAME, Salt, Password1}
    end.

%%
%% Checks if group IDs are defined in tenant
%%
validate_group_ids(null, _TenantGroups) -> [];
validate_group_ids(undefined, _TenantGroups) -> [];
validate_group_ids(<<>>, _TenantGroups) -> {error, {groups, <<"At least one group must be specified.">>}};
validate_group_ids(GroupIds0, _TenantGroups) when erlang:is_list(GroupIds0) ->
    {error, <<"User groups must be string of comma-delimited values.">>};
validate_group_ids(GroupIds0, TenantGroups) when erlang:is_binary(GroupIds0) ->
    GroupIds1 = [case lists:member(erlang:binary_to_list(utils:alphanumeric(T)), [G#group.id || G <- TenantGroups]) of
		    true -> admin_tenants_handler:validate_group_id(utils:alphanumeric(T));
		    false -> {error, lists:flatten(["Group ID ", unicode:characters_to_list(T),
						    " is not defined for provided tenant."])}
		 end || T <- binary:split(GroupIds0, <<",">>, [global]), erlang:byte_size(T) > 0],
    Errors = [element(2, E) || E <- GroupIds1, element(1, E) =:= error],
    case length(Errors) > 0 of
	true ->
	    {error, {groups, unicode:characters_to_binary(lists:flatten(
		utils:join_list_with_separator(Errors, " ", [])))}};
	false ->
	    case utils:has_duplicates(GroupIds1) of
		true -> {error, {groups, <<"Provided list has duplicate group IDs.">>}};
		false -> [G || G <- TenantGroups, lists:member(G#group.id, GroupIds1)]
	    end
    end.

%%
%% Checks the user JSON
%%
validate_post(Tenant, Body) ->
    case jsx:is_json(Body) of
	{error, badarg} -> {error, <<"JSON parsing error.">>};
	false -> {error, <<"JSON parsing error.">>};
	true ->
	    FieldValues = jsx:decode(Body),
	    Login0 = validate_login(proplists:get_value(<<"login">>, FieldValues), required),
	    Tel =
		case proplists:get_value(<<"tel">>, FieldValues) of
		    undefined -> "";
		    V -> utils:hex(V)
		end,
	    Password0 = validate_password(proplists:get_value(<<"password">>, FieldValues)),
	    UserName0 = validate_user_name(proplists:get_value(<<"name">>, FieldValues), required),
	    Groups0 = validate_group_ids(proplists:get_value(<<"groups">>, FieldValues), Tenant#tenant.groups),
	    IsEnabled0 = admin_tenants_handler:validate_boolean(
		proplists:get_value(<<"enabled">>, FieldValues), enabled, true),
	    IsStaff0 = admin_tenants_handler:validate_boolean(
		proplists:get_value(<<"staff">>, FieldValues), staff, false),
	    Errors = [element(2, F) || F <- [Login0, Password0, UserName0, Groups0, IsEnabled0, IsStaff0],
			element(1, F) =:= error],
	    case length(Errors) > 0 of
		true -> {error, Errors};
		false ->
		    {UserId, Login1} = Login0,
		    {HashType, Salt, Password1} = Password0,
		    #user{
			id = UserId,
			name = UserName0,
			tenant_id = Tenant#tenant.id,
			tenant_name = Tenant#tenant.name,
			tenant_enabled = Tenant#tenant.enabled,
			login = Login1,
			tel = Tel,
			salt = Salt,
			password = Password1,
			hash_type = HashType,
			enabled = IsEnabled0,
			staff = IsStaff0,
			groups = Groups0
		    }
	    end
    end.

validate_tel(undefined) -> undefined;
validate_tel(null) -> undefined;
validate_tel(<<>>) -> undefined;
validate_tel(Value) when erlang:is_binary(Value) ->
    utils:hex(utils:trim_spaces(Value)).

validate_patch(not_found, _Tenant, _Body) ->
    {error, <<"User not found">>};
validate_patch(User, Tenant, Body) ->
    case jsx:is_json(Body) of
	{error, badarg} -> {error, <<"JSON parsing error.">>};
	false -> {error, <<"JSON parsing error.">>};
	true ->
	    FieldValues = jsx:decode(Body),
	    UserName0 = validate_user_name(proplists:get_value(<<"name">>, FieldValues), not_required),
	    Login0 = validate_login(proplists:get_value(<<"login">>, FieldValues), not_required),
	    Tel0 = validate_tel(proplists:get_value(<<"tel">>, FieldValues)),
	    Password0 = validate_password(proplists:get_value(<<"password">>, FieldValues)),
	    Groups0 = validate_group_ids(proplists:get_value(<<"groups">>, FieldValues), Tenant#tenant.groups),
	    IsEnabled0 = admin_tenants_handler:validate_boolean(
		proplists:get_value(<<"enabled">>, FieldValues), enabled, User#user.enabled),
	    IsStaff0 = admin_tenants_handler:validate_boolean(
		proplists:get_value(<<"staff">>, FieldValues), staff, User#user.staff),

	    Errors = [element(2, F) || F <- [Login0, Password0, UserName0, Groups0, IsEnabled0, IsStaff0],
			element(1, F) =:= error],
	    case length(Errors) > 0 of
		true -> {error, Errors};
		false ->
		    UserName1 = case UserName0 of undefined -> User#user.name; _ -> UserName0 end,
		    {_UserId, Login1} = Login0,
		    Login2 =
			case Login1 of
			    undefined -> User#user.login;
			    _ -> Login1
			end,
		    {HashType0, Salt0, Password1} = Password0,
		    {HashType1, Salt1, Password2} =
			case Password1 of
			    undefined -> {User#user.hash_type, User#user.salt, User#user.password};
			    _ -> {HashType0, Salt0, Password1}
			end,
		    Groups1 = case Groups0 of [] -> User#user.groups; _ -> Groups0 end,
		    #user{
			id = User#user.id,
			name = UserName1,
			tenant_id = User#user.tenant_id,
			tenant_name = User#user.tenant_name,
			tenant_enabled = User#user.tenant_enabled,
			login = Login2,
			tel = Tel0,
			salt = Salt1,
			password = Password2,
			hash_type = HashType1,
			enabled = IsEnabled0,
			staff = IsStaff0,
			groups = Groups1
		    }
	    end
    end.

%%
%% Creates User record
%%
%% Example of expected request data format:
%%
%% {
%%	"name": "Історик",
%%	"login": "history@example.com",
%%	"password": "secret",
%%	"tenant_id": "sometenant",
%%	"enabled": "true",
%%	"staff": "true",
%%	"groups": "Writers"
%% }
%%
handle_post(Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case proplists:get_value(path_tenant, State) of
	undefined ->
	    Req1 = cowboy_req:reply(404, #{
		<<"content-type">> => <<"application/json">>
	    }, Req0),
	    {stop, Req1, []};
	PathTenant ->
	    case validate_post(PathTenant, Body) of
		{error, Reasons} ->
		    Req2 = cowboy_req:reply(400, #{
			<<"content-type">> => <<"application/json">>
		    }, jsx:encode([{errors, Reasons}]), Req1),
		    {stop, Req2, []};
		User -> new_user(Req1, User)
	    end
    end.

%%
%% User editing endpoint
%%
patch_resource(Req0, State) ->
    Tenant0 = proplists:get_value(path_tenant, State),
    User0 = proplists:get_value(path_user, State),
    case Tenant0 =:= undefined orelse User0 =:= undefined of
	true ->
	    Req1 = cowboy_req:reply(400, #{
		<<"content-type">> => <<"application/json">>
	    }, jsx:encode([{errors, <<"Valid Tenant ID and valid User ID are expected in the URL.">>}]), Req0),
	    {stop, Req1, []};
	false ->
	    {ok, Body, Req1} = cowboy_req:read_body(Req0),
	    case validate_patch(User0, Tenant0, Body) of
		{error, Reasons} ->
		    Req2 = cowboy_req:reply(400, #{
			<<"content-type">> => <<"application/json">>
		    }, jsx:encode([{errors, Reasons}]), Req1),
		    {stop, Req2, []};
		User1 -> edit_user(Req1, User1)
	    end
    end.

delete_resource(Req0, State) ->
    Tenant0 = proplists:get_value(path_tenant, State),
    User0 = proplists:get_value(path_user, State),
    case Tenant0 =:= undefined orelse User0 =:= undefined of
	true ->
	    Req1 = cowboy_req:reply(400, #{
		<<"content-type">> => <<"application/json">>
	    }, jsx:encode([{errors, <<"Valid Tenant ID and valid User ID are expected in the URL.">>}]), Req0),
	    {stop, Req1, []};
	false ->
	    PrefixedUserId = utils:prefixed_object_key(?USER_PREFIX, User0#user.id),
	    {ok, _} = s3_api:delete_object(?SECURITY_BUCKET_NAME, PrefixedUserId),
	    {true, Req0, [{delete_result, ok}]}
    end.

delete_completed(Req0, State) ->
    DeleteResult = proplists:get_value(delete_result, State),
    Req1 = cowboy_req:set_resp_body(jsx:encode(DeleteResult), Req0),
    {true, Req1, []}.
