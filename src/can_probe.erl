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
%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2010, Tony Rogvall
%%% @doc
%%%     CAN frame probe
%%% @end
%%% Created : 12 Jun 2010 by Tony Rogvall <tony@rogvall.se>

-module(can_probe).

-export([start/0,start/1,start/2,stop/1,init/1]).
-export([format_frame/1]).

-include_lib("can/include/can.hrl").

start() ->
    start([]).

start(Opts) ->
    can_udp:start(),  %% testing
    spawn_link(?MODULE, init, [Opts]).

start(BusId, IOpts) when is_integer(BusId) ->
    can_udp:start(BusId, IOpts).

stop(Pid) ->
    Pid ! stop.

init(Opts) ->
    can_router:attach(),
    case proplists:get_value(max_time, Opts, infinity) of
	infinity -> ok;
	Time -> erlang:start_timer(Time, self(), done)
    end,
    MaxFrames = proplists:get_value(max_frame, Opts, -1),
    T0 = now(),
    loop(T0, MaxFrames).

loop(_T, 0) ->
    ok;
loop(T0, FrameCount) ->
    receive
	Frame = #can_frame {} ->
	    print_frame(timer:now_diff(now(),T0), Frame),
	    loop(T0, FrameCount - 1);
	{timeout, _Ref, done} ->
	    ok;
	stop ->
	    ok
    end.

format_frame(Frame) ->
    ["ID: ", if ?is_can_frame_eff(Frame) ->
		    io_lib:format("~8.16.0B", 
				  [Frame#can_frame.id band ?CAN_EFF_MASK]);
		true ->
		     io_lib:format("~3.16.0B", 
				   [Frame#can_frame.id band ?CAN_SFF_MASK])
	     end,
     " LEN:", io_lib:format("~w", [Frame#can_frame.len]),
     if ?is_can_frame_eff(Frame) ->
	     " EXT";
	true ->
	     ""
     end,
     if Frame#can_frame.intf>0 ->
	     [" INTF:", io_lib:format("~w", [Frame#can_frame.intf])];
	true ->
	     []
     end,
     if ?is_can_frame_rtr(Frame) ->
	     " RTR";
	true ->
	     [" DATA:", format_data(Frame#can_frame.data)]
     end,
     if ?is_can_valid_timestamp(Frame) ->
	     ["TS:", io_lib:format("~w", [Frame#can_frame.ts])];
	true -> []
     end
    ].

format_data(<<H,T/binary>>) ->
    [io_lib:format("~2.16.0B", [H]) | format_data(T)];
format_data(<<>>) ->
    [].
	
print_frame(T, Frame) ->
    S = T div 1000000,
    Us = T rem 1000000,
    io:format("~w.~w: ~s\n", [S,Us,format_frame(Frame)]).

    
