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
-export([set_filters/2]).
-export([set_fd_frames/2]).
-export([get_mtu/1]).

-include("../include/can.hrl").
-include("can_sock_drv.hrl").

-define(CTL_OK,     0).
-define(CTL_ERROR,  1).
-define(CTL_UINT32, 2).
-define(CTL_STRING, 3).

-define(BOOL(X), if ((X)=:=true) -> 1; ((X)=:=false) -> 0 end).

open() ->
    Path = code:priv_dir(can),
    %% {Type,_} = os:type(),
    Driver = "can_sock_drv", 
    case load_driver(Path, Driver) of
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

set_filters(Port, Fs) when is_port(Port), is_list(Fs) ->
    Bytes = [<<(F#can_filter.id):32,(F#can_filter.mask):32>> || F <- Fs ],
    call(Port,?CAN_SOCK_DRV_CMD_SET_FILTER, Bytes).

set_loopback(Port,Enable) when is_port(Port) -> 
    Value = ?BOOL(Enable),
    call(Port,?CAN_SOCK_DRV_CMD_SET_LOOPBACK,<<Value:8>>).

recv_own_messages(Port,Enable) when is_port(Port) ->
    Value = ?BOOL(Enable),
    call(Port,?CAN_SOCK_DRV_CMD_RECV_OWN_MESSAGES,<<Value:8>>).

set_fd_frames(Port,Enable) when is_port(Port) ->
    Value = ?BOOL(Enable),
    call(Port,?CAN_SOCK_DRV_CMD_SET_FD_FRAMES,<<Value:8>>).

get_mtu(Port) when is_port(Port) ->
    call(Port,?CAN_SOCK_DRV_CMD_GET_MTU,<<>>).

bind(Port,Index) when is_port(Port), is_integer(Index), Index>=0 -> 
    call(Port,?CAN_SOCK_DRV_CMD_BIND, <<Index:32>>).

send(Port,Index,Frame) when is_port(Port), is_integer(Index), 
			    is_record(Frame, can_frame) ->
%%    N = byte_size(Frame#can_frame.data),
%%    M = if N>8 -> 64; true -> 8 end,
%%    Pad = if N > 8 -> M-N;
%%	     true -> M-N
%%	  end,
%%    Data = if Pad > 0 ->
%%		   <<(Frame#can_frame.data)/binary, 0:Pad/unit:8>>;
%%	      Pad =:= 0 ->
%%		   Frame#can_frame.data
%%	   end,
    Cmd = if ?is_can_frame_fd(Frame) ->
		  ?CAN_SOCK_DRV_CMD_SEND_FD;
	     true ->
		   ?CAN_SOCK_DRV_CMD_SEND
	  end,
    call(Port, Cmd,
	 <<Index:32,
	   (Frame#can_frame.id):32,
	   (Frame#can_frame.intf):32,
	   (Frame#can_frame.ts):32,
	   (Frame#can_frame.len):8,
	   (Frame#can_frame.data)/binary>>).


call(Port, Cmd, Args) ->
    R = erlang:port_control(Port, Cmd, Args),
    case R of
	<<?CTL_OK>> ->   ok;
	<<?CTL_ERROR,Error/binary>> -> {error, binary_to_list(Error)};
	<<?CTL_STRING,String/binary>> -> {ok, binary_to_list(String)};
	<<?CTL_UINT32,X:32>> -> {ok, X}
    end.

%% can be replaced with dloader later
load_driver(Path, Name) ->
    Ext = filename:extension(Name),
    Base = filename:basename(Name,Ext),
    NameExt = case os:type() of
		  {unix,_} ->  Base++".so";
		  {win32,_} -> Base++".dll"
	      end,
    SysPath = filename:join(Path,erlang:system_info(system_architecture)),
    case filelib:is_regular(filename:join(SysPath,NameExt)) of
	true -> erl_ddll:load(SysPath, Name);
	false ->
	    case filelib:is_regular(filename:join(Path,NameExt)) of
		true -> erl_ddll:load(Path, Name);
		false -> {error, enoent}
	    end
    end.
