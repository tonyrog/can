%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2023, Tony Rogvall
%%% @doc
%%%    Simple speed testing
%%% @end
%%% Created :  2 Jun 2023 by Tony Rogvall <tony@rogvall.se>

-module(can_perf).

-export([sender/0, sender/3, receiver/0, receiver/2]).
-include_lib("can/include/can.hrl").

%% Limit for lawicel CANUSB to receive is around 2074 frames/sec
%% Limit for lawicel CANUSB to send is around 1000 frames/sec? 
%%  when usb latency timer is set = 1 (see uart README) 
%%  or use can_usb:low_latency() to set all serial USB/FTDI devices
sender() ->
    ID = rand:uniform(100),  %% ID = 1..100
    sender(ID, 1000, 1000.0).

sender(ID, Count, Ps) ->
    can_router:attach(),
    can_router:error_reception(on),
    T0 = erlang:monotonic_time(),
    Chan = rand:uniform((1 bsl 32)-1),
    N = sender_(ID, Count, 1, Chan, 0, 0, T0, Ps),
    T1 = erlang:monotonic_time(),
    Time = erlang:convert_time_unit(T1-T0,native,microsecond),
    Fs = N/(Time/1000000),
    io:format("sent: ~w frames, missed ~w, frames/s ~f\n",
	      [Count, Count-N, Fs]).

sender_(ID, 0, _I, Chan, N, _C0, _T0, _Ps) ->
    can:sync_send(can:create(ID,<<0:32, Chan:32>>)),  %% end of transmission
    N;
sender_(ID, Count, I, Chan, N, C0, T0, Ps) ->
    case can:sync_send(can:create(ID,<<I:32, Chan:32>>)) of
	ok ->
	    {C1,T1} = wait(C0+1, T0, Ps),
	    sender_(ID, Count-1, I+1, Chan, N+1, C1, T1, Ps);
	{error,_Error} ->
	    io:format("can_perf: sync_send error: ~p\n", [_Error]),
	    sender_(ID, Count-1, I+1, Chan, N, C0, T0, Ps)
    end.

%% wait so we match Ps packets/sec 
wait(Count, T0, Ps) ->
    T1 = erlang:monotonic_time(),
    D = erlang:convert_time_unit(T1-T0,native,microsecond),
    T = D/1000000,
    if (Count / T) =< Ps ->
	    {Count, T0};
       true ->
	    W = trunc((Count/Ps - T)*1000),
	    %% io:format("wait: ~p\n", [W]),
	    if W > 0 -> 
		    timer:sleep(W),
		    {Count, T0};
	       true ->
		    {Count, T0}
	    end
    end.


receiver() ->
    receiver(5000, 3000).

receiver(InitTimeout, Timeout) ->
    can_router:attach(),
    can_router:error_reception(on),
    receive
	#can_frame{id=_ID, data = <<0:32, _Chan:32>>} ->
	    {error, no_data};
	#can_frame{id=ID, data = <<Num:32, Chan:32>>} ->
	    T0 = erlang:monotonic_time(),
	    {Res,{N,M}} = receiver_(ID, Chan, Timeout, Num+1, 0, 1),
	    T1 = erlang:monotonic_time(),
	    Time = erlang:convert_time_unit(T1-T0,native,microsecond),
	    Fs = N/(Time/1000000),
	    io:format("~s: received: ~w frames, missed ~w, frames/s ~f\n",
		      [Res, N, M, Fs]),
	    Res
    after
	InitTimeout ->
	    {error, no_sender}
    end.

receiver_(ID, Chan, Timeout, Next, M, N) ->    
    receive
	#can_frame{id=ID, data = <<0:32,Chan:32>>} ->
	    {ok, {N, M}};
	#can_frame{id=ID, data = <<Num:32,Chan:32>>} ->
	    D = Num - Next,
	    receiver_(ID, Chan, Timeout, Num+1, M+D, N+1)
    after
	Timeout ->
	    {timeout, {N, M}}
    end.
