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
%%%-------------------------------------------------------------------
%%% File    : can_usb.erl
%%% Author  : Tony Rogvall <tony@rogvall.se>
%%% Description : CAN USB (VC) interface 
%%%
%%% Created : 17 Sep 2009 by Tony Rogvall <tony@rogvall.se>
%%%-------------------------------------------------------------------
-module(can_usb).

-behaviour(gen_server).

-include_lib("lager/include/log.hrl").
-include("../include/can.hrl").

%% API
-export([start/0, start/1, start/2]).
-export([stop/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-compile(export_all).

-record(s, 
	{
	  id,              %% interface id
	  uart,            %% serial line port id
	  device,          %% device name
	  offset,          %% Usb port offset
	  baud_rate,       %% baud rate to canusb
	  can_speed,       %% CAN bus speed
	  status_interval, %% Check status interval
	  status_timer,    %% Check status timer
	  retry_timeout,   %% Timeout for open retry
	  acc = [],        %% accumulator for command replies
	  buf = <<>>,      %% parse buffer
	  stat,            %% counter dictionary
	  fs,              %% can_router:fs_new()
	  debug=false      %% debug output (when debug compiled)
	 }).

-define(SERVER, ?MODULE).

-define(COMMAND_TIMEOUT, 500).

-define(BITADD(Code, Bit, Name),
	if (Code) band (Bit) =:= 0 -> [];
 	   true  -> [(Name)]
	end).

%%
%% Some known devices (by me)
%% /dev/tty.usbserial-LWQ8CA1K   (R550)
%%
%% Options:
%%   {bitrate, Rate}         default 250000 KBit/s
%%   {status_interval, Tms}  default 1000 = 1s
%%
start() ->
    start(1,[]).

start(BusId) ->
    start(BusId,[]).

start(BusId, Opts) ->
    can_router:start(),
    gen_server:start(?MODULE, [BusId,Opts], []).

stop(Pid) ->
    gen_server:call(Pid, stop).

set_bitrate(Pid, BitRate) ->
    gen_server:call(Pid, {set_bitrate, BitRate}).

get_bitrate(Pid) ->
    gen_server:call(Pid, get_bitrate).

get_version(Pid) ->
    case gen_server:call(Pid, {command, "V"}) of
	{ok, [$V,H1,H0,S1,S0]} ->
	    {ok, {H1-$0,H0-$0}, {S1-$0,S0-$0}};
	Error ->
	    Error
    end.

get_serial(Pid) ->
    case gen_server:call(Pid, {command, "N"}) of
	{ok, [$N|BCDSn]} ->
	    {ok, BCDSn};
	Error ->
	    Error
    end.

%% enable/disable timestamp - only when channel is closed!
enable_timestamp(Pid) ->
    case gen_server:call(Pid, {command, "Z1"}) of
	{ok, _} ->
	    ok;
	Error ->
	    Error
    end.

disable_timestamp(Pid) ->
    case gen_server:call(Pid, {command, "Z0"}) of
	{ok, _} ->
	    ok;
	Error ->
	    Error
    end.

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%
%%--------------------------------------------------------------------

get_value(Key, EnvKey, Args, Default) ->
    case os:getenv(EnvKey) of
	false ->
	    proplists:get_value(Key, Args, Default);
	Value when is_integer(Default) ->
	    list_to_integer(Value);
	Value ->
	    Value
    end.

init([Id,Args]) ->
    lager:start(),  %% ok testing, remain or go?
    DevKey = "CANUSB_DEVICE_" ++ integer_to_list(Id),
    Device = case get_value(device, DevKey, Args, "") of
		 "" ->
		     case os:type() of
			 {unix, darwin} -> "/dev/tty.usbserial";
			 {unix,linux} -> "/dev/ttyUSB0";
			 {win32,_} -> "COM10";
			 {_, _} -> "/dev/serial"
		     end;
		 Dev -> Dev
	     end,
    Speed = get_value(baud, "CANUSB_SPEED", Args, 115200),
    RetryTimeout = proplists:get_value(timeout, Args, 1),
    BitRate = proplists:get_value(bitrate,Args,250000),
    Interval = proplists:get_value(status_interval,Args,1000),
    case proplists:get_bool(debug, Args) of
	true ->
	    lager:set_loglevel(lager_console_backend, debug);
	_ ->
	    ok
    end,
    S = #s { device = Device,
	     offset = Id,
	     stat = dict:new(),
	     baud_rate = Speed,
	     can_speed = BitRate,
	     status_interval = Interval,
	     retry_timeout = RetryTimeout,
	     fs=can_router:fs_new()
	   },

    case open(S) of
	{ok, S1} -> {ok, S1};
	Error -> {stop, Error}
    end.


open(S0=#s {device = DeviceName, baud_rate = Speed, offset = Offset, 
	    status_interval = Interval, can_speed = BitRate }) ->

    DOpts = [{mode,binary},{baud,Speed},{packet,0},
	     {csize,8},{stopb,1},{parity,none},{active,true}
	     %% {buftm,1},{bufsz,128}
	    ],    
    case uart:open(DeviceName,DOpts) of
	{ok,U} ->
	    lager:debug("canusb:open: ~s@~w", [DeviceName,Speed]),
	    case can_router:join({?MODULE,DeviceName,Offset}) of
		{ok,ID} ->
		    lager:debug("canusb:joined: intf=~w", [ID]),
		    Timer = erlang:start_timer(Interval,self(),status),
		    S = S0#s { id=ID, uart=U, status_timer=Timer },
		    canusb_sync(S),
		    canusb_set_bitrate(S, BitRate),
		    command_open(S),
		    {ok, S};
		false ->
		    {error, sync_error}
	    end;
	{error, E} when E == eaccess;
			E == enoent ->
	    RetryTimeout = S0#s.retry_timeout,
	    lager:error("canusb:open: error ~w, will try again "
			"in ~p secs.", [E,RetryTimeout]),
	    timer:send_after(RetryTimeout * 1000, retry),
	    {ok, S0};
	Error ->
	    lager:error("canusb:open: error ~w", [Error]),
	    Error
    end.
    
%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({send,Mesg}, _From, S) ->
    {Reply,S1} = send_message(Mesg,S),
    {reply, Reply, S1};
handle_call(statistics,_From,S) ->
    Stat = dict:to_list(S#s.stat),
    {reply,{ok,Stat}, S};
handle_call({set_bitrate,Rate}, _From, S) ->
    case canusb_set_bitrate(S, Rate) of
	{ok, _Reply, S1} ->
	    {reply, ok, S1#s { can_speed=Rate}};
	{Error,S1} ->
	    {reply, Error, S1}
    end;
handle_call(get_bitrate, _From, S) ->
    {reply, {ok,S#s.can_speed}, S};
handle_call({command,Cmd}, _From, S) ->
    case command(S, Cmd) of
	{ok,Reply,S1} ->
	    {reply, {ok,Reply}, S1};
	{Error,S1} ->
	    {reply, Error, S1}
    end;
handle_call({add_filter,I,F}, _From, S) ->
    Fs = can_router:fs_add(I,F,S#s.fs),
    {reply, ok, S#s { fs=Fs }};
handle_call({del_filter,I}, _From, S) ->
    {Reply,Fs} = can_router:fs_del(I,S#s.fs),
    {reply, Reply, S#s { fs=Fs }};
handle_call(stop, _From, S) ->
    {stop, normal, ok, S};
handle_call(_Request, _From, S) ->
    {reply, {error,bad_call}, S}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast({send,Mesg}, S) ->
    {_, S1} = send_message(Mesg, S),
    {noreply, S1};

handle_cast({statistics,From},S) ->
    Stat = dict:to_list(S#s.stat),
    gen_server:reply(From, {ok,Stat}),
    {noreply, S};
handle_cast({add_filter,From,F}, S) ->
    {I,Fs} = can_router:fs_add(F,S#s.fs),
    gen_server:reply(From, {ok,I}),
    {noreply, S#s { fs=Fs }};
handle_cast({del_filter,From,I}, S) ->
    {Reply,Fs} = can_router:fs_del(I,S#s.fs),
    gen_server:reply(From, Reply),
    {noreply, S#s { fs=Fs }};
handle_cast({get_filter,From,I}, S) ->
    Reply = can_router:fs_get(I,S#s.fs),
    gen_server:reply(From, Reply),
    {noreply, S};  
handle_cast({list_filter,From}, S) ->
    Reply = can_router:fs_list(S#s.fs),
    gen_server:reply(From, Reply),
    {noreply, S};
handle_cast(_Mesg, S) ->
    lager:debug("can_usb: handle_cast: ~p\n", [_Mesg]),
    {noreply, S}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({uart,U,Data}, S) when S#s.uart == U ->
    NewBuf = <<(S#s.buf)/binary, Data/binary>>,
    lager:debug("handle_info: NewBuf=~p", [NewBuf]),
    {_,S1} = parse_all(S#s { buf = NewBuf}),
    lager:debug("handle_info: RemainBuf=~p", [S1#s.buf]),
    {noreply, S1};

handle_info({uart_error,U,Reason}, S) when U =:= S#s.uart ->
    if Reason =:= enxio ->
	    lager:error("uart error ~p device ~s unplugged?", 
			[Reason,S#s.device]);
       true ->
	    lager:error("uart error ~p for device ~s", 
			[Reason,S#s.device])
    end,
    {noreply, S};
handle_info({uart_closed,U}, S) when U =:= S#s.uart ->
    uart:close(U),
    RetryTimeout = S#s.retry_timeout,
    lager:error("uart device closed, will try again in ~p secs.",
		[RetryTimeout]),
    timer:send_after(RetryTimeout * 1000, retry),
    {noreply, S#s { uart=undefined }};

handle_info({timeout,Ref,status}, S) when Ref =:= S#s.status_timer ->
    case command(S, "F") of
	{ok, [$F|Status], S1} ->
	    try erlang:list_to_integer(Status, 16) of
		0 -> 
		    {noreply,start_timer(S1)};
		Code ->
		    S2 = error_input(Code, S1),
		    S3 = start_timer(S2),
		    {noreply,S3}
	    catch
		error:Reason ->
		    lager:error("can_usb: status error: ~p", [Reason]),
		    {noreply,start_timer(S1)}
	    end;
	{ok, Status, S1} ->
	    lager:error("can_usb: status error: ~p", [Status]),
	    {noreply, start_timer(S1)};	    
	{{error,Reason}, S1} ->
	    lager:error("can_usb: status error: ~p", [Reason]),
	    {noreply, start_timer(S1)}
    end;
handle_info(retry, S) ->
    case open(S) of
	{ok, S1} -> {noreply, S1};
	Error -> {stop, Error, S}
    end;

handle_info(_Info, S) ->
    {noreply, S}.
    
%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

start_timer(S) ->
    Timer = erlang:start_timer(S#s.status_interval,self(),status),
    S#s { status_timer = Timer }.

send_message(Mesg, S) when is_record(Mesg,can_frame) ->
    if is_binary(Mesg#can_frame.data) ->
	    send_bin_message(Mesg, Mesg#can_frame.data, S);
       true ->
	    output_error(?can_error_data,S)
    end;
send_message(_Mesg, S) ->
    output_error(?can_error_data,S).

send_bin_message(Mesg, Bin, S) when byte_size(Bin) =< 8 ->
    send_message(Mesg#can_frame.id,
		 Mesg#can_frame.len,
		 Bin,
		 S);
send_bin_message(_Mesg, _Bin, S) ->
    output_error(?can_error_data_too_large,S).

send_message(ID, L, Data, S) ->
    if ?is_can_id_sff(ID), ?is_not_can_id_rtr(ID) ->
	    ID1 = ID band ?CAN_SFF_MASK,
	    send_frame(S, [$t,to_hex(ID1,3), L+$0, to_hex_min(Data,L)]);
       ?is_can_id_eff(ID), ?is_not_can_id_rtr(ID) ->
	    ID1 = ID band ?CAN_EFF_MASK,
	    send_frame(S, [$T,to_hex(ID1,8), L+$0, to_hex_min(Data,L)]);
       ?is_can_id_sff(ID), ?is_can_id_rtr(ID) ->
	    ID1 = ID band ?CAN_SFF_MASK,
	    send_frame(S, [$r,to_hex(ID1,3), L+$0, to_hex_max(Data,8)]);
       ?is_can_id_eff(ID), ?is_can_id_rtr(ID) ->
	    ID1 = ID band ?CAN_EFF_MASK,
	    send_frame(S, [$R,to_hex(ID1,8), L+$0, to_hex_max(Data,8)]);
       true ->
	    output_error(?can_error_data,S)
    end.

send_frame(S, Frame) ->
    case command(S, Frame) of
	{ok,_Reply,S1} ->
	    {ok, count(output_frames, S1)};
	{{error,Reason},S1} ->
	    output_error(Reason,S1)
    end.

ihex(I) ->
    element(I+1, {$0,$1,$2,$3,$4,$5,$6,$7,$8,$9,$A,$B,$C,$D,$E,$F}).

%% minimum L elements - fill with 0  
to_hex_min(_,0) -> [];
to_hex_min(<<>>,I) -> [$0|to_hex_min(<<>>,I-1)];
to_hex_min(<<H1:4,H2:4,Rest/binary>>,I) ->
    [ihex(H1),ihex(H2) | to_hex_min(Rest,I-1)].

%% maximum L element - no fill
to_hex_max(<<>>, _) -> [];
to_hex_max(_, 0) -> [];
to_hex_max(<<H1:4,H2:4,Rest/binary>>,I) ->
    [ihex(H1),ihex(H2) | to_hex_max(Rest,I-1)].

to_hex(V, N) when is_integer(V) ->
    to_hex(V, N, []).

to_hex(_V, 0, Acc) -> Acc;
to_hex(V, N, Acc) ->
    to_hex(V bsr 4,N-1, [ihex(V band 16#f) | Acc]).



canusb_sync(S) ->
    command_nop(S),
    command_nop(S),
    command_nop(S),
    command_close(S),
    command_nop(S),
    true.

canusb_set_bitrate(S, BitRate) ->
    case BitRate of
	10000  -> command(S, "S0");
	20000  -> command(S, "S1");
	50000  -> command(S, "S2");
	100000 -> command(S, "S3");
	125000 -> command(S, "S4");
	250000 -> command(S, "S5");
	500000 -> command(S, "S6");
	800000 -> command(S, "S7");
	1000000 -> command(S, "S8");
	_ -> {{error,bad_bit_rate}, S}
    end.

command_nop(S) ->
    command(S, "").
	
command_open(S) ->
    command(S, "O").

command_close(S) ->
    command(S, "C").

%%
%% command(S, Command [,Timeout]) ->
%%    {ok,Reply,S'}
%%  | {{error,Reason}, S'}
%%
command(S, Command) ->
    command(S, Command, ?COMMAND_TIMEOUT).

command(S, Command, Timeout) ->
    lager:debug("can_usb:command: [~p]", [Command]),
    if S#s.uart =:= undefined ->
	    {{error,eagain},S};
       true ->
	    uart:send(S#s.uart, [Command, $\r]),
	    wait_reply(S,Timeout)
    end.

wait_reply(S,Timeout) ->
    receive
	{uart,U,Data} when U==S#s.uart ->
	    lager:debug("can_usb:data: ~p", [Data]),	    
	    Data1 = <<(S#s.buf)/binary,Data/binary>>,
	    case parse(Data1, [], S#s{ buf=Data1 }) of
		{more,S1} ->
		    wait_reply(S1,Timeout);
		{ok,Reply,S1} ->
		    lager:debug("can_usb:wait_reply: ok", []),
		    {_, S2} = parse_all(S1),
		    {ok,Reply,S2};
		{Error,S1} ->
		    lager:debug("can_usb:wait_reply: ~p", [Error]),
		    {_, S2} = parse_all(S1),
		    {Error,S2}
	    end
    after Timeout ->
	    {{error,timeout},S}
    end.

ok(Buf,Acc,S)   -> {ok,lists:reverse(Acc),S#s { buf=Buf,acc=[]}}.
error(Reason,Buf,S) -> {{error,Reason}, S#s { buf=Buf, acc=[]}}.

count(Item,S) ->
    Stat = dict:update_counter(Item, 1, S#s.stat),
    S#s { stat = Stat }.

output_error(Reason,S) ->
    {{error,Reason},oerr(Reason,S)}.

oerr(Reason,S) ->
    lager:debug("can_usb:output error: ~p", [Reason]),
    S1 = count(output_error, S),
    count({output_error,Reason}, S1).    

ierr(Reason,S) ->
    lager:debug("can_usb:input error: ~p", [Reason]),
    S1 = count(input_error, S),
    count({input_error,Reason}, S1).

%% Parse until more data is needed
parse_all(S) ->
    case parse(S#s.buf, [], S) of
	{more,S1} ->
	    {more, S1};
	{ok,_,S1} -> 
	    %% replies to command should? not be interleaved, check?
	    parse_all(S1);
	{_Error,S1} ->
	    lager:debug("can_usb:parse_all: ~p, ~p", [_Error,S#s.buf]),
	    parse_all(S1)
    end.

%% Parse one reply while accepting new frames    
parse(<<>>, Acc, S) ->
    {more, S#s { acc=Acc} };
parse(Buf0, Acc, S) ->
    case Buf0 of
	<<$\s, Buf/binary>>     -> parse(Buf,[$\s|Acc],S);
	<<$\t, Buf/binary>>     -> parse(Buf,[$\t|Acc],S);
	<<27,Buf/binary>>       -> parse(Buf,[27|Acc],S);
	<<$\r,$\n, Buf/binary>> -> ok(Buf,Acc,S);
	<<$z,$\r, Buf/binary>>  -> ok(Buf,Acc,S);  %% message sent
	<<$Z,$\r, Buf/binary>>  -> ok(Buf,Acc,S);  %% message sent
	<<$\r, Buf/binary>>     -> ok(Buf,Acc,S);
	<<$\n, Buf/binary>>     -> ok(Buf,Acc,S);
	<<7, Buf/binary>>       -> error(command,Buf,S);
	<<$t,Buf/binary>>       -> parse_11(Buf,false,S#s{buf=Buf0});
	<<$r,Buf/binary>>       -> parse_11(Buf,true,S#s{buf=Buf0});
	<<$T,Buf/binary>>       -> parse_29(Buf,false,S#s{buf=Buf0});
	<<$R,Buf/binary>>       -> parse_29(Buf,true,S#s{buf=Buf0});
	<<C,Buf/binary>>        -> parse(Buf,[C|Acc],S)  %% emit warning?
    end.

sync(S) ->
    sync(S#s.buf, S).

%% sync bad data looking for \r (or \n )
sync(<<$\r,$\n, Buf/binary>>, S) -> S#s { buf=Buf };
sync(<<$\r, Buf/binary>>, S)     -> S#s { buf=Buf };
sync(<<$\n, Buf/binary>>, S)     -> S#s { buf=Buf };
sync(<<7, Buf/binary>>, S)       -> S#s { buf=Buf };
sync(<<_, Buf/binary>>, S)       -> sync(Buf, S);
sync(Buf, S) -> S#s { buf=Buf }.

%% Sync a count error
parse_error(Reason, S) ->
    S1 = sync(S),
    parse(S1#s.buf,[],ierr(Reason,S1)).

%% Parse a t or r (11-bit) frame
%% Buf0 is the start of start of frame data
parse_11(<<I2,I1,I0,L,Ds/binary>>,Rtr,S) ->
    if L >= $0, L =< $8 ->
	    try erlang:list_to_integer([I2,I1,I0],16) of
		ID ->
		    parse_message(ID,L-$0,false,Rtr,Ds,S)
	    catch
		error:_ ->
		    %% bad frame ID
		    parse(Ds,[],ierr(?can_error_corrupt,S))
	    end;
       true ->
	    parse(Ds,[],ierr(?can_error_length_out_of_range,S))
    end;
parse_11(_Buf,_Rtr,S) ->
    {more, S}.

parse_29(<<I7,I6,I5,I4,I3,I2,I1,I0,L,Ds/binary>>,Rtr,S) ->
    if L >= $0, L =< $8 ->
	    try erlang:list_to_integer([I7,I6,I5,I4,I3,I2,I1,I0],16) of
		ID ->
		    parse_message(ID,L-$0,true,Rtr,Ds,S)
	    catch
		error:_ ->
		    %% bad frame ID
		    parse(Ds,[],ierr(?can_error_corrupt,S))
	    end;
       true ->
	    parse(Ds,[],ierr(?can_error_length_out_of_range,S))
    end;
parse_29(_Buf,_Rtr,S) ->
    {more, S}.
    

parse_message(ID,Len,Ext,Rtr,Ds,S) ->
    case parse_data(Len,Rtr,Ds,[]) of
	{ok,Data,Ts,More} ->
	    try can:create(ID,Len,Ext,Rtr,S#s.id,Data,Ts) of
		Frame ->
		    S1 = input(Frame, S#s {buf=More}),
		    parse(More,[],S1)
	    catch
		error:Reason  when is_atom(Reason) ->
		    parse_error(Reason, S);
		error:_Reason ->
		    parse_error(?can_error_corrupt,S)
	    end;
	more ->
	    {more, S};
	{{error,Reason},_Buf} ->
	    parse_error(Reason, S)
    end.

parse_data(L,Rtr,<<Z3,Z2,Z1,Z0,$\r,Buf/binary>>, Acc) when L=:=0; Rtr=:=true->
    case catch erlang:list_to_integer([Z3,Z2,Z1,Z0],16) of
	{'EXIT',_} -> %% ignore ?
	    {ok, list_to_binary(lists:reverse(Acc)), -1, Buf};
	Stamp ->
	    {ok, list_to_binary(lists:reverse(Acc)), Stamp, Buf}
    end;
parse_data(L,Rtr,<<$\r,Buf/binary>>, Acc) when L=:=0; Rtr=:=true ->
    {ok,list_to_binary(lists:reverse(Acc)), -1, Buf};
parse_data(L,Rtr,<<$\n,Buf/binary>>, Acc)  when L=:=0; Rtr=:=true ->
    {ok,list_to_binary(lists:reverse(Acc)), -1, Buf};
parse_data(L,Rtr,<<H1,H0,Buf/binary>>, Acc) when L > 0 ->
    try erlang:list_to_integer([H1,H0],16) of
	H ->
	    parse_data(L-1,Rtr,Buf,[H|Acc])
    catch 
	error:_ ->
	    {{error,?can_error_corrupt}, Buf}
    end;
parse_data(0,_Rtr,<<>>,_Acc) ->
    more;
parse_data(L,Rtr,_Buf,_Acc) when L > 0, Rtr =:= false ->
    more;
parse_data(_L,_Rtr,Buf,_Acc) ->
    {{error,?can_error_corrupt}, Buf}.


input(Frame, S) ->
    case can_router:fs_input(Frame, S#s.fs) of
	true ->
	    can_router:input(Frame),
	    count(input_frames, S);
	false ->
	    S1 = count(input_frames, S),
	    count(filter_frames, S1)
    end.


%% Error codes return by CANUSB
-define(CANUSB_ERROR_RECV_FIFO_FULL,   16#01).
-define(CANUSB_ERROR_SEND_FIFO_FULL,   16#02).
-define(CANUSB_ERROR_WARNING,          16#04).
-define(CANUSB_ERROR_DATA_OVER_RUN,    16#08).
-define(CANUSB_ERROR_RESERVED_10,      16#10).
-define(CANUSB_ERROR_PASSIVE,          16#20).
-define(CANUSB_ERROR_ARBITRATION_LOST, 16#40).
-define(CANUSB_ERROR_BUS,              16#80).

error_input(Code, S) ->
    case error_frame(Code band 16#FF, S#s.id) of
	false -> S;
	{true,Frame} ->
	    case can_router:fs_input(Frame, S#s.fs) of
		true ->
		    can_router:input(Frame),
		    count(error_frames, S);
		false ->
		    S1 = count(error_frames, S),
		    count(filter_frames, S1)
	    end
    end.

error_frame(Code, Intf) ->
    error_frame(Code, Intf, 0, 0, 0, 0, 0, 0).

error_frame(Code, ID, Intf, D0, D1, D2, D3, D4) ->
    if Code =:= 0, ID =:= 0 -> false;
       Code =:= 0 ->
	    {true,
	     #can_frame { id=ID bor ?CAN_ERR_FLAG,
			  len=8, 
			  data = <<D0,D1,D2,D3,D4,0,0,0 >>,
			  intf = Intf,
			  ts = -1 }};
       Code band ?CANUSB_ERROR_RECV_FIFO_FULL =/= 0 ->
	    lager:error("error, recv_fifo_full"),
	    error_frame(Code - ?CANUSB_ERROR_RECV_FIFO_FULL, 
			ID bor ?CAN_ERR_CRTL, Intf,
			D0, (D1 bor ?CAN_ERR_CRTL_RX_OVERFLOW),
			D2, D3, D4);
       Code band ?CANUSB_ERROR_SEND_FIFO_FULL =/= 0 ->
	    lager:error("error, send_fifo_full"),
	    error_frame(Code - ?CANUSB_ERROR_SEND_FIFO_FULL, 
			ID bor ?CAN_ERR_CRTL, Intf,
			D0, (D1 bor ?CAN_ERR_CRTL_TX_OVERFLOW),
			D2, D3, D4);
       Code band ?CANUSB_ERROR_WARNING =/= 0 ->
	    lager:error("error, warning"),
	    error_frame(Code - ?CANUSB_ERROR_WARNING, 
			ID bor ?CAN_ERR_CRTL, Intf,
			D0, D1 bor (?CAN_ERR_CRTL_RX_WARNING bor
					?CAN_ERR_CRTL_TX_WARNING),
			D2, D3, D4);
       Code band ?CANUSB_ERROR_DATA_OVER_RUN =/= 0 ->
	    lager:error("error, data_over_run"),
	    %% FIXME: not really ?
	    error_frame(Code - ?CANUSB_ERROR_DATA_OVER_RUN, 
			ID bor ?CAN_ERR_CRTL, Intf,
			D0, (D1 bor ?CAN_ERR_CRTL_RX_OVERFLOW),
			D2, D3, D4);

       Code band ?CANUSB_ERROR_RESERVED_10 =/= 0 ->
	    error_frame(Code - ?CANUSB_ERROR_RESERVED_10, 
			ID, Intf, D0, D1, D2, D3, D4);
	    
       Code band ?CANUSB_ERROR_PASSIVE =/= 0 ->
	    lager:error("error, passive"),
	    error_frame(Code - ?CANUSB_ERROR_PASSIVE,
			ID bor ?CAN_ERR_CRTL, Intf, 
			D0, D1 bor (?CAN_ERR_CRTL_RX_PASSIVE bor
					?CAN_ERR_CRTL_TX_PASSIVE),
			D2, D3, D4);
       Code band ?CANUSB_ERROR_ARBITRATION_LOST =/= 0 ->
	    lager:error("error, arbitration_lost"),
	    error_frame(Code - ?CANUSB_ERROR_ARBITRATION_LOST, 
			ID bor ?CAN_ERR_LOSTARB, Intf,
			D0, D1, D2, D3, D4);
       Code band ?CANUSB_ERROR_BUS =/= 0 ->
	    lager:error("error, bus"),
	    error_frame(Code - ?CANUSB_ERROR_BUS,
			ID bor ?CAN_ERR_BUSERROR, Intf,
			D0, D1, D2, D3, D4)
    end.

       
	    
