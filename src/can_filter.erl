%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2015, Tony Rogvall
%%% @doc
%%%    CAN soft filter
%%% @end
%%% Created : 28 Aug 2015 by Tony Rogvall <tony@rogvall.se>

-module(can_filter).

-export([new/0, add/2, set/3, del/2, get/2, list/1]).
-export([input/2]).

-include("../include/can.hrl").

-record(can_fs,
	{
	  next_id = 1,
	  filter :: gb_trees:tree()  %% I -> #can_filter{}
	}).

%% create filter structure
new() ->
    #can_fs { filter = gb_trees:empty() }.

%% add filter to filter structure
add(F, Fs) when is_record(F, can_filter), is_record(Fs, can_fs) ->
    I = Fs#can_fs.next_id,
    {I, set(I,F,Fs)}.

set(I,F,Fs) when is_integer(I), is_record(F,can_filter),
		 is_record(Fs,can_fs) ->
    Filter = gb_trees:enter(I, F, Fs#can_fs.filter),
    Fs#can_fs { filter=Filter, next_id=erlang:max(I+1,Fs#can_fs.next_id)}.

del(I, Fs) when is_integer(I), is_record(Fs, can_fs) ->
    case gb_trees:is_defined(I, Fs#can_fs.filter) of
	true ->
	    Filter = gb_trees:delete(I,  Fs#can_fs.filter),
	    {true, Fs#can_fs { filter=Filter }};
	false ->
	    {false, Fs}
    end.

get(I, Fs) when is_integer(I), is_record(Fs, can_fs) ->
    case gb_trees:lookup(I, Fs#can_fs.filter) of
	{value,F} ->
	    {ok,F};
	none ->
	    {error, enoent}
    end.

%% return the ordered filter list [{Num,#can_filter{}}]
list(Fs) when is_record(Fs, can_fs) ->
    {ok, gb_trees:to_list(Fs#can_fs.filter)}.

%% filter a frame
%% return true for no filtering (pass through)
%% return false for filtering
%%
input(F, Fs) when is_record(F, can_frame), is_record(Fs, can_fs) ->
    case gb_trees:is_empty(Fs#can_fs.filter) of
	true -> true;  %% default to accept all
	false -> filter_(F,gb_trees:iterator(Fs#can_fs.filter))
    end.

filter_(Frame, Iter) ->
    case gb_trees:next(Iter) of
	none -> false;
	{_I,F,Iter1} ->
	    Mask = F#can_filter.mask,
	    Cond = (Frame#can_frame.id band Mask) =:= 
		(F#can_filter.id band Mask),
	    if ?is_not_can_id_inv_filter(F#can_filter.id), Cond ->
		    true;
	       ?is_can_id_inv_filter(F#can_filter.id), not Cond ->
		    true;
	       true ->
		    filter_(Frame, Iter1)
	    end
    end.
