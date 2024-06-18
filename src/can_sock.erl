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
%%% File    : can_sock.erl
%%% Author  : Tony Rogvall <tony@rogvall.se>
%%% Description : SocketCAN manager
%%%
%%% Created :  8 Jun 2010 by Tony Rogvall <tony@rogvall.se>
%%%-------------------------------------------------------------------
-module(can_sock).

-behaviour(gen_server).

-include("../include/can.hrl").

%% API
-export([start/0, start/1, start/2]).
-export([start_link/0, start_link/1, start_link/2]).
-export([stop/1]).
-export([get_bitrate/1, set_bitrate/2]).
-export([getopts/2, setopts/2, optnames/0]).
-export([pause/1, resume/1, ifstatus/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).
%% Test API
-export([dump/1]).
-export([get_link_opts/1]).
-export([get_netlink_opts/1]).

-define(DEFAULT_BITRATE,  250000).
-define(DEFAULT_DATARATE, 1000000).
-define(DEFAULT_BITRATES, [100000, 125000, 250000, 500000, 800000, 1000000]).
-define(DEFAULT_DATARATES, [100000, 125000, 250000, 500000, 800000, 1000000,
			    2000000, 3000000, 4000000, 5000000]).
-define(DEFAULT_IF,0).

-define(verbose(F, A), ok).
%%-define(verbose(F, A), io:format((F),(A))).

-type can_sock_optname() ::
	device | name | bitrate | datarate | 
	pause | fd  | mtu | list_only | restart_ms.

-type can_sock_option() ::
	{device,  DeviceName::string()} |  %% can be pattern
	{name,    IfName::string()} |
	{bitrate, CANBitrate::integer()} |
	{bitrates, [CANBitrate::integer()]} |
	{datarate, CANDatarate::integer()} |
	{datarates, [CANDatarate::integer()]} |
	{pause,   Pause::boolean()} |
	{fd, Enable::boolean()} |
	{mtu, Mtu::16|72} |  %% normal CAN or CANFD
	{listen_only, Enable::boolean()} |
	{restart_ms, Ms::integer()}.
%%
%%      {loopback, Enable::boolean()
%%      {one_shot, Enable::boolean()
%%      {berr_reporting, Enable::boolean()
%%      {fd_non_iso, Enable::boolean()
%%      {presume_ack, Enable::boolean()
%%
-type cid() :: integer() | pid() | string().
-define(is_cid(X),(is_integer((X)) orelse is_pid((X)) orelse is_list((X)))).

-record(s,
	{
	 state = init :: init | change | setup | running,
	 name::string(),
	 receiver={can_router, undefined, undefined} ::
	   {Module::atom(),         %% Module to join and send to
	    Pid::pid() | undefined, %% Pid if not default server
	    Id::integer()},         %% Interface id
	 device,                    %% device name argument
	 device_name,               %% real device name (device may be pattern)
	 port,                      %% port-id (registered as can_sock_prt)
	 index,                     %% device index (bind to)
	 intf,                      %% out-bound interface
	 bitrate :: integer(),      %% CAN bus speed
	 bitrates :: [integer()],   %% CAN bus speed
	 datarate :: integer(),     %% CAN bus data speed (FD)
	 datarates :: [integer()],  %% CAN bus data speed (FD)
	 mtu :: undefined|16|72,    %% Link MTU size
	 fd :: boolean(),           %% Request Can FD support
	 listen_only :: boolean(),  %% Listen only 
	 restart_ms :: integer(),   %% restart at bus-off condition timer
	 retry_timer :: reference(),     %% Timer reference for retry
	 pause = false,   %% Pause input
	 fs           %% can_filter:new()
	}).	

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start() ->
    start(0, [{device,"can0"}]).

start(BusId) when is_integer(BusId) ->
    start(BusId,[{device,"can0"}]);
start(Dev) when is_list(Dev) ->  %% backwards compatible for a while..
    start(0,[{device,Dev}]).

start(BusId, Opts) ->
    netlink:start(),
    can:start(),
    ChildSpec= {{?MODULE,BusId}, {?MODULE, start_link, [BusId,Opts]},
		permanent, 5000, worker, [?MODULE]},
    supervisor:start_child(can_sup, ChildSpec).

-spec start_link() -> {ok,pid()} | {error,Reason::term()}.
start_link() ->
    start_link(0, [{device,"can0"}]).

-spec start_link(Arg :: integer() | string()) ->
			{ok,pid()} | {error,Reason::term()}.
start_link(BusId) when is_integer(BusId) ->
    start_link(BusId,[{device,"can"++integer_to_list(BusId)}]);
start_link(Dev) when is_list(Dev) ->  %% backwards compatible for a while..
    start_link(0,[{device,Dev}]).

-spec start_link(BusId::integer(),Opts::[can_sock_option()]) ->
			{ok,pid()} | {error,Reason::term()}.
start_link(BusId, Opts) when is_integer(BusId), is_list(Opts) ->
    netlink:start(),
    gen_server:start_link(?MODULE, [BusId,Opts], []).

-spec stop(BusId::integer()) -> ok | {error,Reason::term()}.

stop(BusId) ->
    case supervisor:terminate_child(can_sup, {?MODULE, BusId}) of
	ok ->
	    supervisor:delete_child(can_sup, {?MODULE, BusId});
	Error ->
	    Error
    end.

-spec pause(Id::cid()) -> ok | {error, Error::atom()}.
pause(Id) when ?is_cid(Id) ->
    call(Id, pause).
-spec resume(Id::cid()) -> ok | {error, Error::atom()}.
resume(Id) when ?is_cid(Id) ->
    call(Id, resume).
-spec ifstatus(Id::cid()) ->
	  {ok, Status::atom()} | {error, Reason::term()}.
ifstatus(Id) when ?is_cid(Id) ->
    call(Id, ifstatus).

-spec dump(Id::cid()) -> ok | {error, Error::atom()}.
dump(Id) when ?is_cid(Id) ->
    call(Id,dump).

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

-spec optnames() -> [can_sock_optname()].

optnames() ->
    [ device, name, bitrate, datarate, bitrates, datarates,
      pause, fd, mtu, listen_only, restart_ms ].

-spec getopts(Id::cid(), Opts::[can_sock_optname()]) ->
	  [can_sock_option()].
getopts(Id, Opts) ->
    call(Id, {getopts, Opts}).

-spec setopts(Id::cid(), Opts::[can_sock_option()]) ->
	  [{can_sock_optname(),ok|{error,Reason::term()}}].
setopts(Id, Opts) ->
    call(Id, {setopts, Opts}).

%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------

init([BusId,Opts]) ->
    Router = proplists:get_value(router, Opts, can_router),
    Pid = proplists:get_value(receiver, Opts, undefined),
    Device = proplists:get_value(device, Opts, "can0"),
    Pause = proplists:get_value(pause, Opts, false),
    Name = proplists:get_value(name, Opts, atom_to_list(?MODULE) ++ "-" ++
				   integer_to_list(BusId)),
    BitRate = proplists:get_value(bitrate, Opts, ?DEFAULT_BITRATE),
    DataRate = proplists:get_value(datarate, Opts, ?DEFAULT_DATARATE),
    BitRates = proplists:get_value(bitrates, Opts, ?DEFAULT_BITRATES),
    DataRates = proplists:get_value(datarates, Opts, ?DEFAULT_DATARATES),
    FD = proplists:get_value(fd, Opts, false),
    ListenOnly = proplists:get_value(listen_only, Opts, false),
    RestartMs = proplists:get_value(restart_ms, Opts, 0),

    {State0,DeviceName0} = 
	case Device of 
	    "vcan"++_ ->
		%% simulate setup
		self() ! {netlink, undefined, Device, flags, [], [up]},
		{setup, Device};
	    _ ->
		{ok, _NRef} = netlink:subscribe(Device, flags, [flush]),
		{init, undefined}
	end,

    Param = #{ mod=>?MODULE,
	       device => Device,
	       index => BusId,
	       name => Name,
	       bitrate => BitRate,
	       datarate => DataRate,
	       bitrates => BitRates,
	       datarates => DataRates,
	       listen_only => ListenOnly,
	       fd => FD },
    case join(Router, Pid, Param) of
	{ok, If} when is_integer(If) ->
	    S = #s{ state = State0,
		    name = Name,
		    device_name = DeviceName0,
		    receiver = {Router,Pid,If},
		    device = Device,
		    intf = If,
		    bitrate = BitRate,
		    bitrates = BitRates,
		    fd = FD,              %% request FD support
		    datarate = DataRate,  %% requested data rate (FD)
		    datarates = DataRates,  %% requested data rate (FD)
		    listen_only = ListenOnly,
		    restart_ms = RestartMs,
		    pause = Pause,
		    fs=can_filter:new()
		  },
	    {ok, S};
	{error, Reason} = E ->
	    ?error("Failed to join ~p(~p), reason ~p", 
		   [Router, Pid, Reason]),
	    {stop, E}
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
handle_call({send,Mesg}, _From, S) when is_record(Mesg,can_frame) ->
    {Reply,S1} = send_message(Mesg,S),
    {reply, Reply, S1};

handle_call(statistics,_From,S) ->
    {reply,{ok,can_counter:list()}, S};

handle_call({getopts, Opts},_From,S) ->
    Result =
	lists:map(
	  fun(device)  -> {device,S#s.device};
	     (name)    -> {name,S#s.name};
	     (bitrate) -> {bitrate,S#s.bitrate};
	     (datarate) -> {datarate,S#s.datarate};
	     (bitrates) -> {bitrates,S#s.bitrates};
	     (datarates) -> {datarates,S#s.datarates};
	     (fd) -> {fd,S#s.fd};
	     (mtu) -> 
		  if is_port(S#s.port) ->
			  case can_sock_drv:get_mtu(S#s.port) of
			      {ok,Mtu} -> {mtu,Mtu};
			      Error={error,_Reason} ->
				  {mtu, Error}
			  end;
		     true ->
			  {mtu, enodev}
		  end;
	     (listen_only) -> {listen_only,S#s.listen_only};
	     (restart_ms) -> {restart_ms, S#s.restart_ms};
	     (Opt) -> {Opt, unknown}
	  end, Opts),
    {reply, Result, S};
handle_call({setopts, Opts},_From,S) ->
    {Reply, S1} = changeopts(Opts,S),
    {reply, Reply, S1};

handle_call({add_filter,F}, _From, S) ->
    {I,Fs} = can_filter:add(F,S#s.fs),
    S1 = S#s { fs=Fs },
    apply_filters(S1),
    {reply, {ok,I}, S1};
handle_call({set_filter,I,F}, _From, S) ->
    Fs = can_filter:set(I,F,S#s.fs),
    S1 = S#s { fs=Fs },
    apply_filters(S1),
    {reply, ok, S1};
handle_call({del_filter,I}, _From, S) ->
    {Reply,Fs} = can_filter:del(I,S#s.fs),
    S1 = S#s { fs=Fs },
    apply_filters(S1),
    {reply, Reply, S1};
handle_call({get_filter,I}, _From, S) ->
    Reply = can_filter:get(I,S#s.fs),
    {reply, Reply, S};  
handle_call(list_filter, _From, S) ->
    Reply = can_filter:list(S#s.fs),
    {reply, Reply, S};
handle_call(pause, _From, S=#s {pause = false}) ->
    {reply, {error, not_implemented_yet}, S#s {pause = true}};
handle_call(pause, _From, S) ->
    ?debug("pause when not active.", []),
    {reply, ok, S#s {pause = true}};
handle_call(resume, _From, S=#s {pause = true}) ->
    ?debug("resume.", []),
    {reply, {error, not_implemented_yet}, S#s {pause = false}};
handle_call(resume, _From, S=#s {pause = false}) ->
    ?debug("resume when not paused.", []),
    {reply, ok, S};
handle_call(ifstatus, _From, S=#s {pause = Pause}) ->
    ?debug("ifstatus.", []),
    {reply, {ok, if Pause -> paused; true -> active end}, S};
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
handle_cast({send,Mesg}, S) when is_record(Mesg,can_frame) ->
    {_, S1} = send_message(Mesg, S),
    {noreply, S1};
handle_cast({statistics,From},S) ->
    gen_server:reply(From, {ok,can_counter:list()}),
    {noreply, S};
handle_cast({add_filter,From,F}, S) ->
    {I,Fs} = can_filter:add(F,S#s.fs),
    S1 = S#s { fs=Fs },
    gen_server:reply(From, {ok,I}),
    apply_filters(S1),
    {noreply, S1};
handle_cast({del_filter,From,I}, S) ->
    {Reply,Fs} = can_filter:del(I,S#s.fs),
    S1 = S#s { fs=Fs },
    gen_server:reply(From, Reply),
    apply_filters(S1),
    {noreply, S1};
handle_cast({get_filter,From,I}, S) ->
    Reply = can_filter:get(I,S#s.fs),
    gen_server:reply(From, Reply),
    {noreply, S};  
handle_cast({list_filter,From}, S) ->
    Reply = can_filter:list(S#s.fs),
    gen_server:reply(From, Reply),
    {noreply, S};
handle_cast(_Mesg, S) ->
    ?debug("can_sock: handle_cast: ~p", [_Mesg]),
    {noreply, S}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({Port,{data,Frame}}, S=#s {receiver = {_Router, _Pid, If}}) 
  when element(1,Frame) =:= can_frame, Port =:= S#s.port ->
    S1 = input(Frame#can_frame{intf=If}, S),
    {noreply, S1};
handle_info({Port,{data,Frame}}, S=#s {receiver = {_Router, _Pid, If}}) 
  when element(1,Frame) =:= canfd_frame, Port =:= S#s.port ->
    FdFrame = #can_frame {
		 id = element(2, Frame) + ?CAN_FD_FLAG,
		 len = element(3, Frame),
		 data = element(4, Frame),
		 intf = If,
		 ts = element(6, Frame) },
    S1 = input(FdFrame, S),
    {noreply, S1};

handle_info({netlink,_NRef,Dev,flags,Old0,New0}, S) ->
    _Old = if Old0 =:= undefined -> undefined;
	      is_list(Old0) ->
		   case lists:member(up, Old0) of
		       true -> up;
		       false -> down
		   end
	   end,
    New = if New0 =:= undefined -> undefined;
	     is_list(New0) ->
		  case lists:member(up, New0) of
		      true -> up;
		      false -> down
		  end
	  end,
    ?debug("   flags ~p ~p => ~p\n", [Dev,Old0,New0]),
    ?debug("State = ~w, New = ~w, _Old = ~w\n", [S#s.state, New, _Old]),
    case S#s.state of
	init -> %% init: make sure device is in down stat 
	    case New of
		undefined -> 
		    %% device does not exist yet, we have to wait for it
		    {noreply, S};
		down when S#s.device_name =:= undefined ->
		    {noreply, setup(S, Dev)};
		down ->
		    ?debug("init: other interface ~p down\n",[Dev]),
		    {noreply, S};
		up when S#s.device_name =:= undefined ->
		    can_sock_link:down(Dev),
		    {noreply, S};
		up ->
		    ?debug("init: other interface ~p up\n",[Dev]),
		    {noreply, S};
		ignore ->
		    ?debug("init: ~p ignore\n",[Dev]),
		    {noreply, S}
	    end;
	setup ->
	    case New of
		undefined when Dev =:= S#s.device_name ->
		    {noreply, S#s { state = init, device_name=undefined }};
		undefined ->
		    ?debug("running: other interface ~p removed\n",[Dev]),
		    {noreply, S};
		up when Dev =:= S#s.device_name ->
		    {noreply, running(S)};
		up ->
		    ?debug("setup: other interface ~p up\n",[Dev]),
		    {noreply, S};
		down when Dev =:= S#s.device_name ->
		    send_state(down, S#s.receiver),
		    {noreply, S#s { state = init, device_name=undefined }};
		down ->
		    ?debug("setup: other interface ~p down\n",[Dev]),
		    {noreply, S};
		ignore ->
		    ?debug("setup: ~p ignore\n",[Dev]),
		    {noreply, S}
	    end;
	change -> %% setopts
	    case New of
		undefined when Dev =:= S#s.device_name ->  %% interface removed
		    can_sock_drv:close(S#s.port),
		    send_state(down, S#s.receiver),
		    {noreply, S#s { state = init,
				    port = undefined,
				    device_name = undefined }};
		undefined ->
		    ?debug("running: other interface ~p removed\n",[Dev]),
		    {noreply, S};
		up ->  %% ignore
		    ?debug("running: other interface ~p up\n",[Dev]),
		    {noreply, S};
		down when Dev =:= S#s.device_name ->
		    {noreply, setup(S, Dev)};
		down ->
		    ?debug("setup: other interface ~p down\n",[Dev]),
		    {noreply, S};
		ignore ->
		    ?debug("change: ~p ignore\n",[Dev]),
		    {noreply, S}
	    end;
	running ->
	    case New of
		undefined when Dev =:= S#s.device_name ->  %% interface removed
		    can_sock_drv:close(S#s.port),
		    {noreply, S#s { state = init,
				    port = undefined,
				    device_name = undefined }};
		undefined ->
		    ?debug("running: other interface ~p removed\n",[Dev]),
		    {noreply, S};
		up ->  %% new interface? ignore
		    ?debug("running: other interface ~p up\n",[Dev]),
		    {noreply, S};
		down when Dev =:= S#s.device_name ->  %% external down?
		    can_sock_drv:close(S#s.port),
		    send_state(down, S#s.receiver),
		    {noreply, S#s { state = init,
				    port = undefined,
				    device_name = undefined
				  }};
		down -> %% other interface
		    ?debug("running: other interface ~p down\n",[Dev]),
		    {noreply, S}
	    end
    end;

handle_info(_Info, S) ->
    ?debug("can_sock: got message=~p", [_Info]),
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

%% FIXME; device change require new subscription and restart! (and re-join!!)
%%        name change require update of join Param?
changeopts(Opts, S) ->
    ?debug("can_sock: changeopts ~p\n", [Opts]),
    changeopts_(Opts, [], false, S).

changeopts_([{Key,Value}|Opts], Acc, SetLink, S) ->
    case Key of
	device ->
	    changeopts_(Opts, SetLink, [{Key,ok}|Acc], S#s {device=Value});
	name -> 
	    changeopts_(Opts, SetLink, [{Key,ok}|Acc], S#s {name=Value });
	bitrate ->
	    changeopts_(Opts, true, [{Key,ok}|Acc], S#s {bitrate=Value });
	datarate ->
	    changeopts_(Opts, true, [{Key,ok}|Acc], S#s {datarate=Value });
	fd -> 
	    changeopts_(Opts, true, [{Key,ok}|Acc], S#s { fd=Value });
	listen_only ->
	    changeopts_(Opts, true, [{Key,ok}|Acc], S#s { listen_only=Value });
	restart_ms ->
	    changeopts_(Opts, true, [{Key,ok}|Acc], S#s { restart_ms=Value });
	_ ->
	    changeopts_(Opts, SetLink, [{Key,{error,einval}}|Acc],  S)
    end;
changeopts_([], true, Acc, S) ->
    can_sock_link:down(S#s.device_name),
    {lists:reverse(Acc), S#s { state = change }};
changeopts_([], false, Acc, S) ->
    {lists:reverse(Acc), S}.


setup(S, Dev)  when S#s.state =:= init; S#s.state =:= change ->
    _Res = set_link_opts(S, Dev),
    ?debug("set = ~p", [_Res]),
    _Res1 = can_sock_link:up(Dev),
    ?debug("up = ~p", [_Res1]),
    S#s { state = setup, device_name = Dev }.

running(S) when S#s.state =:= setup ->
    case can_sock_drv:open() of
	{ok,Port} ->
	    ?debug("can_sock: drv open ~p ~p\n", [S#s.device_name, Port]),
	    %% timer:sleep(1000),
	    case get_index(Port, S#s.device_name) of
		{ok,Index} ->
		    ?debug("can_sock: index ~s = ~w\n", [S#s.device_name,
							 Index]),
		    case can_sock_drv:bind(Port,Index) of
			ok ->
			    ?debug("can_sock: bound\n", []),
			    Mtu = case can_sock_drv:get_mtu(Port) of
				      {ok,_Mtu} -> _Mtu;
				      {error,_MtuReason}  ->
					  ?error("unable to read MTU ~p",
						 [_MtuReason]),
					  16
				  end,
			    FDRes = set_fd(Port,S#s.fd, Mtu),
			    ?debug("can_sock: fd ~w = ~w, mtu=~w",
				   [FDRes, S#s.fd, Mtu]),
			    can_sock_drv:set_error_filter(Port, 16#ff),
			    Param = #{ device_name => S#s.device_name,
				       mtu => Mtu, fd => FDRes },
			    send_state(Param, S#s.receiver),
			    send_state(up, S#s.receiver),
			    S#s { state = running, 
				  port = Port,
				  mtu = Mtu,
				  index = Index
				};
			{error,_BindReason} ->
			    ?error("cansock:bind error ~p", [_BindReason]),
			    S
		    end;
		{error, "enodev"} -> %% fixme atom?
		    ?debug("cansock:running: ~s@~w  error ~s",
			   [S#s.device_name,S#s.bitrate,"enodev"]),
		    send_state(down, S#s.receiver),
		    can_sock_drv:close(Port),
		    S#s { state = init };
		{error,_Error} ->
		    ?debug("cansock:running: ~s@~w  error ~p",
			   [S#s.device_name,S#s.bitrate,_Error]),
		    can_sock_drv:close(Port),
		    S#s { state = init }
	    end;
	{error, _OpenError} -> %% unkown terminate
	    ?error("cansock:open error ~p", [_OpenError]),
	    send_state(down, S#s.receiver),
	    S#s { state = init }
    end.

get_link_opts(Dev) ->
    case os:cmd("ip -j -d link show " ++ Dev) of
	Json = "["++_ ->
	    try jsone:decode(list_to_binary(Json),
			     [{keys, attempt_atom},
			      {object_format, map}]) of
		[IF] ->
		    {ok,IF}
	    catch
		error:_ ->
		    {error, einval}
	    end;
	_ ->
	    {error, einval}
    end.

set_link_opts(S, Dev="vcan"++_) -> %% vcan
    %% For vcan we ignore various option but we want to simulate FD mode
    if S#s.fd ->
	    can_sock_link:set(Dev, [{mtu, 72}]);
       true ->
	    can_sock_link:set(Dev, [{mtu, 16}])
    end;
set_link_opts(S, Dev) ->
    Fd = if S#s.fd -> true; true -> false end,
    Res = 
	if S#s.fd ->
		can_sock_link:set(Dev,
				  [{type, "can"},
				   {fd,Fd},
				   {bitrate,S#s.bitrate},
				   {dbitrate,S#s.datarate},
				   {listen_only,S#s.listen_only},
				   {restart_ms,S#s.restart_ms}]);
	   true ->
		can_sock_link:set(Dev,
				  [{type, "can"},
				   {fd,false},
				   {bitrate,S#s.bitrate},
				   {listen_only,S#s.listen_only},
				   {restart_ms,S#s.restart_ms}])
	end,
    send_state(#{ fd=>Fd,
		  bitrate=>S#s.bitrate,
		  datarate=>S#s.datarate,
		  listen_only=>S#s.listen_only}, 
	       S#s.receiver),
    Res.


-define(IFLA_CAN_BITTIMING, 1).
-define(IFLA_CAN_BITTIMING_CONST, 2).
-define(IFLA_CAN_CLOCK, 3).
-define(IFLA_CAN_STATE, 4).
-define(IFLA_CAN_CTRLMODE, 5).
-define(IFLA_CAN_RESTART_MS, 6).
-define(IFLA_CAN_RESTART, 7).
-define(IFLA_CAN_BERR_COUNTER, 8).
-define(IFLA_CAN_DATA_BITTIMING, 9).
-define(IFLA_CAN_DATA_BITTIMING_CONST, 10).
-define(IFLA_CAN_TERMINATION, 11).
-define(IFLA_CAN_TERMINATION_CONST, 12).
-define(IFLA_CAN_BITRATE_CONST, 13).
-define(IFLA_CAN_DATA_BITRATE_CONST, 14).
-define(IFLA_CAN_BITRATE_MAX, 15).

-define(CAN_STATE_ERROR_ACTIVE, 0).     %% RX/TX error count < 96
-define(CAN_STATE_ERROR_WARNING, 1).    %% RX/TX error count < 128
-define(CAN_STATE_ERROR_PASSIVE, 2).    %% RX/TX error count < 256
-define(CAN_STATE_BUS_OFF, 3).          %% RX/TX error count >= 256
-define(CAN_STATE_STOPPED, 4).          %% Device is stopped
-define(CAN_STATE_SLEEPING, 5).

-define(CanBitTiming(Endian,BitRate,SamplePoint,Tq,PropSeg,
		     PhaseSeg1,PhasSeg2,Sjw,Brp),
	BitRate:32/Endian,
	SamplePoint:32/Endian,
	Tq:32/Endian,
	PropSeg:32/Endian,
	PhaseSeg1:32/Endian,
	PhaseSeg2:32/Endian,
	Sjw:32/Endian,
	Brp:32/Endian).

-define(CanBitTimeingConst(Endian,Name,
			   TSeg1Min, TSeg1Max,
			   TSeg2Min, TSeg2Max,
			   SjwMax, 
			   BrpMin, BrpMax, BrpInc),
	Name:16/binary, 
	TSeg1Min:32/Endian, TSeg1Max:32/Endian,
	TSeg2Min:32/Endian, TSeg2Max:32/Endian,
	SjwMax:32/Endian,
	BrpMin:32/Endian, BrpMax:32/Endian, BrpInc:32/Endian).
	

get_netlink_opts(Dev) ->
    case netlink:getlinkattr(Dev, linkinfo) of
	[{linkinfo,Info}] ->
	    Data = proplists:get_value(data, Info),
	    TLVs = netlink_codec:decode_tlv_list(Data),
	    decode_can_tlvs(TLVs);
	_ ->
	    false
    end.

decode_can_tlvs([{?IFLA_CAN_BITTIMING, native,
		 <<?CanBitTiming(native,BitRate,SamplePoint,Tq,PropSeg,
				 PhaseSeg1,PhasSeg2,Sjw,Brp)>>} | TLVs]) ->
    [{bittiming,
      [
       {bitrate, BitRate},
       {sample_point, (SamplePoint/10)/100},
       {tq, Tq},
       {prop_seg, PropSeg},
       {phase_seg1, PhaseSeg1},
       {phase_seg2, PhaseSeg2},
       {sjw, Sjw},
       {brp, Brp}]} | decode_can_tlvs(TLVs)];
decode_can_tlvs([{?IFLA_CAN_BITTIMING_CONST, native,
		  <<?CanBitTimeingConst(native,Name,
					TSeg1Min, TSeg1Max,
					TSeg2Min, TSeg2Max,
					SjwMax, 
					BrpMin, BrpMax, BrpInc)>>} | TLVs]) ->
    [{bittiming_const,
      [{name, cstring(Name)},
       {tseg1_min,TSeg1Min},
       {tseg1_max, TSeg1Max},
       {tseg2_min,TSeg2Min},
       {tseg2_max, TSeg2Max},
       {sjw_max, SjwMax}, 
       {brp_min,BrpMin},
       {brp_max,BrpMax},
       {brp_inc,BrpInc}]} | decode_can_tlvs(TLVs)];
decode_can_tlvs([{?IFLA_CAN_CLOCK, native, <<CanClock:32/native>>} | TLVs]) ->
    [{clock, CanClock} | decode_can_tlvs(TLVs)];

decode_can_tlvs([{?IFLA_CAN_STATE, native, <<CanState:32/native>>} | TLVs]) ->
    State = case CanState of
		?CAN_STATE_ERROR_ACTIVE -> active;
		?CAN_STATE_ERROR_WARNING -> error_warning;
		?CAN_STATE_ERROR_PASSIVE -> error_passive;
		?CAN_STATE_BUS_OFF       -> bus_off;
		?CAN_STATE_STOPPED       -> stopped;
		?CAN_STATE_SLEEPING      -> sleeping;
		_ -> CanState
	    end,
    [{state, State} | decode_can_tlvs(TLVs)];

decode_can_tlvs([{?IFLA_CAN_CTRLMODE, native,
		  <<Mask:32/native, Flags:32/native>>} | TLVs]) ->
    [{ctrlmode,[{mask,Mask},{flags,Flags}]} | decode_can_tlvs(TLVs)];
decode_can_tlvs([{?IFLA_CAN_RESTART_MS, native,
		  <<RestartMs:32/native>>} | TLVs]) ->
    [{restart_ms, RestartMs}  | decode_can_tlvs(TLVs)];

decode_can_tlvs([{?IFLA_CAN_BERR_COUNTER, native,
		  <<TxErr:16/native, RxErr:16/native>>} | TLVs]) ->
    [{berr_counter,[{txerr,TxErr},{rxerr,RxErr}]} | decode_can_tlvs(TLVs)];

decode_can_tlvs([{?IFLA_CAN_DATA_BITTIMING, native,
		 <<?CanBitTiming(native,BitRate,SamplePoint,Tq,PropSeg,
				 PhaseSeg1,PhasSeg2,Sjw,Brp)>>} | TLVs]) ->
    [{data_bittiming,
      [
       {bitrate, BitRate},
       {sample_point, (SamplePoint/10)/100},
       {tq, Tq},
       {prop_seg, PropSeg},
       {phase_seg1, PhaseSeg1},
       {phase_seg2, PhaseSeg2},
       {sjw, Sjw},
       {brp, Brp}]} | decode_can_tlvs(TLVs)];
decode_can_tlvs([{?IFLA_CAN_DATA_BITTIMING_CONST, native,
		  <<?CanBitTimeingConst(native,Name,
					TSeg1Min, TSeg1Max,
					TSeg2Min, TSeg2Max,
					SjwMax, 
					BrpMin, BrpMax, BrpInc)>>} | TLVs]) ->
    [{data_bittiming_const,
      [{name, cstring(Name)},
       {tseg1_min,TSeg1Min},
       {tseg1_max, TSeg1Max},
       {tseg2_min,TSeg2Min},
       {tseg2_max, TSeg2Max},
       {sjw_max, SjwMax}, 
       {brp_min,BrpMin},
       {brp_max,BrpMax},
       {brp_inc,BrpInc}]} | decode_can_tlvs(TLVs)];

decode_can_tlvs([{?IFLA_CAN_BITRATE_MAX, native, <<Rate:32/native>>} | TLVs]) ->
    [{bitrate_max, Rate} | decode_can_tlvs(TLVs)];

decode_can_tlvs([TLV | TLVs]) ->
    [TLV | decode_can_tlvs(TLVs)];
decode_can_tlvs([]) ->
    [].


cstring(<<0,_/binary>>) -> [];
cstring(<<C,Bin/binary>>) -> [C|cstring(Bin)];
cstring(<<>>) -> [].

%% Enable/Disable FD frames 
set_fd(Port,false,_Mtu) ->
    can_sock_drv:set_fd_frames(Port, false),
    false;
set_fd(Port,true,72) -> %% Mtu=72!
    can_sock_drv:set_fd_frames(Port, true),
    true;
set_fd(Port,true,_Mtu) ->
    can_sock_drv:set_fd_frames(Port, false),
    false.

get_index(_Port, "any") -> {ok, 0};
get_index(Port,IfName) -> can_sock_drv:ifindex(Port,IfName).

send_message(Mesg, S) when is_record(Mesg,can_frame), S#s.intf =:= 0 ->
    {ok,S};
send_message(_Mesg, S) when S#s.port =:= undefined ->
    if not S#s.pause ->
	    ?debug("~s: ~p, Msg ~p dropped", [?MODULE,S#s.device,_Mesg]);
       true -> ok
    end,
    {ok,S};
send_message(Mesg, S) when is_record(Mesg,can_frame) ->
    case can_sock_drv:send(S#s.port,S#s.index,Mesg) of
	ok ->
	    S1 = count(output_frames, S),
	    {ok,S1};
	{error,_Reason} ->
	    output_error(?can_error_data,S)
    end;
send_message(_Mesg, S) ->
    output_error(?can_error_data,S).

count(Counter,S) ->
    can_counter:update(Counter, 1),
    S.

output_error(Reason,S) ->
    {{error,Reason}, oerr(Reason,S)}.

oerr(Reason,S) ->
    S1 = count(output_error, S),
    count({output_error,Reason}, S1).

%% ierr(Reason,S) ->
%%    S1 = count(input_error, S),
%%    count({input_error,Reason}, S1).

apply_filters(S) ->
    {ok,Filter} = can_filter:list(S#s.fs),
    Fs = [F || {_I,F} <- Filter],
    ?verbose("apply_filters: fs=~p", [Fs]),
    _Res =
	if Fs =:= [] ->
		All = #can_filter { id = 0, mask = 0 },
		can_sock_drv:set_filters(S#s.port, [All]);
	   true ->
		can_sock_drv:set_filters(S#s.port, Fs)
	end,
    ?verbose("Res = ~p", [_Res]),
    ok.

join(undefined, Pid, _Arg) when is_pid(Pid) ->
    {ok,?DEFAULT_IF};
join(Module, Pid, Arg) when is_atom(Module), is_pid(Pid) ->
    Module:join(Pid, Arg);
join(Module, undefined, Arg) when is_atom(Module) ->
    Module:join(Arg).
    
%% The filters are pushed onto the driver, here we
%% should check that this is also the case.
input(Frame, S=#s {receiver = Receiver}) ->
    %% read number of filtered frames ?
    input_frame(Frame, Receiver),
    if ?is_can_id_err(Frame#can_frame.id) ->
	    count(error_frames, S);
       true ->
	    count(input_frames, S)
    end.

%%    case can_filter:input(Frame, S#s.fs) of
%%	true ->
%%	    can_router:input(Frame),
%%	    count(input_frames, S);
%%	false ->
%%	    S1 = count(input_frames, S),
%%	    count(filter_frames, S1)
%%  end.

input_frame(Frame, {undefined, Pid, _If}) when is_pid(Pid) ->
    Pid ! Frame;
input_frame(Frame,{Module, undefined, _If}) when is_atom(Module) ->
    Module:input(Frame);
input_frame(Frame,{Module, Pid, _If}) when is_atom(Module), is_pid(Pid) ->
    Module:input(Pid,Frame).

send_state(State, {undefined, Pid, Id}) when is_pid(Pid) ->
    Pid ! {if_state_event, Id, State};
send_state(State,{Module, undefined, Id}) when is_atom(Module) ->
    Module:if_state_event(Id, State);
send_state(State,{Module, Pid, Id}) when is_atom(Module), is_pid(Pid) ->
    Module:if_state_event(Pid, Id, State).

call(Pid, Request) when is_pid(Pid) -> 
    gen_server:call(Pid, Request);
call(Id, Request) when is_integer(Id); is_list(Id) ->
    case can_router:interface_pid({?MODULE, Id})  of
	Pid when is_pid(Pid) -> gen_server:call(Pid, Request);
	Error -> Error
    end.
