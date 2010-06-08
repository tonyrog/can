%%% File    : can.erl
%%% Author  : Tony Rogvall <tony@PBook.lan>
%%% Description : can message creator
%%% Created :  7 Jan 2008 by Tony Rogvall <tony@PBook.lan>

-module(can).

-include("can.hrl").

-export([send/1, send_from/2]).
-export([create/6,create/7]).
-export([send/6, send_from/7]).

create(ID,Len,Ext,Rtr,Intf,Data) ->
    create(ID,Len,Ext,Rtr,Intf,Data,undefined).

create(ID,Len,Ext,Rtr,Intf,Data,Ts) ->
    Data1 = if is_binary(Data) -> Data;
	      is_list(Data) -> binary_to_list(Data);
	      true -> erlang:error(?CAN_ERROR_DATA)
	    end,
    L = size(Data1),
    if  Ext=:=true, not ?CAN29_ID_VALID(ID) ->
	    erlang:error(?CAN_ERROR_ID_OUT_OF_RANGE);
       Ext=:=false, not ?CAN11_ID_VALID(ID) ->
	    erlang:error(?CAN_ERROR_ID_OUT_OF_RANGE);
       L > 8 ->
	    erlang:error(?CAN_ERROR_DATA_TOO_LARGE);
       Len < 0; Len > 8 ->
	    erlang:error(?CAN_ERROR_LENGTH_OUT_OF_RANGE);
       Rtr =:= false, Len > L ->
	    erlang:error(?CAN_ERROR_DATA_TOO_SMALL);
       true ->
	    #can_frame { id=ID,rtr=Rtr,ext=Ext,intf=Intf,
			   len=Len,data=Data1,ts=Ts}
    end.

send(ID,Len,Ext,Rtr,Intf,Data) -> 
    send(create(ID,Len,Ext,Rtr,Intf,Data,0)).

send_from(Pid,ID,Len,Ext,Rtr,Intf,Data) -> 
    send_from(Pid,create(ID,Len,Ext,Rtr,Intf,Data,0)).

send(M) when is_record(M, can_frame) ->
    can_router:send(M).

send_from(Pid,M) when is_record(M, can_frame) ->
    can_router:send_from(Pid,M).






