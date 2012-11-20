%%%---- BEGIN COPYRIGHT --------------------------------------------------------
%%%
%%% Copyright (C) 2007 - 2012, Rogvall Invest AB, <tony@rogvall.se>
%%%
%%% This software is licensed as described in the file COPYRIGHT, which
%%% you should have received as part of this distribution. The terms
%%% are also available at http://www.rogvall.se/docs/copyright.txt.
%%%
%%% You may opt to use, copy, modify, merge, publish, distribute and/or sell
%%% copies of the Software, and permit persons to whom the Software is
%%% furnished to do so, under the terms of the COPYRIGHT file.
%%%
%%% This software is distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY
%%% KIND, either express or implied.
%%%
%%%---- END COPYRIGHT ----------------------------------------------------------
%%% File    : can.erl
%%% Author  : Tony Rogvall <tony@rogvall.se
%%% Description : can message creator
%%% Created :  7 Jan 2008 by Tony Rogvall 

-module(can).

-include("can.hrl").

-export([send/2, send_ext/2]).
-export([send/1, send_from/2]).
-export([create/5,create/6,create/7]).
-export([send/5, send_from/4, send_from/6]).

%%
%% API for applicatins and backends to create CAN frames
%%
create(ID,Len,Ext,Rtr,Intf,Data) ->
    create(ID,Len,Ext,Rtr,Intf,Data,-1).

create(ID,Len,false,false,Intf,Data,Ts) ->
    create(ID,Len,Intf,Data,Ts);
create(ID,Len,true,false,Intf,Data,Ts) ->
    create(ID bor ?CAN_EFF_FLAG,Len,Intf,Data,Ts);
create(ID,Len,false,true,Intf,Data,Ts) ->
    create(ID bor ?CAN_RTR_FLAG,Len,Intf,Data,Ts);
create(ID,Len,true,true,Intf,Data,Ts) ->
    create(ID bor (?CAN_EFF_FLAG bor ?CAN_RTR_FLAG),Len,Intf,Data,Ts).

create(ID,Len,Intf,Data,Ts) ->    
    Data1 = if is_binary(Data) -> Data;
	      is_list(Data) -> list_to_binary(Data);
	      true -> erlang:error(?can_error_data)
	    end,
    L = size(Data1),
    if ?is_can_id_eff(ID), not ?is_can_id_eff_valid(ID) ->
	    erlang:error(?can_error_id_out_of_range);
       ?is_can_id_sff(ID), not ?is_can_id_sff_valid(ID) ->
	    erlang:error(?can_error_id_out_of_range);
       L > 8 ->
	    erlang:error(?can_error_data_too_large);
       Len < 0; Len > 8 ->
	    erlang:error(?can_error_length_out_of_range);
       ?is_not_can_id_rtr(ID), Len > L ->
	    erlang:error(?can_error_data_too_small);
       true ->
	    #can_frame { id=ID,len=Len,data=Data1,intf=Intf,ts=Ts}
    end.

%%
%% Application interface to send CAN frames
%%

%% Simple SEND
send(ID,Data) ->
    Len = byte_size(Data),
    send(create(ID,Len,false,false,0,Data,0)).

%% Simple SEND extended frame ID format
send_ext(ID,Data) ->
    Len = byte_size(Data),
    send(create(ID,Len,true,false,0,Data,0)).

%% More general    
send(ID,Len,Ext,Rtr,Data) -> 
    send(create(ID,Len,Ext,Rtr,0,Data,0)).

%% Send with application Pid
send_from(Pid,ID,Len,Data) -> 
    send_from(Pid,create(ID,Len,0,Data,0)).

send_from(Pid,ID,Len,Ext,Rtr,Data) -> 
    send_from(Pid,create(ID,Len,Ext,Rtr,0,Data,0)).


%% Send a homebrew can_frame
send(Frame) when is_record(Frame, can_frame) ->
    can_router:send(Frame).

%% Send a homebrew can_frame from application Pid
send_from(Pid,Frame) when is_record(Frame, can_frame) ->
    can_router:send_from(Pid,Frame).






