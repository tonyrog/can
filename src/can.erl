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

-export([start/0]).
-export([send/2, send_ext/2, send_fd/2]).
-export([send/1, send_from/2]).
-export([sync_send/1, sync_send_from/2]).
-export([create/2, create/3, create/4, create/6, create/7, create/8]).
-export([icreate/5]).
-export([send/5, send_from/4, send_from/6]).

-export([pause/0, resume/0, ifstatus/0]).
-export([pause/1, resume/1, ifstatus/1]).

-include("../include/can.hrl").

start() ->
    (catch error_logger:tty(false)),
    ?start_logging(),
    application:start(uart),
    application:start(can).

%%--------------------------------------------------------------------
%% @doc
%% Pause an interface.
%% @end
%%--------------------------------------------------------------------
-spec pause(If::integer() | string()) -> ok | {error, Reason::term()}.
pause(If) when is_integer(If); is_list(If) ->
    can_router:pause(If).

-spec pause() -> {error, Reason::term()}.
pause() ->
    {error, interface_required}.

%%--------------------------------------------------------------------
%% @doc
%% Resume an interface.
%% @end
%%--------------------------------------------------------------------
-spec resume(If::integer() | string()) -> ok | {error, Reason::term()}.
resume(If) when is_integer(If); is_list(If) ->
    can_router:resume(If).
    
-spec resume() -> {error, Reason::term()}.
resume() ->
    {error, interface_required}.

%%--------------------------------------------------------------------
%% @doc
%% Get active status of interface.
%% @end
%%--------------------------------------------------------------------
-spec ifstatus(If::integer() | string()) ->
		      {ok, Status::atom()} | {error, Reason::term()}.
ifstatus(If) when is_integer(If); is_list(If) ->
    can_router:ifstatus(If).
    
-spec ifstatus() -> {error, Reason::term()}.
ifstatus() ->
    {error, interface_id_required}.
%%
%% API for applicatins and backends to create CAN frames
%%
create(ID,Data) ->
    create(ID,0,Data).

create(ID,Intf,Data) ->
    Ext = (ID > ?CAN_SFF_MASK),
    create(ID,erlang:iolist_size(Data),Ext,false,false,
	   Intf,Data,?CAN_NO_TIMESTAMP).

create(ID,Len,Intf,Data) ->
    Ext = (ID > ?CAN_SFF_MASK),
    create(ID,Len,Ext,false,false,Intf,Data,?CAN_NO_TIMESTAMP).

create(ID,Len,Ext,Rtr,Intf,Data) ->
    create(ID,Len,Ext,Rtr,false,Intf,Data,?CAN_NO_TIMESTAMP).

create(ID,Len,Ext,Rtr,FD,Intf,Data) ->
    create(ID,Len,Ext,Rtr,FD,Intf,Data,?CAN_NO_TIMESTAMP).

create(ID0,Len,Ext,Rtr,FD,Intf,Data,Ts) ->
    ID1 = if Ext -> ID0 bor ?CAN_EFF_FLAG;
	     true -> ID0
	  end,
    ID2 = if FD -> ID1 bor ?CAN_FD_FLAG;
	     true -> ID1
	  end,
    ID = if Rtr -> ID2 bor ?CAN_RTR_FLAG;
	    true -> ID2
	 end,
    icreate(ID,Len,Intf,Data,Ts).

icreate(ID0,Len,Intf,Data,Ts) ->
    Data1 = iolist_to_binary(Data),
    L = byte_size(Data1),
    ID = if L > 8 -> ID0 bor ?CAN_FD_FLAG;
	    true -> ID0
	 end,
    if ?is_can_id_eff(ID), not ?is_can_id_eff_valid(ID) ->
	    erlang:error(?can_error_id_out_of_range);
       ?is_can_id_sff(ID), not ?is_can_id_sff_valid(ID) ->
	    erlang:error(?can_error_id_out_of_range);
       L < 0 ->
	    erlang:error(?can_error_length_out_of_range);
       L > 8, ?is_not_can_fd(ID) ->
	    erlang:error(?can_error_data_too_large);
       L > 64 ->
	    erlang:error(?can_error_data_too_large);
       Len < 0 ->
	    erlang:error(?can_error_length_out_of_range);
       Len > 15, ?is_not_can_fd(ID)  ->
	    erlang:error(?can_error_length_out_of_range);
       Len > 64 ->
	    erlang:error(?can_error_length_out_of_range);
       ?is_not_can_id_rtr(ID), Len > L, ?is_not_can_fd(ID) ->
	    erlang:error(?can_error_length_out_of_range);
       true ->
	    #can_frame { id=ID,len=Len,data=Data1,intf=Intf,ts=Ts}
    end.

%%
%% Application interface to send CAN frames
%%

%% Simple SEND
send(ID,Data) ->
    Ext = (ID > ?CAN_SFF_MASK),
    Len = erlang:iolist_size(Data),
    send(create(ID,Len,Ext,false,false,0,Data,?CAN_NO_TIMESTAMP)).

%% Simple SEND extended frame ID format
send_ext(ID,Data) ->
    Len = erlang:iolist_size(Data),
    send(create(ID,Len,true,false,false,0,Data,?CAN_NO_TIMESTAMP)).

%% Simple send FD frame
send_fd(ID,Data) ->
    Ext = (ID > ?CAN_SFF_MASK),
    Len = erlang:iolist_size(Data),
    send(create(ID,Len,Ext,false,true,0,Data,?CAN_NO_TIMESTAMP)).

%% More general
send(ID,Len,Ext,Rtr,Data) ->
    send(create(ID,Len,Ext,Rtr,false,0,Data,?CAN_NO_TIMESTAMP)).

%% Send with application Pid
send_from(Pid,ID,Len,Data) ->
    send_from(Pid,create(ID,Len,0,Data)).

send_from(Pid,ID,Len,Ext,Rtr,Data) ->
    send_from(Pid,create(ID,Len,Ext,Rtr,false,0,Data,?CAN_NO_TIMESTAMP)).

%% Send a homebrew can_frame
send(Frame) when is_record(Frame, can_frame) ->
    can_router:send(Frame).

sync_send(Frame) when is_record(Frame, can_frame) ->
    can_router:sync_send(Frame).

%% Send a homebrew can_frame from application Pid
send_from(Pid,Frame) when is_record(Frame, can_frame) ->
    can_router:send_from(Pid,Frame).

sync_send_from(Pid,Frame) when is_record(Frame, can_frame) ->
    can_router:sync_send_from(Pid,Frame).
