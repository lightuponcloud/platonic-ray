%%%
%%% @title Dotted Version Vector Set
%%%
%%% @doc  
%%% An Erlang implementation of *compact* Dotted Version Vectors, which
%%% provides a container for a set of concurrent values (siblings) with causal
%%% order information.
%%%
%%% @copyright The MIT License (MIT)
%%% Copyright (C) 2013
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
%%%
%%% @author    Ricardo Tom Gonsalves <tome.wave@gmail.com>
%%% @author    Paulo Sergio Almeida <pssalmeida@gmail.com>
%%%
-module(dvvset).

-export([new/1,
         new/2,
         new_list/1,
         new_list/2,
         sync/1,
         join/1,
         update/2,
         update/3,
         size/1,
         ids/1,
         values/1,
         equal/2,
         less/2,
         map/2,
         last/2,
         lww/2,
         reconcile/2
        ]).

-export_type([clock/0, vector/0, id/0, value/0]).

% % @doc
%% STRUCTURE details:
%%      * entries() are sorted by id()
%%      * each counter() also includes the number of values in that id()
%%      * the values in each triple of entries() are causally ordered and each new value goes to the head of the list

-type clock()   :: nonempty_list().  %% [entries(), values()].
-type vector()  :: nonempty_list().  %% [[id(), counter()]].
-type entries() :: nonempty_list().  %% [[id(), counter(), values()]].
-type id()      :: any().
-type values()  :: [value()].
-type value()   :: any().
-type counter() :: non_neg_integer().


%% @doc Constructs a new clock set without causal history,
%% and receives one value that goes to the anonymous list.
-spec new(value()) -> clock().
new(V) -> [[], [V]].

%% @doc Same as new/1, but receives a list of values, instead of a single value.
-spec new_list([value()]) -> clock().
new_list(Vs) when is_list(Vs) -> [[], Vs];
new_list(V) -> [[], [V]].

%% @doc Constructs a new clock set with the causal history
%% of the given version vector / vector clock,
%% and receives one value that goes to the anonymous list.
%% The version vector SHOULD BE the output of join/1.
-spec new(vector(), value()) -> clock().
new(VV, V) ->
    VVS = lists:sort(VV), % defense against non-order preserving serialization
    [[[I, N, []] || [I, N] <- VVS], [V]].

%% @doc Same as new/2, but receives a list of values, instead of a single value.
-spec new_list(vector(), [value()]) -> clock().
new_list(VV, Vs) when is_list(Vs) ->
    VVS = lists:sort(VV), % defense against non-order preserving serialization
    [[[I, N, []] || [I, N] <- VVS], Vs];
new_list(VV, V) -> new_list(VV, [V]).

%% @doc Synchronizes a list of clocks using sync/2.
%% It discards (causally) outdated values, 
%% while merging all causal histories.
-spec sync([clock()]) -> clock().
sync(L) -> lists:foldl(fun sync/2, [], L).

%% Private function
-spec sync(clock(), clock()) -> clock().
sync([], C) -> C;
sync(C ,[]) -> C;
sync(C1=[E1,V1],C2=[E2,V2]) ->
    V = case less(C1,C2) of
        true  -> V2; % C1 < C2 => return V2
        false -> case less(C2,C1) of
                    true  -> V1; % C2 < C1 => return V1
                    false -> % keep all unique anonymous values and sync entries()
                        sets:to_list(sets:from_list(V1++V2))
                 end
    end,
    [sync2(E1,E2),V].

%% Private function
-spec sync2(entries(), entries()) -> entries().
sync2([], C) -> C;
sync2(C, []) -> C;
sync2([[I1, N1, L1]=H1 | T1]=C1, [[I2, N2, L2]=H2 | T2]=C2) ->
    if
      I1 < I2 -> [H1 | sync2(T1, C2)];
      I1 > I2 -> [H2 | sync2(T2, C1)];
      true    -> [merge(I1, N1, L1, N2, L2) | sync2(T1, T2)]
    end.

%% Private function
-spec merge(id(), counter(), values(), counter(), values()) -> nonempty_list().  %% [id(), counter(), values()].
merge(I, N1, L1, N2, L2) ->
    LL1 = length(L1),
    LL2 = length(L2),
    case N1 >= N2 of
        true ->
          case N1 - LL1 >=  N2 - LL2 of 
            true  -> [I, N1, L1];
            false -> [I, N1, lists:sublist(L1, N1 - N2 + LL2)]
          end;
        false ->
          case N2 - LL2 >=  N1 - LL1 of 
            true  -> [I, N2, L2];
            false -> [I, N2, lists:sublist(L2, N2 - N1 + LL1)]
          end
    end.


%% @doc Return a version vector that represents the causal history.
-spec join(clock()) -> vector().
join([C,_]) -> [[I, N] || [I, N, _] <- C].

%% @doc Advances the causal history with the given id.
%% The new value is the *anonymous dot* of the clock.
%% The client clock SHOULD BE a direct result of new/2.
-spec update(clock(), id()) -> clock().
update([C,[V]], I) -> [event(C, I, V), []].

%% @doc Advances the causal history of the
%% first clock with the given id, while synchronizing
%% with the second clock, thus the new clock is
%% causally newer than both clocks in the argument.
%% The new value is the *anonymous dot* of the clock.
%% The first clock SHOULD BE a direct result of new/2,
%% which is intended to be the client clock with
%% the new value in the *anonymous dot* while
%% the second clock is from the local server.
-spec update(clock(), clock(), id()) -> clock().
update([Cc,[V]], Cr, I) ->
    %% Sync both clocks without the new value
    [C,Vs] = sync([Cc,[]], Cr),
    %% We create a new event on the synced causal history,
    %% with the id I and the new value.
    %% The anonymous values that were synced still remain.
    [event(C, I, V), Vs].

%% Private function
-spec event(vector(), id(), value()) -> entries().
event([], I, V) -> [[I, 1, [V]]];
event([[I, N, L] | T], I, V) -> [[I, N+1, [V | L]] | T];
event([[I1, _, _] | _]=C, I, V) when I1 > I -> [[I, 1, [V]] | C];
event([H | T], I, V) -> [H | event(T, I, V)].

%% @doc Returns the total number of values in this clock set.
-spec size(clock()) -> non_neg_integer().
size([C,Vs]) -> lists:sum([length(L) || [_,_,L] <- C]) + length(Vs).

%% @doc Returns all the ids used in this clock set.
-spec ids(clock()) -> [id()].
ids([C,_]) -> ([I || [I,_,_] <- C]).

%% @doc Returns all the values used in this clock set,
%% including the anonymous values.
-spec values(clock()) -> [value()].
values([C,Vs]) -> Vs ++ lists:append([L || [_,_,L] <- C]).

%% @doc Compares the equality of both clocks, regarding
%% only the causal histories, thus ignoring the values.
-spec equal(clock() | vector(), clock() | vector()) -> boolean().
equal([C1,_],[C2,_]) -> equal2(C1,C2); % DVVSet
equal(C1,C2) when is_list(C1) and is_list(C2) -> equal2(C1,C2). %vector clocks

%% Private function
-spec equal2(vector(), vector()) -> boolean().
equal2([], []) -> true;
equal2([[I, C, L1] | T1], [[I, C, L2] | T2]) 
    when length(L1) =:= length(L2) -> 
    equal2(T1, T2);
equal2(_, _) -> false.

%% @doc Returns True if the first clock is causally older than
%% the second clock, thus values on the first clock are outdated.
%% Returns False otherwise.
-spec less(clock(), clock()) -> boolean().
less([C1,_], [C2,_]) -> greater(C2, C1, false).

%% Private function
-spec greater(vector(), vector(), boolean()) -> boolean().
greater([], [], Strict) -> Strict;
greater([_|_], [], _) -> true;
greater([], [_|_], _) -> false;
greater([[I, N1, _] | T1], [[I, N2, _] | T2], Strict) ->
   if
     N1 == N2 -> greater(T1, T2, Strict);
     N1 >  N2 -> greater(T1, T2, true);
     N1 <  N2 -> false
   end;
greater([[I1, _, _] | T1], [[I2, _, _] | _]=C2, _) when I1 < I2 -> greater(T1, C2, true);
greater(_, _, _) -> false.

%% @doc Maps (applies) a function on all values in this clock set,
%% returning the same clock set with the updated values.
-spec map(fun((value()) -> value()), clock()) -> clock().
map(F, [C,Vs]) -> 
    [[ [I, N, lists:map(F, V)] || [I, N, V] <- C], lists:map(F, Vs)].


%% @doc Return a clock with the same causal history, but with only one
%% value in the anonymous placeholder. This value is the result of
%% the function F, which takes all values and returns a single new value.
-spec reconcile(Winner::fun(([value()]) -> value()), clock()) -> clock().
reconcile(F, C) ->
    V = F(values(C)),
    new(join(C), V).

%% @doc Returns the latest value in the clock set,
%% according to function F(A,B), which returns *true* if 
%% A compares less than or equal to B, false otherwise.
-spec last(LessOrEqual::fun((value(),value()) -> boolean()), clock()) -> value().
last(F, C) ->
   [_ ,_ , V2] = find_entry(F, C),
   V2.

%% @doc Return a clock with the same causal history, but with only one
%% value in its original position. This value is the newest value
%% in the given clock, according to function F(A,B), which returns *true*
%% if A compares less than or equal to B, false otherwise.
-spec lww(LessOrEqual::fun((value(),value()) -> boolean()), clock()) -> clock().
lww(F, C=[E,_]) ->
    case find_entry(F, C) of
        [id, I, V]      -> [join_and_replace(I, V, E),[]];
        [anonym, _, V]  -> new(join(C), V)
    end.

%% find_entry/2 - Private function
find_entry(F, [[], [V|T]]) -> find_entry(F, null, V, [[],T], anonym);
find_entry(F, [[[_, _, []] | T], Vs]) -> find_entry(F, [T,Vs]);
find_entry(F, [[[I, _, [V|_]] | T], Vs]) -> find_entry(F, I, V, [T,Vs], id).

%% find_entry/5 - Private function
find_entry(F, I, V, C, Flag) ->
    Fun = fun (A,B) ->
        case F(A,B) of
            false -> [left,A]; % A is newer than B
            true  -> [right,B] % A is older than B
        end
    end,
    find_entry2(Fun, I, V, C, Flag).

%% find_entry2/5 - Private function
find_entry2(_, I, V, [[], []], anonym) -> [anonym, I , V];
find_entry2(_, I, V, [[], []], id) -> [id, I, V];
find_entry2(F, I, V, [[], [V1 | T]], Flag) ->
    case F(V, V1) of
        [left,V2]  -> find_entry2(F, I, V2, [[],T], Flag);
        [right,V2] -> find_entry2(F, I, V2, [[],T], anonym)
    end;
find_entry2(F, I, V, [[[_, _, []] | T], Vs], Flag) -> find_entry2(F, I, V, [T, Vs], Flag);
find_entry2(F, I, V, [[[I1, _, [V1|_]] | T], Vs], Flag) -> 
    case F(V, V1) of
        [left,V2]  -> find_entry2(F, I, V2, [T, Vs], Flag);
        [right,V2] -> find_entry2(F, I1, V2, [T, Vs], Flag)
    end.

%% Private function
join_and_replace(Ir, V, C) -> 
    [if
       I == Ir -> [I, N, [V]];
       true    -> [I, N, []]
     end
     || [I, N, _] <- C].
