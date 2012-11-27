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

-module(can_sock_drv).

-export([open/0]).
-export([close/1]).
-export([set_loopback/2]).
-export([ifindex/2]).
-export([ifname/2]).
-export([bind/2]).
-export([send/3]).
-export([recv_own_messages/2]).
-export([set_error_filter/2]).

-include("../include/can.hrl").
-include("can_sock_drv.hrl").

-define(CTL_OK,     0).
-define(CTL_ERROR,  1).
-define(CTL_UINT32, 2).
-define(CTL_STRING, 3).

open() ->
    Path = code:priv_dir(can),
    %% {Type,_} = os:type(),
    Driver = "can_sock_drv", 
    case erl_ddll:load(Path, Driver) of
	ok ->
	    Command = Driver,
	    {ok,erlang:open_port({spawn_driver, Command}, [])};
	Err={error,Error} ->
	    io:format("Error: ~s\n", [erl_ddll:format_error_int(Error)]),
	    Err
    end.

close(Port) when is_port(Port) ->
    erlang:port_close(Port).

ifname(Port,Index) when is_port(Port), is_integer(Index), Index>=0 -> 
    call(Port,?CAN_SOCK_DRV_CMD_IFNAME, <<Index:32>>).

ifindex(Port,Name) when is_port(Port) -> 
    Bin = iolist_to_binary(Name),
    call(Port,?CAN_SOCK_DRV_CMD_IFINDEX, Bin).

set_error_filter(Port,Mask) when is_port(Port), is_integer(Mask), Mask>0-> 
    call(Port,?CAN_SOCK_DRV_CMD_SET_ERROR_FILTER, <<Mask:32>>).

set_loopback(Port,Enable) when is_port(Port), is_boolean(Enable) -> 
    Value=if Enable -> 1; true -> 0 end,
    call(Port,?CAN_SOCK_DRV_CMD_SET_LOOPBACK,<<Value:8>>).

recv_own_messages(Port,Enable) when is_port(Port), is_boolean(Enable) -> 
    Value=if Enable -> 1; true -> 0 end,
    call(Port,?CAN_SOCK_DRV_CMD_RECV_OWN_MESSAGES,<<Value:8>>).

bind(Port,Index) when is_port(Port), is_integer(Index), Index>=0 -> 
    call(Port,?CAN_SOCK_DRV_CMD_BIND, <<Index:32>>).

send(Port,Index,Frame) when is_port(Port), is_integer(Index), 
			    is_record(Frame, can_frame) ->
    Pad  = 8-byte_size(Frame#can_frame.data),
    Data = if Pad > 0 ->
		   <<(Frame#can_frame.data)/binary, 0:Pad/unit:8>>;
	      Pad =:= 0 ->
		   Frame#can_frame.data
	   end,
    call(Port, ?CAN_SOCK_DRV_CMD_SEND,
	 <<Index:32,
	   (Frame#can_frame.id):32,
	   (Frame#can_frame.len):8,
	   Data:8/binary,
	   (Frame#can_frame.intf):32,
	   (Frame#can_frame.ts):32>>).

call(Port, Cmd, Args) ->
    R = erlang:port_control(Port, Cmd, Args),
    case R of
	<<?CTL_OK>> ->   ok;
	<<?CTL_ERROR,Error/binary>> -> {error, binary_to_list(Error)};
	<<?CTL_STRING,String/binary>> -> {ok, binary_to_list(String)};
	<<?CTL_UINT32,X:32>> -> {ok, X}
    end.
