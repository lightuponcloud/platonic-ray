%%
%% This module contains common utilities.
%%
-module(utils).

%% Validations
-export([is_valid_bucket_id/2, is_restricted_bucket_id/1,
	 is_valid_object_key/1, is_bucket_belongs_to_group/3, is_bucket_belongs_to_tenant/2,
	 is_true/1, is_false/1, has_duplicates/1, ends_with/2, starts_with/2,
	 even/1, validate_utf8/1, is_valid_hex_prefix/1, is_hidden_object/1,
	 is_hidden_prefix/1, get_token/1]).

%% Conversions
-export([to_integer/1, to_integer/2, to_float/1, to_float/2, to_number/1, to_list/1,
	 to_binary/1, to_binary/2, to_boolean/1, bytes_to_string/1]).

%% Ancillary
-export([slugify_object_key/1, prefixed_object_key/2, alphanumeric/1,
	 trim_spaces/1, hex/1, unhex/1, unhex_path/1, join_list_with_separator/3,
	 join_binary_with_separator/2,
	 timestamp/0, format_timestamp/1, firstmatch/2, timestamp_to_datetime/1,
	 translate/2, dirname/1, read_config/1, real_prefix/2, get_temp_path/1,
	 get_server_version/1]).

-include("storage.hrl").
-include("general.hrl").
-include("entities.hrl").

-define(MULTI_BYTE_UNITS, [<<"KB">>, <<"MB">>, <<"GB">>, <<"TB">>, <<"PB">>, <<"EB">>, <<"ZB">>, <<"YB">>]).

%%
%% Extracts letters and digits from binary.
%%
-spec alphanumeric(binary() | string()) -> binary().

alphanumeric(String) when erlang:is_list(String) ->
    alphanumeric(erlang:list_to_binary(String));
alphanumeric(String) when erlang:is_binary(String)  ->
    re:replace(String, <<"[^a-zA-Z0-9]+">>, <<"">>, [{return, binary}, global]).

%%
%% Transliterates binary to ascii.
%%
-spec slugify_object_key(binary()) -> string().

slugify_object_key(FileName0) when erlang:is_binary(FileName0) ->
    FileName1 = filename:rootname(FileName0),
    FileName2 = slughifi:slugify(FileName1),
    %% Not all unicode characters can be transliterated
    Regex = <<"[^a-zA-Z0-9\-\._~,\\s+]+">>,
    FileName3 = re:replace(unicode:characters_to_binary(FileName2), Regex, <<"">>, [{return, binary}, global]),
    FileName4 = string:to_lower(erlang:binary_to_list(FileName3)),
    Extension0 = filename:extension(FileName0),
    Extension1 = slughifi:slugify(Extension0),
    Extension2 = re:replace(unicode:characters_to_binary(Extension1), Regex, <<"">>, [{return, binary}, global]),
    Extension3 = string:to_lower(erlang:binary_to_list(Extension2)),
    case Extension3 of
	[] -> FileName4;
	_ -> lists:concat([FileName4, Extension3])
    end.

%%
%% Removes spaces at the end and on the beginning of binary string
%%
-spec trim_spaces(binary()) -> binary().

trim_spaces(Bin0) ->
    re:replace(Bin0, <<"^\\s+|\\s+$">>, <<"">>, [{return, binary}, global]).

%%
%% Returns 'prefix/object_key'
%% or, if prefix is empty just 'object_key'
%%
-spec prefixed_object_key(string()|binary()|undefined, string()|binary()) -> string().

prefixed_object_key(null, ObjectKey) -> ObjectKey;
prefixed_object_key(undefined, ObjectKey) -> ObjectKey;
prefixed_object_key([], ObjectKey) -> ObjectKey;
prefixed_object_key(".", ObjectKey) -> ObjectKey;
prefixed_object_key(<<>>, ObjectKey) -> ObjectKey;
prefixed_object_key(BucketId, undefined) -> BucketId;
prefixed_object_key(BucketId, <<"/">>) -> BucketId;
prefixed_object_key(BucketId, null) -> BucketId;
prefixed_object_key(BucketId, []) -> BucketId;
prefixed_object_key(BucketId, <<".">>) -> BucketId;
prefixed_object_key(BucketId, <<>>) -> BucketId;

%% Handle list of path components
prefixed_object_key(List, ObjectKey) when erlang:is_list(List), erlang:length(List) > 0, erlang:is_list(hd(List)) ->
    FirstComponent = hd(List),
    Result = lists:foldl(
        fun(Component, Acc) ->
            prefixed_object_key(Acc, Component)
        end,
        FirstComponent,
        tl(List)
    ),
    prefixed_object_key(Result, ObjectKey);

prefixed_object_key(Prefix, ObjectKey0) when erlang:is_binary(Prefix), erlang:is_binary(ObjectKey0) ->
    ObjectKey1 =
        case starts_with(ObjectKey0, <<"/">>) of
            true ->
                << _:1/binary, N0/binary >> = ObjectKey0,
                N0;
            false -> ObjectKey0
        end,
    case ends_with(Prefix, <<"/">>) of
        true -> << Prefix/binary, ObjectKey1/binary >>;
        false -> << Prefix/binary, <<"/">>/binary, ObjectKey1/binary >>
    end;
prefixed_object_key(Prefix, ObjectKey0) when erlang:is_list(Prefix), erlang:is_list(ObjectKey0) ->
    FlatPrefix = lists:flatten(Prefix),
    FlatObject = lists:flatten(ObjectKey0),

    ObjectKey1 =
        case length(FlatObject) > 0 andalso string:sub_string(FlatObject, 1, 1) =:= "/" of
            true -> string:sub_string(FlatObject, 2, length(FlatObject));
            false -> FlatObject
        end,

    %% Concatenate prefix and object key
    case length(FlatPrefix) > 0 andalso string:sub_string(FlatPrefix, length(FlatPrefix), length(FlatPrefix)) =:= "/" of
        true -> string:concat(FlatPrefix, ObjectKey1);
        false -> string:concat(string:concat(FlatPrefix, "/"), ObjectKey1)
    end.


%%
%% Files are stored by the following URLs
%% ~object/file-GUID/upload-GUID/N_md5, where N is the part number
%%
%% This function returns a bucket id and prefix:
%% {bucket_id, GUID, UploadId, ~object/file-GUID/upload-GUID/}
%%
-spec real_prefix(string(), list()) -> {string(), string()}.

real_prefix(BucketId, Metadata) ->
    GUID = proplists:get_value("x-amz-meta-guid", Metadata),
    UploadId = proplists:get_value("x-amz-meta-upload-id", Metadata),
    %% Old GUID, old bucket id and upload id are needed for 
    %% determining URI of the original object, before it was copied
    OldGUID = proplists:get_value("x-amz-meta-copy-from-guid", Metadata),
    OldBucketId =
	case proplists:get_value("x-amz-meta-copy-from-bucket-id", Metadata) of
	    undefined -> BucketId;
	    B -> B
	end,
    OldUploadId =
	case proplists:get_value("x-amz-meta-copy-from-upload-id", Metadata) of
	    undefined -> UploadId;
	    UID -> UID
	end,
    case OldGUID =/= undefined andalso OldGUID =/= GUID of
	true ->
	    RealPrefix1 = prefixed_object_key(?REAL_OBJECT_PREFIX, OldGUID),
	    {OldBucketId, OldGUID, OldUploadId, prefixed_object_key(RealPrefix1, OldUploadId)};
	false ->
	    PrefixedGUID0 = prefixed_object_key(?REAL_OBJECT_PREFIX, GUID),
	    {BucketId, GUID, UploadId, prefixed_object_key(PrefixedGUID0, UploadId)}
    end.


-spec to_integer(string() | binary() | integer() | float() | undefined) -> integer().

to_integer(X) ->
    to_integer(X, nonstrict).

-spec to_integer(string() | binary() | integer() | float(),
		 strict | nonstrict | undefined) -> integer().
to_integer(X, strict)
  when erlang:is_float(X) ->
    erlang:error(badarg);
to_integer(X, nonstrict)
  when erlang:is_float(X) ->
    erlang:round(X);
to_integer(X, S)
  when erlang:is_binary(X) ->
    to_integer(erlang:binary_to_list(X), S);
to_integer(X, S) when erlang:is_list(X) ->
    case string:to_integer(X) of
        {Int, []} when erlang:is_integer(Int) -> Int;
        _ when S =:= nonstrict ->
            case string:to_float(X) of
                {Float, []} -> erlang:round(Float);
                _ -> erlang:error(badarg)
            end;
        _ -> erlang:error(badarg)
    end;
to_integer(X, _)
  when erlang:is_integer(X) ->
    X.

%% @doc
%% Automatic conversion of a term into float type. badarg if strict
%% is defined and an integer value is passed.
-spec to_float(string() | binary() | integer() | float()) ->
                      float().
to_float(X) ->
    to_float(X, nonstrict).

-spec to_float(string() | binary() | integer() | float(), strict | nonstrict) -> float().

to_float(X, S) when erlang:is_binary(X) ->
    to_float(erlang:binary_to_list(X), S);
to_float(X, S)
  when erlang:is_list(X) ->
    try erlang:list_to_float(X) of
        Result ->
            Result
    catch
        error:badarg when S =:= nonstrict ->
            erlang:list_to_integer(X) * 1.0
    end;
to_float(X, strict) when
      erlang:is_integer(X) ->
    erlang:error(badarg);
to_float(X, nonstrict)
  when erlang:is_integer(X) ->
    X * 1.0;
to_float(X, _) when erlang:is_float(X) ->
    X.

%% @doc
%% Automatic conversion of a term into number type.
-spec to_number(binary() | string() | number()) ->
                       number().
to_number(X)
  when erlang:is_number(X) ->
    X;
to_number(X)
  when erlang:is_binary(X) ->
    to_number(to_list(X));
to_number(X)
  when erlang:is_list(X) ->
    try list_to_integer(X) of
        Int -> Int
    catch
        error:badarg ->
            list_to_float(X)
    end.

%% @doc
%% Automatic conversion of a term into Erlang list
-spec to_list(atom() | list() | binary() | integer() | float()) -> list().
to_list(X) when erlang:is_float(X) ->
    erlang:float_to_list(X);
to_list(X) when erlang:is_integer(X) ->
    erlang:integer_to_list(X);
to_list(X) when erlang:is_binary(X) ->
    erlang:binary_to_list(X);
to_list(X) when erlang:is_atom(X) ->
    erlang:atom_to_list(X);
to_list(X) when erlang:is_list(X) ->
    X.

%% @doc
%% Known limitations:
%%   Converting [256 | _], lists with integers > 255
-spec to_binary(atom() | string() | binary() | integer() | float()) -> binary().
to_binary(X) when erlang:is_float(X) ->
    to_binary(to_list(X));
to_binary(X) when erlang:is_integer(X) ->
    erlang:iolist_to_binary(integer_to_list(X));
to_binary(X) when erlang:is_atom(X) ->
    erlang:list_to_binary(erlang:atom_to_list(X));
to_binary(X) when erlang:is_list(X) ->
    erlang:iolist_to_binary(X);
to_binary(X) when erlang:is_binary(X) ->
    X.

%% @private Converts number to binary with specified precision
-spec to_binary(number(), integer()) -> binary().
to_binary(Number, Precision) when Precision >= 0 ->
    % Use ~.Nf formatting for specified precision
    erlang:list_to_binary(io_lib:format("~.*f", [Precision, Number]));
to_binary(Number, _) when erlang:is_integer(Number) ->
    integer_to_binary(Number);
to_binary(Number, _) when erlang:is_float(Number) ->
    % Use default representation for floats
    Bin = erlang:float_to_binary(Number, [{decimals, 10}, compact]),
    % Remove trailing zeros after decimal point
    remove_trailing_zeros(Bin).

%% @private Removes trailing zeros from float binary representation
-spec remove_trailing_zeros(binary()) -> binary().
remove_trailing_zeros(Bin) ->
    case binary:match(Bin, <<".">>) of
        nomatch -> Bin;
        _ ->
            case binary:last(Bin) of
                $0 -> remove_trailing_zeros(binary:part(Bin, 0, byte_size(Bin) - 1));
                $. -> binary:part(Bin, 0, byte_size(Bin) - 1);
                _ -> Bin
            end
    end.

-spec to_boolean(binary() | string() | atom()) ->
                        boolean().
to_boolean(<<"true">>) -> true;
to_boolean("true") -> true;
to_boolean(true) -> true;
to_boolean(<<"false">>) -> false;
to_boolean("false") -> false;
to_boolean(false) -> false.

-spec is_true(binary() | string() | atom()) -> boolean().

is_true(<<"true">>) -> true;
is_true("true") -> true;
is_true(true) -> true;
is_true(_) -> false.

-spec is_false(binary() | string() | atom()) -> boolean().

is_false(<<"false">>) -> true;
is_false("false") -> true;
is_false(false) -> true;
is_false(_) -> false.

%% This function returns 0 on success, 1 on error, and 2..8 on incomplete data.
%% Tail-recursive UTF-8 binary validator

%% Main entry point with fast path validation
validate_utf8(Bin) when is_binary(Bin) ->
    %% Try fast path first
    case unicode:characters_to_binary(Bin) of
        {error, _, _} -> 1;  %% Invalid UTF-8
        {incomplete, _, _} -> 1;  %% Incomplete UTF-8 sequence
        _ -> 
            %% Perform detailed validation with state machine
            validate_utf8(Bin, 0, [])
    end.

%% Tail-recursive implementation with state and accumulator
validate_utf8(<<>>, 0, _Acc) -> 0;  %% Valid if we end in state 0
validate_utf8(<<>>, _State, _Acc) -> 1;  %% Invalid if we end in any other state
validate_utf8(<< C, Rest/binary >>, 0, Acc) when C < 128 ->
    %% ASCII character
    validate_utf8(Rest, 0, [C | Acc]);
validate_utf8(<< C, Rest/binary >>, 0, Acc) when C >= 194, C < 224 ->
    %% 2-byte sequence start
    validate_utf8(Rest, 2, [C | Acc]);
validate_utf8(<< 224, Rest/binary >>, 0, Acc) ->
    %% 3-byte sequence start (with special handling for 0xE0)
    validate_utf8(Rest, 4, [224 | Acc]);
validate_utf8(<< C, Rest/binary >>, 0, Acc) when C >= 225, C < 237 ->
    %% Standard 3-byte sequence start
    validate_utf8(Rest, 3, [C | Acc]);
validate_utf8(<< 237, Rest/binary >>, 0, Acc) ->
    %% 3-byte sequence start (with special handling for 0xED)
    validate_utf8(Rest, 5, [237 | Acc]);
validate_utf8(<< C, Rest/binary >>, 0, Acc) when C =:= 238; C =:= 239 ->
    %% Standard 3-byte sequence start
    validate_utf8(Rest, 3, [C | Acc]);
validate_utf8(<< 240, Rest/binary >>, 0, Acc) ->
    %% 4-byte sequence start (with special handling for 0xF0)
    validate_utf8(Rest, 6, [240 | Acc]);
validate_utf8(<< C, Rest/binary >>, 0, Acc) when C =:= 241; C =:= 242; C =:= 243 ->
    %% Standard 4-byte sequence start
    validate_utf8(Rest, 7, [C | Acc]);
validate_utf8(<< 244, Rest/binary >>, 0, Acc) ->
    %% 4-byte sequence start (with special handling for 0xF4)
    validate_utf8(Rest, 8, [244 | Acc]);
validate_utf8(<< C, Rest/binary >>, 2, Acc) when C >= 128, C < 192 ->
    %% Valid continuation byte for state 2
    validate_utf8(Rest, 0, [C | Acc]);
validate_utf8(<< C, Rest/binary >>, 3, Acc) when C >= 128, C < 192 ->
    %% Valid continuation byte for state 3
    validate_utf8(Rest, 2, [C | Acc]);
validate_utf8(<< C, Rest/binary >>, 4, Acc) when C >= 160, C < 192 ->
    %% Valid continuation byte for state 4 (special case for 0xE0)
    validate_utf8(Rest, 2, [C | Acc]);
validate_utf8(<< C, Rest/binary >>, 5, Acc) when C >= 128, C < 160 ->
    %% Valid continuation byte for state 5 (special case for 0xED)
    validate_utf8(Rest, 2, [C | Acc]);
validate_utf8(<< C, Rest/binary >>, 6, Acc) when C >= 144, C < 192 ->
    %% Valid continuation byte for state 6 (special case for 0xF0)
    validate_utf8(Rest, 3, [C | Acc]);
validate_utf8(<< C, Rest/binary >>, 7, Acc) when C >= 128, C < 192 ->
    %% Valid continuation byte for state 7
    validate_utf8(Rest, 3, [C | Acc]);
validate_utf8(<< C, Rest/binary >>, 8, Acc) when C >= 128, C < 144 ->
    %% Valid continuation byte for state 8 (special case for 0xF4)
    validate_utf8(Rest, 3, [C | Acc]);
validate_utf8(_, _, _) -> 1.  %% Any other case is invalid


%% This function returns 0 on success, 1 on error.
%% Usage: case even(byte_size(Str)) of true -> validate_hex();..
validate_hex(<<>>, State) -> State;
validate_hex(<< C, Rest/bits >>, 0) when C >= $0 andalso C =< $9 -> validate_hex(Rest, 0);
validate_hex(<< C, Rest/bits >>, 0) when C >= $a andalso C =< $f -> validate_hex(Rest, 0);
validate_hex(<< C, Rest/bits >>, 0) when C >= $A andalso C =< $F -> validate_hex(Rest, 0);
validate_hex(_, _) -> 1.

%%
%% Checks the following
%% - Bucket has specified tenant ID
%%     as system do not allow to read contents of other tenants
%% - Length of bucket is less than 63
%%     as this is limit of Riak CS
%% - Suffix is either private or restricted
%%
-spec is_valid_bucket_id(string(), string()|undefined) -> boolean().

is_valid_bucket_id(undefined, _TenantId) -> false;
is_valid_bucket_id(BucketId, TenantId) when erlang:is_list(BucketId) ->
    Bits = string:tokens(BucketId, "-"),
    case length(BucketId) =< ?MAX_BUCKET_LENGTH of
	false -> false;
	true ->
	    case length(Bits) of
		3 ->
		    BucketSuffix = lists:last(Bits),
		    (BucketSuffix =:= ?PRIVATE_BUCKET_SUFFIX
		     orelse BucketSuffix =:= ?RESTRICTED_BUCKET_SUFFIX
		    ) andalso lists:prefix([?BACKEND_PREFIX], Bits) =:= true;
		4 ->
		    BucketTenantId = string:to_lower(lists:nth(2, Bits)),
		    BucketSuffix = lists:last(Bits),
		    case TenantId of
			undefined ->
			    (BucketSuffix =:= ?PRIVATE_BUCKET_SUFFIX
			     orelse BucketSuffix =:= ?RESTRICTED_BUCKET_SUFFIX
			    ) andalso lists:prefix([?BACKEND_PREFIX], Bits) =:= true;
			_ ->
			    (BucketSuffix =:= ?PRIVATE_BUCKET_SUFFIX
			     orelse BucketSuffix =:= ?RESTRICTED_BUCKET_SUFFIX
			    ) andalso BucketTenantId =:= TenantId
			    andalso lists:prefix([?BACKEND_PREFIX], Bits) =:= true
		    end;
		_ -> false
	    end
    end.

is_restricted_bucket_id(BucketId) when erlang:is_list(BucketId) ->
    Bits = string:tokens(BucketId, "-"),
    case lists:last(Bits) of
	?RESTRICTED_BUCKET_SUFFIX -> true;
	_ -> false
    end.

even(X) when X >= 0 -> (X band 1) == 0.

%%
%% Checks if provided prefix consists of allowed characters
%%
is_valid_hex_prefix(undefined) -> true;
is_valid_hex_prefix(HexPrefix) when erlang:is_list(HexPrefix) ->
    is_valid_hex_prefix(erlang:list_to_binary(HexPrefix));
is_valid_hex_prefix(HexPrefix) when erlang:is_binary(HexPrefix) ->
    F0 = fun(T) ->
	    case even(erlang:byte_size(T)) of
		true ->
		    case validate_hex(T, 0) of
			0 -> is_valid_object_key(unhex(T));
			1 -> false
		    end;
	    _ ->
		false
	    end
	end,
    lists:all(
	F0, [T || T <- binary:split(HexPrefix, <<"/">>, [global]), erlang:byte_size(T) > 0]
    );
is_valid_hex_prefix(undefined) -> true.

%%
%% Returns true, if "tenant id" and "group name", that are encoded
%% in BucketId equal to provided TenantId and GroupName.
%% the-projectname-groupname-res
%% ^^^ ^^^^^^^^^^^ ^^^^^^^^  ^^^
%% prefix  bucket  group     suffix
%%
-spec is_bucket_belongs_to_group(string(), string(), string()) -> boolean().

is_bucket_belongs_to_group(BucketId, TenantId, GroupName)
    when erlang:is_list(BucketId), erlang:is_list(TenantId),
	 erlang:is_list(GroupName) ->
    Bits = string:tokens(BucketId, "-"),
    case length(Bits) >= 4 of
        true ->
            BucketTenantId = string:to_lower(lists:nth(2, Bits)),
            BucketGroupName = string:to_lower(lists:nth(3, Bits)),
            BucketGroupName =:= GroupName andalso BucketTenantId =:= TenantId;
        false -> false
    end;
is_bucket_belongs_to_group(_,_,_) -> false.

is_bucket_belongs_to_tenant(BucketId, TenantId)
	when erlang:is_list(BucketId), erlang:is_list(TenantId) ->
    Bits = string:tokens(BucketId, "-"),
    BucketTenantId = string:to_lower(lists:nth(2, Bits)),
    BucketTenantId =:= TenantId;
is_bucket_belongs_to_tenant(_,_) -> false.

%%
%% This function returns 0 when binary string do not contain forbidden
%% characters. Returns 1 otherwise.
%%
%% Forbidden characters are " < > \ | / : * ?
%%
is_valid_object_key(<<>>, State) -> State;
is_valid_object_key(<< $", _/bits >>, 0) -> 1;
is_valid_object_key(<< $<, _/bits >>, 0) -> 1;
is_valid_object_key(<< $>, _/bits >>, 0) -> 1;
is_valid_object_key(<< "\\", _/bits >>, 0) -> 1;
is_valid_object_key(<< $|, _/bits >>, 0) -> 1;
is_valid_object_key(<< $/, _/bits >>, 0) -> 1;
is_valid_object_key(<< $:, _/bits >>, 0) -> 1;
is_valid_object_key(<< $*, _/bits >>, 0) -> 1;
is_valid_object_key(<< $?, _/bits >>, 0) -> 1;
is_valid_object_key(<< _, Rest/bits >>, 0) -> is_valid_object_key(Rest, 0).

-spec is_valid_object_key(binary()) -> true|false.

is_valid_object_key(<<>>) -> false;
is_valid_object_key(Prefix) when erlang:is_binary(Prefix) ->
    (size(Prefix) =< 254) andalso (validate_utf8(Prefix) =:= 0) andalso (is_valid_object_key(Prefix, 0) =:= 0);
is_valid_object_key(_) -> false.

digit(0) -> $0;
digit(1) -> $1;
digit(2) -> $2;
digit(3) -> $3;
digit(4) -> $4;
digit(5) -> $5;
digit(6) -> $6;
digit(7) -> $7;
digit(8) -> $8;
digit(9) -> $9;
digit(10) -> $a;
digit(11) -> $b;
digit(12) -> $c;
digit(13) -> $d;
digit(14) -> $e;
digit(15) -> $f.

hex(undefined) -> [];
hex(Bin) -> erlang:binary_to_list(<< << (digit(A1)),(digit(A2)) >> || <<A1:4,A2:4>> <= Bin >>).
unhex(Hex) -> << << (erlang:list_to_integer([H1,H2], 16)) >> || <<H1,H2>> <= Hex >>.

%%
%% Decodes hexadecimal representation of object path
%% and returns list of unicode character numbers.
%%
-spec unhex_path(string()) -> list().

unhex_path(undefined) -> [];
unhex_path(Path) when erlang:is_list(Path) ->
    Bits0 = binary:split(unicode:characters_to_binary(Path), <<"/">>, [global]),

    Bits1 = [case is_valid_hex_prefix(T) of
	true -> unhex(T);
	false -> T end || T <- Bits0, erlang:byte_size(T) > 0],
    Bits2 = [unicode:characters_to_list(T) || T <- Bits1],
    join_list_with_separator(Bits2, "/", []).

%%
%% Returns UNIX timestamp. Precision: microseconds
%%
timestamp() ->
    {Mega, Sec, Micro} = erlang:timestamp(),
    (Mega*1000000 + Sec)*1000 + (Micro div 1000).

%%
%% Converts timestamp to datetime.
%%
timestamp_to_datetime(TimeStamp) ->
    UnixEpochGS = calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}),
    GregorianSeconds = (TimeStamp div 1000) + UnixEpochGS,
    calendar:universal_time_to_local_time(calendar:gregorian_seconds_to_datetime(GregorianSeconds)).

%%
%% Converts timestamp to string "YYYY-mm-dd".
%%
format_timestamp(ModifiedTime0) when erlang:is_integer(ModifiedTime0) ->
    ModifiedTime1 = timestamp_to_datetime(ModifiedTime0*1000),
    {{Year, Month, Day}, {_H, _M, _S}} = ModifiedTime1,
    lists:flatten(
	io_lib:format("~4.10.0b-~2.10.0b-~2.10.0b", [Year, Month, Day])).

%%
%% Checks if provided object's key ends with service suffix
%%
-spec is_hidden_object(proplist()) -> boolean().

is_hidden_object(ObjInfo) ->
    case proplists:get_value(key, ObjInfo) of
        undefined -> true;  %% .stop file or something
        ObjectKey ->
	    lists:suffix(?INDEX_FILENAME, ObjectKey) =:= true orelse 
	    lists:suffix(?LOCK_INDEX_FILENAME, ObjectKey) =:= true orelse
	    lists:suffix(?LOCK_SUFFIX, ObjectKey) =:= true orelse
	    lists:suffix(?DB_VERSION_KEY, ObjectKey) =:= true orelse
	    lists:suffix(?DB_VERSION_LOCK_FILENAME, ObjectKey) =:= true
    end.

%%
%% Check if provided prefix starts with service prefixes.
%%
-spec is_hidden_prefix(list()) -> boolean().

is_hidden_prefix(Prefix) when erlang:is_list(Prefix) ->
    lists:prefix(?REAL_OBJECT_PREFIX, Prefix) =:= true orelse 
    lists:prefix(?REAL_OBJECT_PREFIX, Prefix) =:= true.

%%
%% Joins a list of elements adding a separator between each of them.
%% Example: ["a", "/", "b"]
%%
-spec join_list_with_separator(List :: [string()], Sep :: string(), Acc0 :: list()) -> binary().
join_list_with_separator([Head|Tail], Sep, Acc0) ->
    Acc1 = case Tail of
	[] -> [Head | Acc0];  % do not add separator at the beginning
	_ ->
	    case Head of
		Sep -> Acc0;
		"" -> Acc0;
		_ -> [Sep, Head | Acc0]
	    end
    end,
    join_list_with_separator(Tail, Sep, Acc1);
join_list_with_separator([], _Sep, Acc0) -> lists:reverse(Acc0).

-spec join_binary_with_separator(List :: [binary()], Sep :: binary()) -> binary().
join_binary_with_separator([Head|Tail], Sep) ->
    case Tail of
	<<>> -> [Head|Tail];
	<<"/">> -> [Head|Tail];
	_ ->
	    lists:foldl(
		fun (Value, Acc) ->
		    case Value of
			Sep -> Acc;
			<<>> -> Acc;
			_ -> <<Acc/binary, Sep/binary, Value/binary>>
		    end
		end, Head, Tail)
    end;
join_binary_with_separator([], _Sep) -> <<>>.

-spec get_token(any()) -> list()|undefined.

get_token(Req0) ->
    case cowboy_req:header(<<"authorization">>, Req0) of
        <<"Token ", TokenValue0/binary>> -> erlang:binary_to_list(TokenValue0);
	_ -> undefined
    end.

%%
%% Checks if provided list has duplicate items.
%%
-spec has_duplicates(list()) -> boolean().

has_duplicates([H|T]) ->
    case lists:member(H, T) of
	true -> true;
	false -> has_duplicates(T)
    end;
has_duplicates([]) -> false.

%%
%% Returns true, if `Name` ends with `Characters`
%%
-spec ends_with(binary()|list()|undefined, binary()) -> boolean().

ends_with(null, _Smth) -> false;
ends_with(undefined, _Smth) -> false;
ends_with(Name, Characters)
	when erlang:is_list(Name), erlang:is_binary(Characters) ->
    ends_with(erlang:list_to_binary(Name), Characters);
ends_with(Name, Characters)
	when erlang:is_binary(Name), erlang:is_binary(Characters) ->
    Size0 = byte_size(Characters),
    Size1 = byte_size(Name)-Size0,
    case Size1 < 0 of
	true -> false;
	false ->
	    <<_:Size1/binary, Rest/binary>> = Name,
	    Rest =:= Characters
    end.

%%
%% Returns true, if `Name` starts with `Characters`
%%
-spec starts_with(binary()|list()|undefined, binary()) -> boolean().

starts_with(undefined, _Smth) -> false;
starts_with(Name, Characters)
	when erlang:is_list(Name), erlang:is_binary(Characters) ->
    starts_with(erlang:list_to_binary(Name), Characters);
starts_with(Name, Characters)
	when erlang:is_binary(Name), erlang:is_binary(Characters) ->
    Size0 = byte_size(Characters),
    Size1 = byte_size(Name)-Size0,
    case Size1 < 0 of
	true -> false;
	false ->
	    <<Beginning:Size0/binary, _/binary>> = Name,
	    Beginning =:= Characters
    end.

%%
%% Returns the first item matching condition.
%%
firstmatch(L, Condition) ->
  case lists:dropwhile(fun(E) -> not Condition(E) end, L) of
    [] -> [];
    [F | _] -> F
  end.

translate(Val, Locale) when is_list(Locale) ->
    %% TODO: use dets to get translations
    Val.

-spec dirname(binary()|list()|undefined) -> binary()|list()|undefined.

dirname(undefined) -> undefined;
dirname([]) -> undefined;
dirname(Path0) when erlang:is_list(Path0) ->
    Path1 =
	case string:sub_string(Path0, length(Path0), length(Path0)) =:= "/" of
	    true -> string:sub_string(Path0, 1, length(Path0)-1);
	    _ -> Path0
	end,
    case filename:dirname(Path1) of
	"." -> undefined;
	Path2 -> Path2 ++ "/"
    end;
dirname(Path0) when erlang:is_binary(Path0) ->
    Path2 =
	case ends_with(Path0, <<"/">>) of
	    true ->
		Size = byte_size(Path0)-1,
		<<Path1:Size/binary, _/binary>> = Path0,
		filename:dirname(Path1);
	    false -> filename:dirname(Path0)
	end,
    case filename:dirname(Path2) of
	<<".">> -> undefined;
	Path3 -> << Path3/binary, <<"/">>/binary >>
    end.

%%
%% Reads application config from sys.config
%%
read_config(App) ->
    Config = application:get_all_env(App),

    Port = proplists:get_value(http_listen_port, Config),
    #general_settings{
        version = proplists:get_value(version, Config),
        http_listen_port = Port
    }.

%%
%% Return path to temporary filename.
%%
get_temp_path(App) ->
    Config = application:get_all_env(App),

    TempPath = proplists:get_value(temp_path, Config),

    filename:join([TempPath, crypto_utils:random_string()]).

%%
%% Return application version.
%%
get_server_version(App) ->
    Config = application:get_all_env(App),

    proplists:get_value(version, Config).




%% @doc Formats a number with thousand separators
%% Validates input is a number and handles negative numbers properly
%% Returns formatted string or throws badarg for invalid inputs
-spec format_bytes(number()) -> binary().
format_bytes(Number) ->
    format_bytes(Number, #{}).

%% @doc Formats a number with thousand separators with options
%% Options map can include:
%%   - separator: binary() - custom thousand separator (default: <<",">>)
%%   - decimal_point: binary() - custom decimal point (default: <<".">>)
%%   - precision: integer() - decimal precision (default: determined by input)
-spec format_bytes(number(), map()) -> binary().
format_bytes(Number, Options) when (is_integer(Number) orelse is_float(Number)) ->
    % Extract options with defaults
    Separator = maps:get(separator, Options, <<",">>),
    DecimalPoint = maps:get(decimal_point, Options, <<".">>),
    
    % Handle sign separately
    {Sign, PositiveNumber} = case Number < 0 of
        true -> {<<"-">>, erlang:abs(Number)};
        false -> {<<>>, Number}
    end,
    
    % Convert to binary representation
    BinNum = case is_map_key(precision, Options) of
        true ->
            Precision = maps:get(precision, Options),
            to_binary(PositiveNumber, Precision);
        false ->
            to_binary(PositiveNumber, -1)  % Use default precision
    end,
    
    % Split integer and decimal parts
    {IntegerPart, DecimalPart} = case binary:split(BinNum, <<".">>, [global]) of
        [I, D] -> {I, D};
        [I] -> {I, <<>>}
    end,
    
    % Format the integer part with thousand separators
    FormattedIntegerPart = format_integer_part(IntegerPart, Separator),
    
    % Combine parts
    FullNumber = case DecimalPart of
        <<>> ->
            FormattedIntegerPart;
        _ ->
            <<FormattedIntegerPart/binary, DecimalPoint/binary, DecimalPart/binary>>
    end,
    
    % Apply sign
    <<Sign/binary, FullNumber/binary>>;

format_bytes(_, _) ->
    erlang:error(badarg).

%% @private Formats the integer part with thousand separators
-spec format_integer_part(binary(), binary()) -> binary().
format_integer_part(IntegerPart, Separator) ->
    HeadSize = byte_size(IntegerPart) rem 3,
    case HeadSize of
        0 when byte_size(IntegerPart) =:= 0 ->
            <<"0">>;  % Handle "0" or "0.xxx" case
        0 ->
            % Integer part is already divisible by 3, start splitting from beginning
            ThousandParts = split_thousands(IntegerPart),
	    join_binary_with_separator(ThousandParts, Separator);
        _ ->
            % Extract head and rest
            <<Head:HeadSize/binary, Rest/binary>> = IntegerPart,
            ThousandParts = split_thousands(Rest),
            AllParts = [Head | ThousandParts],
	    join_binary_with_separator(AllParts, Separator)
    end.

%% @private Splits binary into chunks of 3 characters
-spec split_thousands(binary()) -> [binary()].
split_thousands(<<>>) -> [];
split_thousands(Bin) ->
    split_thousands(Bin, []).

split_thousands(<<>>, Acc) ->
    lists:reverse(Acc);
split_thousands(Bin, Acc) ->
    case byte_size(Bin) of
        Size when Size =< 3 ->
            lists:reverse([Bin | Acc]);
        _ ->
            <<Chunk:3/binary, Rest/binary>> = Bin,
            split_thousands(Rest, [Chunk | Acc])
    end.


bytes_to_string(Size) ->
    bytes_to_string(Size, 1).

bytes_to_string(Size0, N) ->
    Power = math:pow(2, 10),
    Size1 = Size0/Power,
    case Size1 < 1024 of
	true -> 
	    Number = format_bytes(Size1),
	    Units =
		case N > length(?MULTI_BYTE_UNITS) of
		    true -> lists:nth(length(?MULTI_BYTE_UNITS), ?MULTI_BYTE_UNITS);
		    false -> lists:nth(N, ?MULTI_BYTE_UNITS)
		end,
	    << Number/binary, <<" ">>/binary, Units/binary >>;
	false -> bytes_to_string(Size1, N+1)
    end.
