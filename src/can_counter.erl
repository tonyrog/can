%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2015, Tony Rogvall
%%% @doc
%%%    Small wrapper for dynamic counter using proccess dict
%%% @end
%%% Created : 28 Aug 2015 by Tony Rogvall <tony@rogvall.se>

-module(can_counter).

-export([init/1]).
-export([set/2]).
-export([update/2]).
-export([list/0]).

init(Counter) ->
    set(Counter, 0).

set(Counter, Value) ->
    put({counter,Counter}, Value).

update(Counter, Value) ->
    Key = {counter,Counter},
    case get(Key) of
	undefined -> put(Key,Value);
	Current -> put(Key,Current+Value)
    end.

list() ->
    [{C,V} || {{counter,C},V} <- get()].
