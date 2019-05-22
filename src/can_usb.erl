%%%---- BEGIN COPYRIGHT -------------------------------------------------------
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
%%%---- END COPYRIGHT ---------------------------------------------------------
%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2013, Tony Rogvall
%%% @doc
%%%   CAN USB (VC) interface
%%%
%%% Created: 17 Sep 2009 by Tony Rogvall
%%% @end
%%%-------------------------------------------------------------------
-module(can_usb).

-behaviour(gen_server).

-include("../include/can.hrl").

%% API
-export([start/0, 
	 start/1, 
	 start/2]).
-export([start_link/0, 
	 start_link/1, 
	 start_link/2]).
-export([stop/1]).

%% gen_server callbacks
-export([init/1, 
	 handle_call/3, 
	 handle_cast/2, 
	 handle_info/2,
	 terminate/2, 
	 code_change/3]).

-export([set_bitrate/2]).
-export([get_bitrate/1]).
-export([get_version/1]).
-export([get_serial/1]).
-export([enable_timestamp/1]).
-export([disable_timestamp/1]).

%% Test API
-export([pause/1, resume/1, ifstatus/1]).
-export([dump/1]).
%% -compile(export_all).

-record(s, 
	{
	  name::string(),
	  receiver={can_router, undefined, 0} ::
	    {Module::atom(), %% Module to join and send to
	     Pid::pid() | undefined, %% Pid if not default server
	     If::integer()}, %% Interface id
	  uart::port() | undefined, %% serial line port id
	  device,          %% device name
	  offset,          %% Usb port offset
	  baud_rate,       %% baud rate to canusb
	  can_speed,       %% CAN bus speed
	  status_interval, %% Check status interval
	  retry_interval,  %% Timeout for open retry
	  retry_timer,     %% Timer reference for retry
	  pause = false,   %% Pause input
	  acc = [],        %% accumulator for command replies
	  buf = <<>>,      %% parse buffer
	  fs               %% can_filter:new()
	}).

-define(DEFAULT_BITRATE,         250000).
-define(DEFAULT_STATUS_INTERVAL, 1000).
-define(DEFAULT_RETRY_INTERVAL,  2000).
-define(DEFAULT_BAUDRATE,        115200).
-define(DEFAULT_IF,              0).

-define(SERVER, ?MODULE).

-define(COMMAND_TIMEOUT, 500).

-define(BITADD(Code, Bit, Name),
	if (Code) band (Bit) =:= 0 -> [];
 	   true  -> [(Name)]
	end).

-type can_usb_option() ::
	{device,  DeviceName::string()} |
	{name,    IfName::string()} |
	{baud,    DeviceBaud::integer()} |
	{timeout, ReopenTimeout::timeout()} |
	{bitrate, CANBitrate::integer()} |
	{status_interval, Time::timeout()} |
	{retry_interval, Time::timeout()} |
	{pause,   Pause::boolean()}.
	
-spec start() -> {ok,pid()} | {error,Reason::term()}.
start() ->
    start(1,[]).

-spec start(BudId::integer()) -> {ok,pid()} | {error,Reason::term()}.
start(BusId) ->
    start(BusId,[]).

-spec start(BudId::integer(),Opts::[can_usb_option()]) ->
		   {ok,pid()} | {error,Reason::term()}.
start(BusId, Opts) ->
    can:start(),
    ChildSpec= {{?MODULE,BusId}, {?MODULE, start_link, [BusId,Opts]},
		permanent, 5000, worker, [?MODULE]},
    supervisor:start_child(can_if_sup, ChildSpec).


-spec start_link() -> {ok,pid()} | {error,Reason::term()}.
start_link() ->
    start_link(1,[]).

-spec start_link(BudId::integer()) -> {ok,pid()} | {error,Reason::term()}.
start_link(BusId) when is_integer(BusId) ->
    start_link(BusId,[]).

-spec start_link(BusId::integer(),Opts::[can_usb_option()]) ->
			{ok,pid()} | {error,Reason::term()}.
start_link(BusId, Opts) when is_integer(BusId), is_list(Opts) ->
    gen_server:start_link(?MODULE, [BusId,Opts], []).

-spec stop(BusId::integer()) -> ok | {error,Reason::term()}.

stop(BusId) ->
    case supervisor:terminate_child(can_if_sup, {?MODULE, BusId}) of
	ok ->
	    supervisor:delete_child(can_if_sup, {?MODULE, BusId});
	Error ->
	    Error
    end.

-spec set_bitrate(Pid::pid(), BitRate::integer()) ->
			 ok | {error,Reason::term()}.

set_bitrate(Pid, BitRate) ->
    gen_server:call(Pid, {set_bitrate, BitRate}).

-spec get_bitrate(Pid::pid()) -> 
			 {ok,BitRate::integer()} | {error,Reason::term()}.
get_bitrate(Pid) ->
    gen_server:call(Pid, get_bitrate).

%% collect when init device?
-spec get_version(Pid::pid()) -> 
			 {ok,Version::string()} | {error,Reason::term()}.
get_version(Pid) ->
    case gen_server:call(Pid, {command, "V"}) of
	{ok, [$V,H1,H0,S1,S0]} ->
	    {ok, {H1-$0,H0-$0}, {S1-$0,S0-$0}};
	Error ->
	    Error
    end.

%% collect when init device?
-spec get_serial(Pid::pid()) ->
			{ok,Version::string()} | {error,Reason::term()}.
get_serial(Pid) ->
    case gen_server:call(Pid, {command, "N"}) of
	{ok, [$N|BCDSn]} ->
	    {ok, BCDSn};
	Error ->
	    Error
    end.

%% set as argument and initialize when device starts?
-spec enable_timestamp(Pid::pid()) ->
			      ok | {error,Reason::term()}.
%% enable/disable timestamp - only when channel is closed!
enable_timestamp(Pid) ->
    case gen_server:call(Pid, {command, "Z1"}) of
	{ok, _} ->
	    ok;
	Error ->
	    Error
    end.


-spec disable_timestamp(Pid::pid()) ->
			       ok | {error,Reason::term()}.
disable_timestamp(Pid) ->
    case gen_server:call(Pid, {command, "Z0"}) of
	{ok, _} ->
	    ok;
	Error ->
	    Error
    end.

-spec pause(Id::integer() | pid() | string()) -> ok | {error, Error::atom()}.
pause(Id) when is_integer(Id); is_pid(Id); is_list(Id) ->
    call(Id, pause).
-spec resume(Id::integer() | pid() | string()) -> ok | {error, Error::atom()}.
resume(Id) when is_integer(Id); is_pid(Id); is_list(Id) ->
    call(Id, resume).
-spec ifstatus(If::integer() | pid() | string()) ->
		      {ok, Status::atom()} | {error, Reason::term()}.
ifstatus(Id) when is_integer(Id); is_pid(Id); is_list(Id) ->
    call(Id, ifstatus).

-spec dump(Id::integer()| pid() | string()) -> ok | {error, Error::atom()}.
dump(Id) when is_integer(Id); is_pid(Id); is_list(Id) ->
    call(Id,dump).

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%
%%--------------------------------------------------------------------

init([Id,Opts]) ->
    Device = case proplists:get_value(device, Opts) of
		 undefined ->
		     %% try environment
		     os:getenv("CANUSB_DEVICE_" ++ integer_to_list(Id));
		 D -> D
	     end,
    if Device =:= false; Device =:= "" ->
	    lager:error("missing device argument"),
	    {stop, einval};
       true ->
	    Name = proplists:get_value(name, Opts,
				       atom_to_list(?MODULE) ++ "-" ++
					   integer_to_list(Id)),
	    Router = proplists:get_value(router, Opts, can_router),
	    Pid = proplists:get_value(receiver, Opts, undefined),
	    RetryInterval = proplists:get_value(retry_interval,Opts,
						?DEFAULT_RETRY_INTERVAL),
	    Pause = proplists:get_value(pause, Opts, false),
	    BitRate = proplists:get_value(bitrate,Opts,?DEFAULT_BITRATE),
	    Interval = proplists:get_value(status_interval,Opts,
					   ?DEFAULT_STATUS_INTERVAL),
	    Speed = case proplists:get_value(baud, Opts) of
			undefined ->
			    %% maybe CANUSB_SPEED_<x>
			    case os:getenv("CANUSB_SPEED") of
				false -> ?DEFAULT_BAUDRATE;
				""    -> ?DEFAULT_BAUDRATE;
				Speed0 -> list_to_integer(Speed0)
			    end;
			Speed1 -> Speed1
		    end,

	    case join(Router, Pid, {?MODULE,Device,Id, Name}) of
		{ok, If} when is_integer(If) ->
		    lager:debug("can_usb:joined: intf=~w", [If]),
		    S = #s{ name = Name,
			    receiver={Router,Pid,If},
			    device = Device,
			    offset = Id,
			    baud_rate = Speed,
			    can_speed = BitRate,
			    status_interval = Interval,
			    retry_interval = RetryInterval,
			    pause = Pause,
			    fs=can_filter:new()
			  },
		    lager:info("using device ~s@~w\n", [Device, BitRate]),
		    case open(S) of
			{ok, S1} -> {ok, S1};
			Error -> {stop, Error}
		    end;
		{error, Reason} = E ->
		    lager:error("Failed to join ~p(~p), reason ~p", 
				[Router, Pid, Reason]),
		    {stop, E}
	    end
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
handle_call({send,Msg}, _From, S=#s {uart = Uart})  
  when Uart =/= undefined ->
    {Reply,S1} = send_message(Msg,S),
    {reply, Reply, S1};
handle_call({send,Msg}, _From, S) ->
    if not S#s.pause ->
	    lager:debug("Msg ~p dropped", [Msg]);
       true -> ok
    end,
    {reply, ok, S};
handle_call(statistics,_From,S) ->
    {reply,{ok,can_counter:list()}, S};
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
handle_call({add_filter,F}, _From, S) ->
    Fs = can_filter:add(F,S#s.fs),
    {reply, ok, S#s { fs=Fs }};
handle_call({set_filter,I,F}, _From, S) ->
    Fs = can_filter:set(I,F,S#s.fs),
    S1 = S#s { fs=Fs },
    {reply, ok, S1};
handle_call({del_filter,I}, _From, S) ->
    {Reply,Fs} = can_filter:del(I,S#s.fs),
    {reply, Reply, S#s { fs=Fs }};
handle_call(pause, _From, S=#s {pause = false, uart = Uart}) 
  when Uart =/= undefined ->
    lager:debug("pause.", []),
    lager:debug("closing device ~s", [S#s.device]),
    R = uart:close(S#s.uart),
    lager:debug("closed ~p", [R]),
    {reply, ok, S#s {pause = true}};
handle_call(pause, _From, S) ->
    lager:debug("pause when not active.", []),
    {reply, ok, S#s {pause = true}};
handle_call(resume, _From, S=#s {pause = true}) ->
    lager:debug("resume.", []),
    case open(S#s {pause = false}) of
	{ok, S1} -> {reply, ok, S1};
	Error -> {reply, Error, S}
    end;
handle_call(resume, _From, S=#s {pause = false}) ->
    lager:debug("resume when not paused.", []),
    {reply, ok, S};
handle_call(ifstatus, _From, S=#s {pause = true}) ->
    lager:debug("ifstatus.", []),
    {reply, {ok, paused}, S};
handle_call(ifstatus, _From, S=#s {uart = undefined}) ->
    lager:debug("ifstatus.", []),
    {reply, {ok, faulty}, S};
handle_call(ifstatus, _From, S) ->
    lager:debug("ifstatus.", []),
    {reply, {ok, active}, S};
handle_call(dump, _From, S) ->
    lager:debug("dump.", []),
    {reply, {ok, S}, S};
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
handle_cast({send,Msg}, S=#s {uart = Uart})  
  when Uart =/= undefined ->
    {_, S1} = send_message(Msg, S),
    {noreply, S1};
handle_cast({send,Msg}, S) ->
    if not S#s.pause ->
	    lager:debug("Msg ~p dropped", [Msg]);
       true -> ok
    end,
    {noreply, S};
handle_cast({statistics,From},S) ->
    gen_server:reply(From, {ok,can_counter:list()}),
    {noreply, S};
handle_cast({add_filter,From,F}, S) ->
    {I,Fs} = can_filter:add(F,S#s.fs),
    gen_server:reply(From, {ok,I}),
    {noreply, S#s { fs=Fs }};
handle_cast({del_filter,From,I}, S) ->
    {Reply,Fs} = can_filter:del(I,S#s.fs),
    gen_server:reply(From, Reply),
    {noreply, S#s { fs=Fs }};
handle_cast({get_filter,From,I}, S) ->
    Reply = can_filter:get(I,S#s.fs),
    gen_server:reply(From, Reply),
    {noreply, S};  
handle_cast({list_filter,From}, S) ->
    Reply = can_filter:list(S#s.fs),
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
handle_info({uart,U,Data}, S) when S#s.uart =:= U ->
    NewBuf = <<(S#s.buf)/binary, Data/binary>>,
    lager:debug("handle_info: NewBuf=~p", [NewBuf]),
    {_,S1} = parse_all(S#s { buf = NewBuf}),
    lager:debug("handle_info: RemainBuf=~p", [S1#s.buf]),
    {noreply, S1};

handle_info({uart_error,U,Reason}, S) when U =:= S#s.uart ->
    send_state(down, S#s.receiver),
    if Reason =:= enxio ->
	    lager:error("uart error ~p device ~s unplugged?", 
			[Reason,S#s.device]),
	    {noreply, reopen(S)};
       true ->
	    lager:error("uart error ~p for device ~s", 
			[Reason,S#s.device]),
	    {noreply, S}
    end;

handle_info({uart_closed,U}, S) when U =:= S#s.uart ->
    send_state(down, S#s.receiver),
    lager:error("uart device closed, will try again in ~p msecs.",
		[S#s.retry_interval]),
    S1 = reopen(S),
    {noreply, S1};

handle_info({timeout,_TRef,status}, S) ->
    case command(S, "F") of
	{ok, [$F|Status], S1} ->
	    try erlang:list_to_integer(Status, 16) of
		0 ->
		    start_timer(S#s.status_interval,status),
		    {noreply,S};
		Code ->
		    S2 = error_input(Code, S1),
		    start_timer(S2#s.status_interval,status),
		    {noreply,S2}
	    catch
		error:Reason ->
		    lager:error("can_usb: status error: ~p", [Reason]),
		    start_timer(S#s.status_interval,status),
		    {noreply,S}
	    end;
	{ok, Status, S1} ->
	    lager:error("can_usb: status error: ~p", [Status]),
	    start_timer(S1#s.status_interval,status),
	    {noreply,S1};
	{{error,Reason}, S1} ->
	    lager:error("can_usb: status error: ~p", [Reason]),
	    start_timer(S1#s.status_interval,status),
	    {noreply,S1}
    end;

handle_info({timeout,TRef,reopen},S) when TRef =:= S#s.retry_timer ->
    case open(S#s { retry_timer = undefined }) of
	{ok, S1} ->
	    {noreply, S1};
	Error ->
	    {stop, Error, S}
    end;

handle_info(_Info, S) ->
    lager:debug("can_usb: got info ~p", [_Info]),
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


open(S=#s {pause = true}) ->
    {ok, S};
open(S0=#s {device = DeviceName, baud_rate = Speed,
	    status_interval = Interval, can_speed = BitRate }) ->
    DOpts = [{mode,binary},{baud,Speed},{packet,0},
	     {csize,8},{stopb,1},{parity,none},{active,true}
	     %% {debug,debug}
	     %% {buftm,1},{bufsz,128}
	    ],    
    case uart:open1(DeviceName,DOpts) of
	{ok,U} ->
	    {ok,[{device,RealDeviceName}]} = uart:getopts(U,[device]),
	    if DeviceName =/= RealDeviceName ->
		    lager:info("open CANUSB device ~s@~w", 
			       [RealDeviceName, Speed]);
	       true ->
		    lager:debug("canusb:open: ~s@~w", [RealDeviceName,Speed])
	    end,
	    start_timer(Interval,status),
	    S = S0#s { uart=U },
	    canusb_sync(S),
	    canusb_set_bitrate(S, BitRate),
	    command_open(S),
	    send_state(up, S#s.receiver),
	    {ok, S};
	{error, E} when E =:= eaccess;
			E =:= enoent ->
	    lager:debug("canusb:open: ~s@~w  error ~w, will try again "
		   "in ~p msecs.", [DeviceName,Speed,E,S0#s.retry_interval]),
	    send_state(down, S0#s.receiver),
	    Timer = start_timer(S0#s.retry_interval, reopen),
	    {ok, S0#s { retry_timer = Timer }};
	Error ->
	    lager:error("canusb:open: error ~w", [Error]),
	    send_state(down, S0#s.receiver),
	    Error
    end.
    
reopen(S=#s {pause = true}) ->
    S;
reopen(S) ->
    if S#s.uart =/= undefined ->
	    lager:debug("closing device ~s", [S#s.device]),
	    R = uart:close(S#s.uart),
	    send_state(down, S#s.receiver),
	    lager:debug("closed ~p", [R]),
	    R;
       true ->
	    ok
    end,
    Timer = start_timer(S#s.retry_interval, reopen),
    S#s { uart=undefined, buf=(<<>>), acc=[], retry_timer=Timer }.

start_timer(undefined, _Tag) ->
    undefined;
start_timer(infinity, _Tag) ->
    undefined;
start_timer(Time, Tag) ->
    erlang:start_timer(Time,self(),Tag).

send_message(Mesg, S) when is_record(Mesg,can_frame) ->
    lager:debug([{tag, frame}],"can_usb:send_message: [~s]", 
	   [can_probe:format_frame(Mesg)]),
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
    DCL = if L < 10 -> L+$0; true -> (L-10)+$A end,
    Len = min(L,8),
    if ?is_can_id_sff(ID), ?is_not_can_id_rtr(ID) ->
	    ID1 = ID band ?CAN_SFF_MASK,
	    send_frame(S, [$t,to_hex(ID1,3), DCL, to_hex_min(Data,Len)]);
       ?is_can_id_eff(ID), ?is_not_can_id_rtr(ID) ->
	    ID1 = ID band ?CAN_EFF_MASK,
	    send_frame(S, [$T,to_hex(ID1,8), DCL, to_hex_min(Data,Len)]);
       ?is_can_id_sff(ID), ?is_can_id_rtr(ID) ->
	    ID1 = ID band ?CAN_SFF_MASK,
	    send_frame(S, [$r,to_hex(ID1,3), DCL, to_hex_max(Data,8)]);
       ?is_can_id_eff(ID), ?is_can_id_rtr(ID) ->
	    ID1 = ID band ?CAN_EFF_MASK,
	    send_frame(S, [$R,to_hex(ID1,8), DCL, to_hex_max(Data,8)]);
       true ->
	    output_error(?can_error_data,S)
    end.

send_frame(S, Frame) ->
    case command(S, Frame) of
	{ok,_Reply,S1} ->
	    {ok, count(output_frames,S1)};
	{{error,eagain = Reason},S1} ->
	    send_state(down, S1#s.receiver),
	    output_error(Reason,S1);
	{{error,Reason},S1} ->
	    output_error(Reason,S1)
    end.

ihex(I) ->
    element(I+1, {$0,$1,$2,$3,$4,$5,$6,$7,$8,$9,$A,$B,$C,$D,$E,$F}).

%% minimum L elements - fill with 0  
to_hex_min(_,0) -> [];
to_hex_min(<<>>,I) -> [$0,$0|to_hex_min(<<>>,I-1)];
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
-spec command(#s{},iolist()) -> 
		     {{'error',term()},#s{}} | 
		     {'ok',list(byte()),#s{}}.
command(S, Command) ->
    command(S, Command, ?COMMAND_TIMEOUT).

-spec command(#s{},iolist(),integer()) -> 
		     {{'error',term()},#s{}} | 
		     {'ok',list(byte()),#s{}}.
command(S, Command, Timeout) ->
    BCommand = iolist_to_binary([Command,$\r]),
    lager:debug("can_usb:command: [~p]", [BCommand]),
    if S#s.uart =:= undefined ->
	    {{error,eagain},S};
       true ->
	    uart:send(S#s.uart, BCommand),
	    wait_reply(S,Timeout)
    end.

-spec wait_reply(#s{},integer()) -> 
			{{'error',term()},#s{}} | 
			{'ok',list(byte()),#s{}}.
wait_reply(S,Timeout) ->
    receive
	{uart,U,Data} when U=:=S#s.uart ->
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
	    end;
	{uart_error,U,enxio} when U =:= S#s.uart ->
	    lager:error("uart error ~p device ~s unplugged?", 
			[enxio,S#s.device]),
	    {{error,enxio},reopen(S)};
	{uart_error,U,Error} when U=:=S#s.uart ->
	    {{error,Error}, S};
	{uart_closed,U} when U =:= S#s.uart ->
	    lager:error("uart close will reopen", []),
	    {{error,closed},reopen(S)}
	
    after Timeout ->
	    {{error,timeout},S}
    end.

ok(Buf,Acc,S)   -> {ok,lists:reverse(Acc),S#s { buf=Buf,acc=[]}}.
error(Reason,Buf,S) -> {{error,Reason}, S#s { buf=Buf, acc=[]}}.

count(Counter,S) ->
    can_counter:update(Counter, 1),
    S.

output_error(Reason,S) ->
    {{error,Reason},oerr(Reason,S)}.

oerr(Reason,S) ->
    lager:debug("can_usb:output error: ~p", [Reason]),
    S1 = count(output_error,S),
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
	<<C,Buf/binary>>        -> parse(Buf, [C|Acc], S)
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
    if L >= $0, L =< $9 ->
	    parse_([I2,I1,I0],L-$0,false,Rtr,Ds,S);
       L >= $A, L =< $F ->
	    parse_([I2,I1,I0],(L-$A)+10,false,Rtr,Ds,S);
       L >= $a, L =< $f ->
	    parse_([I2,I1,I0],(L-$a)+10,false,Rtr,Ds,S);
       true ->
	    parse(Ds,[],ierr(?can_error_length_out_of_range,S))
    end;
parse_11(_Buf,_Rtr,S) ->
    {more, S}.

parse_29(<<I7,I6,I5,I4,I3,I2,I1,I0,L,Ds/binary>>,Rtr,S) ->
    if L >= $0, L =< $9 ->
	    parse_([I7,I6,I5,I4,I3,I2,I1,I0],L-$0,true,Rtr,Ds,S);
       L >= $A, L =< $F ->
	    parse_([I7,I6,I5,I4,I3,I2,I1,I0],(L-$A)+10,true,Rtr,Ds,S);
       L >= $a, L =< $f ->
	    parse_([I7,I6,I5,I4,I3,I2,I1,I0],(L-$a)+10,true,Rtr,Ds,S);
       true ->
	    parse(Ds,[],ierr(?can_error_length_out_of_range,S))
    end;
parse_29(_Buf,_Rtr,S) ->
    {more, S}.

parse_(IDs,Len,Ext,Rtr,Ds,S) ->
    try erlang:list_to_integer(IDs,16) of
	ID ->
	    parse_message(ID,Len,Ext,Rtr,Ds,S)
    catch
	error:_ ->
	    %% bad frame ID
	    parse(Ds,[],ierr(?can_error_corrupt,S))
    end.
    

parse_message(ID,Len,Ext,Rtr,Ds,S=#s {receiver = {_Module, _Pid, If}}) ->
    case parse_data(Len,Rtr,Ds,[]) of
	{ok,Data,Ts,More} ->
	    try can:create(ID,Len,Ext,Rtr,If,Data,Ts) of
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

join(Module, Pid, Arg) when is_atom(Module), is_pid(Pid) ->
    Module:join(Pid, Arg);
join(undefined, Pid, _Arg) when is_pid(Pid) ->
    %% No join
    ?DEFAULT_IF;
join(Module, undefined, Arg) when is_atom(Module) ->
    Module:join(Arg).
  
input(Frame, S=#s {receiver = Receiver, fs = Fs}) ->
    case can_filter:input(Frame, Fs) of
	true ->
	    input_frame(Frame, Receiver),
	    count(input_frames, S);
	false ->
	    S1 = count(input_frames, S),
	    count(filter_frames, S1)
    end.

input_frame(Frame, {undefined, Pid, _If}) when is_pid(Pid) ->
    Pid ! Frame;
input_frame(Frame,{Module, undefined, _If}) when is_atom(Module) ->
    Module:input(Frame);
input_frame(Frame,{Module, Pid, _If}) when is_atom(Module), is_pid(Pid) ->
    Module:input(Pid, Frame).

send_state(State, {undefined, Pid, If}) when is_pid(Pid) ->
    Pid ! {if_state_event, If, State};
send_state(State,{Module, undefined, If}) when is_atom(Module) ->
    Module:if_state_event(If, State);
send_state(State,{Module, Pid, If}) when is_atom(Module), is_pid(Pid) ->
    Module:if_state_event(Pid, If, State).

%% Error codes return by CANUSB
-define(CANUSB_ERROR_RECV_FIFO_FULL,   16#01).
-define(CANUSB_ERROR_SEND_FIFO_FULL,   16#02).
-define(CANUSB_ERROR_WARNING,          16#04).
-define(CANUSB_ERROR_DATA_OVER_RUN,    16#08).
-define(CANUSB_ERROR_RESERVED_10,      16#10).
-define(CANUSB_ERROR_PASSIVE,          16#20).
-define(CANUSB_ERROR_ARBITRATION_LOST, 16#40).
-define(CANUSB_ERROR_BUS,              16#80).

error_input(Code, S=#s {receiver = Receiver = {_Module, _Pid, If}, fs = Fs}) ->
    case error_frame(Code band 16#FF, If) of
	false -> S;
	{true,Frame} ->
	    case can_filter:input(Frame, Fs) of
		true ->
		    input_frame(Frame, Receiver),
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

call(Pid, Request) when is_pid(Pid) -> 
    gen_server:call(Pid, Request);
call(Id, Request) when is_integer(Id); is_list(Id) ->
    case can_router:interface_pid({?MODULE, Id})  of
	Pid when is_pid(Pid) -> gen_server:call(Pid, Request);
	Error -> Error
    end.
	    
