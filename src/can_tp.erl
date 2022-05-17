%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2020, Tony Rogvall
%%% @doc
%%%    Implement simple ISO-TP client
%%% @end
%%% Created :  9 Jun 2020 by Tony Rogvall <tony@rogvall.se>

-module(can_tp).

-export([read/2]).

-include("../include/can.hrl").

-define(SINGLE, 0).
-define(FIRST,  1).
-define(NEXT,   2).
-define(FLOW,   3).

-define(CONTINUE, 0).
-define(WAIT,     1).
-define(ABORT,    2).

read(_ID,Timeout) ->  %% fixme check match ID and ID1!!! depend on broadcast 
    receive
	Frame = #can_frame{id=ID1,data= <<?SINGLE:4,_/bitstring>>} ->
	    single_frame(ID1,Frame);
	Frame = #can_frame{id=ID1,data= <<?FIRST:4,_/bitstring>>} ->
	    first_frame(ID1,Frame)
    after Timeout ->
	    timeout
    end.

single_frame(ID,#can_frame{data= <<?SINGLE:4,Len:4,
				   Data:Len/binary,_/binary>>}) ->
    {ID,Data}.

first_frame(ID,#can_frame{data=(<<?FIRST:4, Size:12, Data:6/binary>>)}) ->
    can:send(ID-8,
	     <<?FLOW:4, ?CONTINUE:4, 0, 1, 16#CC,16#CC,16#CC,16#CC,16#CC>>),
    read_next(ID, Size-6, 1, Data).

read_next(ID, Remain, I, Buf) ->
    receive
	#can_frame{id=ID, data=(<<?NEXT:4,I:4, Data/binary>>)} ->
	    Size = byte_size(Data),
	    if Remain > Size ->
		    read_next(ID, Remain-Size, (I+1) band 16#f,
			      <<Buf/binary,Data/binary>>);
	       Remain =:= Size ->
		    {ID, <<Buf/binary,Data/binary>>};
	       true ->
		    <<Data1:Remain/binary,_/binary>> = Data,
		    {ID, <<Buf/binary,Data1/binary>>}
	    end
    end.
