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

-export([get_version/1]).
-export([get_serial/1]).
-export([enable_timestamp/1]).
-export([disable_timestamp/1]).
-export([get_bitrate/1, set_bitrate/2]).
-export([getopts/2, setopts/2, optnames/0]).
-export([pause/1, resume/1, ifstatus/1]).

%% Util
-export([low_latency/0]).
%% Test API
-export([dump/1]).
%% -compile(export_all).

-type cid() :: integer() | pid() | string().
-define(is_cid(X),(is_integer((X)) orelse is_pid((X)) orelse is_list((X)))).


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

-define(COMMAND_TIMEOUT, 5000).
-define(OPEN_TIMEOUT,    10000).

-define(SUPPORTED_BITRATES, [10000,20000,50000,100000,125000,
			     250000,500000,800000,1000000]).
-define(SUPPORTED_DATARATES, []).

-type can_usb_optname() ::
	device | name | baud | bitrate | bitrates | datarates | 
	status_interval | retry_interval | pause | fd.

-type can_usb_option() ::
	{device,  DeviceName::string()} |
	{name,    IfName::string()} |
	{baud,    DeviceBaud::integer()} |
	{bitrate, CANBitrate::integer()} |
	{datarate, CANDatarate::integer()} |
	{status_interval, Time::timeout()} |
	{retry_interval, Time::timeout()} |
	{pause,   Pause::boolean()} |
	{fd,   FD::boolean()}.
	
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

-spec set_bitrate(Id::cid(), BitRate::integer()) ->
	  ok | {error,Reason::term()}.

set_bitrate(Id, Rate) ->
    case setopts(Id, [{bitrate, Rate}]) of
	[{bitrate, Result}] ->
	    Result;
	[] ->
	    {error, einval}
    end.

-spec get_bitrate(Id::cid()) -> 
	  {ok,BitRate::integer()} | {error,Reason::term()}.

get_bitrate(Id) ->
    case getopts(Id, [bitrate]) of
	[] -> {error, einval};
	[{bitrate,Rate}] -> {ok,Rate}
    end.

%% collect when init device?
-spec get_version(Id::cid()) -> 
	  {ok,Version::string()} | {error,Reason::term()}.
get_version(Id) ->
    case call(Id, {command, "V"}) of
	{ok, [$V,H1,H0,S1,S0]} ->
	    {ok, {H1-$0,H0-$0}, {S1-$0,S0-$0}};
	Error ->
	    Error
    end.

%% collect when init device?
-spec get_serial(Id::cid()) ->
			{ok,Version::string()} | {error,Reason::term()}.
get_serial(Id) ->
    case call(Id, {command, "N"}) of
	{ok, [$N|BCDSn]} ->
	    {ok, BCDSn};
	Error ->
	    Error
    end.

%% set as argument and initialize when device starts?
-spec enable_timestamp(Id::cid()) ->
			      ok | {error,Reason::term()}.
%% enable/disable timestamp - only when channel is closed!
enable_timestamp(Id) ->
    case call(Id, {command, "Z1"}) of
	{ok, _} ->
	    ok;
	Error ->
	    Error
    end.


-spec disable_timestamp(Id::cid()) ->
	  ok | {error,Reason::term()}.
disable_timestamp(Id) ->
    case call(Id, {command, "Z0"}) of
	{ok, _} ->
	    ok;
	Error ->
	    Error
    end.

-spec pause(Id::cid()) -> ok | {error, Error::atom()}.
pause(Id) when is_integer(Id); is_pid(Id); is_list(Id) ->
    call(Id, pause).
-spec resume(Id::cid()) -> ok | {error, Error::atom()}.
resume(Id) when is_integer(Id); is_pid(Id); is_list(Id) ->
    call(Id, resume).
-spec ifstatus(Id::cid()) ->
	  {ok, Status::atom()} | {error, Reason::term()}.
ifstatus(Id) when is_integer(Id); is_pid(Id); is_list(Id) ->
    call(Id, ifstatus).

-spec dump(Id::cid()) -> ok | {error, Error::atom()}.
dump(Id) when is_integer(Id); is_pid(Id); is_list(Id) ->
    call(Id,dump).

-spec optnames() -> [can_usb_optname()].

optnames() ->
    [ device, name, baud, bitrate, datarate, bitrates, datarates,
      status_interval, retry_interval, pause, fd ].

-spec getopts(Id::cid(), Opts::[can_usb_optname()]) ->
	  [can_usb_option()].
getopts(Id, Opts) ->
    call(Id, {getopts, Opts}).

-spec setopts(Id::cid(), Opts::[can_usb_option()]) ->
	  [{can_usb_optname(),ok|{error,Reason::term()}}].

setopts(Id, Opts) ->
    call(Id, {setopts, Opts}).

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%
%%--------------------------------------------------------------------

init([BusId,Opts]) ->
    Device = case proplists:get_value(device, Opts) of
		 undefined ->
		     %% try environment
		     os:getenv("CANUSB_DEVICE_" ++ integer_to_list(BusId));
		 D -> D
	     end,
    if Device =:= false; Device =:= "" ->
	    ?error("missing device argument"),
	    {stop, einval};
       true ->
	    Name = proplists:get_value(name, Opts,
				       atom_to_list(?MODULE) ++ "-" ++
					   integer_to_list(BusId)),
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
	    Param = #{ mod => ?MODULE,
		       device => Device,
		       index => BusId,
		       name => Name,  %% mod-<id>
		       bitrates => ?SUPPORTED_BITRATES,
		       datarate => 0,
		       datarates => ?SUPPORTED_DATARATES,
		       listen_only => false,
		       fd => false },
	    case join(Router, Pid, Param) of
		{ok, If} when is_integer(If) ->
		    ?debug("can_usb:joined: intface id=~w", [If]),
		    S = #s{ name = Name,
			    receiver={Router,Pid,If},
			    device = Device,
			    offset = If,
			    baud_rate = Speed,
			    can_speed = BitRate,
			    status_interval = Interval,
			    retry_interval = RetryInterval,
			    pause = Pause,
			    fs=can_filter:new()
			  },
		    ?info("using device ~s@~w\n", [Device, BitRate]),
		    case open(S) of
			{ok, S1} -> {ok, S1};
			Error -> {stop, Error}
		    end;
		{error, Reason} = E ->
		    ?error("Failed to join ~p(~p), reason ~p", 
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
handle_call({send,Msg}, _From, S) ->
    {Reply,S1} = send_message(Msg,S),
    {reply, Reply, S1};
handle_call(statistics,_From,S) ->
    {reply,{ok,can_counter:list()}, S};
handle_call({getopts, Opts},_From,S) ->
    Result =
	lists:map(
	  fun(device)  -> {device,S#s.device};
	     (name)    -> {name,S#s.name};
	     (bitrate) -> {bitrate,S#s.can_speed};
	     (datarate) -> {datarate, undefined};
	     (bitrates) -> {bitrates,?SUPPORTED_BITRATES};
	     (datarates) -> {datarates,?SUPPORTED_DATARATES};
	     (baud)    -> {baud,S#s.baud_rate};
	     (status_interval) -> {status_interval,S#s.status_interval};
	     (retry_interval) -> {retry_interval,S#s.retry_interval};
	     (pause) -> {pause,S#s.pause};
	     (fd) -> {fd,false};
	     (Opt) -> {Opt, undefined}
	  end, Opts),
    {reply, Result, S};
handle_call({setopts, Opts},_From,S) ->
    {Result,S1} = changeopts(Opts, S),
    {reply, Result, S1};
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
    ?debug("pause.", []),
    ?debug("closing device ~s", [S#s.device]),
    _R = uart:close(S#s.uart),
    ?debug("closed ~p", [_R]),
    {reply, ok, S#s {pause = true}};
handle_call(pause, _From, S) ->
    ?debug("pause when not active.", []),
    {reply, ok, S#s {pause = true}};
handle_call(resume, _From, S=#s {pause = true}) ->
    ?debug("resume.", []),
    case open(S#s {pause = false}) of
	{ok, S1} -> {reply, ok, S1};
	Error -> {reply, Error, S}
    end;
handle_call(resume, _From, S=#s {pause = false}) ->
    ?debug("resume when not paused.", []),
    {reply, ok, S};
handle_call(ifstatus, _From, S=#s {pause = true}) ->
    ?debug("ifstatus.", []),
    {reply, {ok, paused}, S};
handle_call(ifstatus, _From, S=#s {uart = undefined}) ->
    ?debug("ifstatus.", []),
    {reply, {ok, faulty}, S};
handle_call(ifstatus, _From, S) ->
    ?debug("ifstatus.", []),
    {reply, {ok, active}, S};
handle_call(dump, _From, S) ->
    ?debug("dump.", []),
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
handle_cast({send,Msg}, S) ->
    {_, S1} = send_message(Msg, S),
    {noreply, S1};
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
    ?debug("can_usb: handle_cast: ~p\n", [_Mesg]),
    {noreply, S}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({uart,U,Data}, S) when S#s.uart =:= U ->
    NewBuf = <<(S#s.buf)/binary, Data/binary>>,
    ?debug("handle_info: NewBuf=~p", [NewBuf]),
    {_,S1} = parse_all(S#s { buf = NewBuf}),
    ?debug("handle_info: RemainBuf=~p", [S1#s.buf]),
    {noreply, S1};

handle_info({uart_error,U,Reason}, S) when U =:= S#s.uart ->
    send_state(down, S#s.receiver),
    if Reason =:= enxio ->
	    ?error("uart error ~p device ~s unplugged?", 
			[Reason,S#s.device]),
	    {noreply, reopen(S)};
       true ->
	    ?error("uart error ~p for device ~s", 
			[Reason,S#s.device]),
	    {noreply, S}
    end;

handle_info({uart_closed,U}, S) when U =:= S#s.uart ->
    send_state(down, S#s.receiver),
    ?error("uart device closed, will try again in ~p msecs.",
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
		    ?error("can_usb: status error: ~p", [Reason]),
		    start_timer(S#s.status_interval,status),
		    {noreply,S}
	    end;
	{ok, Status, S1} ->
	    ?error("can_usb: status error: ~p", [Status]),
	    start_timer(S1#s.status_interval,status),
	    {noreply,S1};
	{{error,Reason}, S1} ->
	    ?error("can_usb: status error: ~p", [Reason]),
	    canusb_sync_close(S1),
	    canusb_set_bitrate(S, S#s.can_speed),
	    command_open(S1),
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
    ?debug("can_usb: got info ~p", [_Info]),
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

changeopts(Opts, S) ->
    changeopts_(Opts,[],S).

changeopts_([{Key,Value}|Opts],Acc,S) ->
    case Key of
	device ->
	    changeopts_(Opts, [{Key,ok}|Acc], S#s {device=Value});
	name -> 
	    changeopts_(Opts, [{Key,ok}|Acc], S#s {name=Value});
	bitrate ->
	    case set_can_speed(Value, S) of
		Error = {error,_} ->
		    changeopts_(Opts, [{Key,Error}|Acc], S);
		ok ->
		    changeopts_(Opts, [{Key,ok}|Acc], 
				  S#s { can_speed=Value })
	    end;
	baud ->
	    changeopts_(Opts, [{Key,ok}|Acc], S#s { baud_rate=Value });
	status_interval ->
	    changeopts_(Opts, [{Key,ok}|Acc], 
			S#s { status_interval=Value});
	retry_interval -> 
	    changeopts_(Opts, [{Key,ok}|Acc], 
			  S#s { retry_interval=Value});
	_ ->
	    changeopts_(Opts, [{Key, {error, einval}}|Acc],  S)
    end;
changeopts_([], Acc, S) ->
    {lists:reverse(Acc), S}.


set_can_speed(Rate, S) ->
    if S#s.uart =:= undefined ->
	    case speed_number(Rate) of
		error ->
		    {error,bad_bit_rate};
		_ ->
		    ok
	    end;
       true ->
	    command_close(S),
	    case canusb_set_bitrate(S, Rate) of
		{ok, _Reply, S1} ->
		    command_open(S1),
		    ok;
		{Error={error,_},S1} ->
		    command_open(S1),
		    Error
	    end
    end.


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
		    ?info("open CANUSB device ~s@~w", 
			       [RealDeviceName, Speed]);
	       true ->
		    ?debug("canusb:open: ~s@~w", [RealDeviceName,Speed])
	    end,
	    uart:flush(U, both),
	    start_timer(Interval,status),
	    S = S0#s { uart=U },
	    canusb_sync_close(S),
	    _R1 = canusb_set_bitrate(S, BitRate),
	    _R2 = command_open(S),
	    Param = #{ device_name => RealDeviceName,
		       bitrate => BitRate,
		       fd => false
		     },
	    send_state(Param, S#s.receiver),
	    send_state(up, S#s.receiver),
	    {ok, S};
	{error, E} when E =:= eaccess;
			E =:= enoent ->
	    ?debug("canusb:open: ~s@~w  error ~w, will try again "
		   "in ~p msecs.", [DeviceName,Speed,E,S0#s.retry_interval]),
	    send_state(down, S0#s.receiver),
	    Timer = start_timer(S0#s.retry_interval, reopen),
	    {ok, S0#s { retry_timer = Timer }};
	Error ->
	    ?error("canusb:open: error ~w", [Error]),
	    send_state(down, S0#s.receiver),
	    Error
    end.
    
reopen(S=#s {pause = true}) ->
    S;
reopen(S) ->
    if S#s.uart =/= undefined ->
	    ?debug("closing device ~s", [S#s.device]),
	    R = uart:close(S#s.uart),
	    send_state(down, S#s.receiver),
	    ?debug("closed ~p", [R]),
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

send_message(_Mesg, S) when S#s.uart =:= undefined ->
    if not S#s.pause ->
	    ?debug("~s: ~p, Msg ~p dropped", [?MODULE,S#s.device,_Mesg]);
       true -> ok
    end,
    {ok, S};
send_message(Mesg, S) when is_record(Mesg,can_frame) ->
    ?debug("can_usb:send_message: [~s]", [can_probe:format_frame(Mesg)]),
    if is_binary(Mesg#can_frame.data), not ?is_can_frame_fd(Mesg) ->
	    send_bin_message(Mesg, Mesg#can_frame.data, S);
       true ->
	    output_error(?can_error_data,S)
    end;
send_message(_Mesg, S) ->
    output_error(?can_error_data,S).

send_bin_message(Mesg, Bin, S) when byte_size(Bin) =< 8 ->
    send_message_(Mesg#can_frame.id,
		 Mesg#can_frame.len,
		 Bin,
		 S);
send_bin_message(_Mesg, _Bin, S) ->
    output_error(?can_error_data_too_large,S).

send_message_(ID, L, Data, S) ->
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

%% get 1-based element position or false if not found
%% index(List, Elem) -> index(List, Elem, 1, false).
%% get 0-bases element poistion or false if not found
%% zindex(List, Elem) -> index(List, Elem, 0, false).
    
index([Elem|_List], Elem, I, _D) -> I;
index([_|List], Elem, I, D) -> index(List, Elem, I+1, D);
index([], _Elem, _I, D) -> D.
    

canusb_sync_close(S) ->
    command_nop(S),
    command_nop(S),
    command_nop(S),
    command_close(S),
    command_nop(S),
    true.

speed_number(BitRate) ->
    index(?SUPPORTED_BITRATES, BitRate, 0, error).

canusb_set_bitrate(S, BitRate) ->
    case speed_number(BitRate) of
	error ->
	    {{error,bad_bit_rate}, S};
	N ->
	    command(S, [$S,N+$0])
    end.

command_nop(S) ->
    command(S, "").
	
command_open(S) ->
    command(S, "O", ?OPEN_TIMEOUT).

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
    ?debug("can_usb:command: [~p]", [BCommand]),
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
	    ?debug("can_usb:data: ~p", [Data]),
	    Data1 = <<(S#s.buf)/binary,Data/binary>>,
	    case parse(Data1, [], S#s{ buf=Data1 }) of
		{more,S1} ->
		    wait_reply(S1,Timeout);
		{ok,Reply,S1} ->
		    ?debug("can_usb:wait_reply: ok", []),
		    {_, S2} = parse_all(S1),
		    {ok,Reply,S2};
		{Error,S1} ->
		    ?debug("can_usb:wait_reply: ~p", [Error]),
		    {_, S2} = parse_all(S1),
		    {Error,S2}
	    end;
	{uart_error,U,enxio} when U =:= S#s.uart ->
	    ?error("uart error ~p device ~s unplugged?", 
			[enxio,S#s.device]),
	    {{error,enxio},reopen(S)};
	{uart_error,U,Error} when U=:=S#s.uart ->
	    {{error,Error}, S};
	{uart_closed,U} when U =:= S#s.uart ->
	    ?error("uart close will reopen", []),
	    {{error,closed},reopen(S)}
	
    after Timeout ->
	    ?debug("can_usb:wait_reply: timeout", []),
	    {{error,timeout},S}
    end.

ok(Buf,Acc,S)   -> {ok,lists:reverse(Acc),S#s { buf=Buf,acc=[]}}.
err(Reason,Buf,S) -> {{error,Reason}, S#s { buf=Buf, acc=[]}}.

count(Counter,S) ->
    can_counter:update(Counter, 1),
    S.

output_error(Reason,S) ->
    {{error,Reason},oerr(Reason,S)}.

oerr(Reason,S) ->
    ?debug("can_usb:output error: ~p", [Reason]),
    S1 = count(output_error,S),
    count({output_error,Reason}, S1).

ierr(Reason,S) ->
    ?debug("can_usb:input error: ~p", [Reason]),
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
	    ?debug("can_usb:parse_all: ~p, ~p", [_Error,S#s.buf]),
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
	<<7, Buf/binary>>       -> err(command,Buf,S);
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
    

parse_message(ID,Len,Ext,Rtr,Ds,S=#s {receiver = {_Module, _Pid, Id}}) ->
    case parse_data(Len,Rtr,Ds,[]) of
	{ok,Data,Ts,More} ->
	    try can:create(ID,Len,Ext,Rtr,false,Id,Data,Ts) of
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

join(undefined, Pid, _Arg) when is_pid(Pid) ->
    {ok,?DEFAULT_IF};
join(Module, Pid, Arg) when is_atom(Module), is_pid(Pid) ->
    Module:join(Pid, Arg);
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

input_frame(Frame, {undefined, Pid, _Id}) when is_pid(Pid) ->
    Pid ! Frame;
input_frame(Frame,{Module, undefined, _Id}) when is_atom(Module) ->
    Module:input(Frame);
input_frame(Frame,{Module, Pid, _Id}) when is_atom(Module), is_pid(Pid) ->
    Module:input(Pid, Frame).

send_state(State, {undefined, Pid, Id}) 
  when is_integer(Id), is_pid(Pid) ->
    Pid ! {if_state_event, Id, State};
send_state(State,{Module, undefined, Id}) when 
      is_integer(Id), is_atom(Module) ->
    Module:if_state_event(Id, State);
send_state(State,{Module, Pid, Id}) when 
      is_integer(Id), is_atom(Module), is_pid(Pid) ->
    Module:if_state_event(Pid, Id, State).

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
    error_frame(Code, 0, Intf, 0, 0, 0, 0, 0).

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
	    ?error("error, recv_fifo_full"),
	    error_frame(Code - ?CANUSB_ERROR_RECV_FIFO_FULL, 
			ID bor ?CAN_ERR_CRTL, Intf,
			D0, (D1 bor ?CAN_ERR_CRTL_RX_OVERFLOW),
			D2, D3, D4);
       Code band ?CANUSB_ERROR_SEND_FIFO_FULL =/= 0 ->
	    ?error("error, send_fifo_full"),
	    error_frame(Code - ?CANUSB_ERROR_SEND_FIFO_FULL, 
			ID bor ?CAN_ERR_CRTL, Intf,
			D0, (D1 bor ?CAN_ERR_CRTL_TX_OVERFLOW),
			D2, D3, D4);
       Code band ?CANUSB_ERROR_WARNING =/= 0 ->
	    ?error("error, warning"),
	    error_frame(Code - ?CANUSB_ERROR_WARNING, 
			ID bor ?CAN_ERR_CRTL, Intf,
			D0, D1 bor (?CAN_ERR_CRTL_RX_WARNING bor
					?CAN_ERR_CRTL_TX_WARNING),
			D2, D3, D4);
       Code band ?CANUSB_ERROR_DATA_OVER_RUN =/= 0 ->
	    ?error("error, data_over_run"),
	    %% FIXME: not really ?
	    error_frame(Code - ?CANUSB_ERROR_DATA_OVER_RUN, 
			ID bor ?CAN_ERR_CRTL, Intf,
			D0, (D1 bor ?CAN_ERR_CRTL_RX_OVERFLOW),
			D2, D3, D4);

       Code band ?CANUSB_ERROR_RESERVED_10 =/= 0 ->
	    error_frame(Code - ?CANUSB_ERROR_RESERVED_10, 
			ID, Intf, D0, D1, D2, D3, D4);
	    
       Code band ?CANUSB_ERROR_PASSIVE =/= 0 ->
	    ?error("error, passive"),
	    error_frame(Code - ?CANUSB_ERROR_PASSIVE,
			ID bor ?CAN_ERR_CRTL, Intf, 
			D0, D1 bor (?CAN_ERR_CRTL_RX_PASSIVE bor
					?CAN_ERR_CRTL_TX_PASSIVE),
			D2, D3, D4);
       Code band ?CANUSB_ERROR_ARBITRATION_LOST =/= 0 ->
	    ?error("error, arbitration_lost"),
	    error_frame(Code - ?CANUSB_ERROR_ARBITRATION_LOST, 
			ID bor ?CAN_ERR_LOSTARB, Intf,
			D0, D1, D2, D3, D4);
       Code band ?CANUSB_ERROR_BUS =/= 0 ->
	    ?error("error, bus"),
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

%% utility (linux) require setserial command!!

low_latency() ->
    lists:foreach(
      fun(UsbDev) ->
	      %% ignore output since only FTDI devices will return ok
	      os:cmd("setserial "++UsbDev++" low_latency")
      end, filelib:wildcard("/dev/ttyUSB*")).
