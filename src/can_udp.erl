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
%%% File    : can_udp.erl
%%% Author  : Tony Rogvall <tony@rogvall.se>
%%% Description : CAN/UDP adaptor module
%%%
%%% Created : 30 Jan 2009 by Tony Rogvall <tony@rogvall.se>
%%%-------------------------------------------------------------------
-module(can_udp).

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

-export([reuse_port/0]).
-export([lookup_ip/2, lookup_ifaddr/2]).
%% Test API

-export([dump/1]).

-define(DEFAULT_BITRATE,      250000).
-define(DEFAULT_DATARATE,     250000).

-type cid() :: integer() | pid() | string().
-define(is_cid(X),(is_integer((X)) orelse is_pid((X)) orelse is_list((X)))).

-record(s, 
	{
	 name::string(),
	 receiver={can_router, undefined, undefined} ::
	   {Module::atom(), %% Module to join and send to
	    Pid::pid() | undefined,     %% Pid if not default server
	    Id::integer() | undefined}, %% Interface id
	 in,          %% incoming udp socket
	 out,         %% outgoing udp socket
	 maddr,       %% multicast address
	 ttl = 1,     %% multicast ttl value
	 ifaddr,      %% interface address (any, {192,168,1,4} ...)
	 mport,       %% port number used
	 oport,       %% output port number used
	 pause = false,   %% Pause input
	 fs,          %% can_filter:new()
	 fd = false,  %% FD support
	 bitrate = ?DEFAULT_BITRATE,
	 datarate = ?DEFAULT_DATARATE
	}).

%% MAC specific reuseport options
-define(SO_REUSEPORT, 16#0200).

-define(IPPROTO_IP,   0).
-define(IPPROTO_TCP,  6).
-define(IPPROTO_UDP,  17).
-define(SOL_SOCKET,   16#ffff).

-define(CAN_MULTICAST_ADDR, {224,0,0,1}).
-define(CAN_MULTICAST_IF,   {0,0,0,0}).
-define(CAN_UDP_PORT, 51712).

-define(DEFAULT_IF,0).

-define(FLAG_FD,   16#0001).
-define(FLAG_NONE, 16#0000).

-define(SUPPORTED_BITRATES, [10000,20000,50000,100000,125000,
			     250000,500000,800000,1000000]).
-define(SUPPORTED_DATARATES, [10000,20000,50000,100000,125000,
			      250000,500000,800000,1000000,
			      2000000,3000000,4000000,5000000]).
-define(DEFAULT_BIT_RATE, 250000).
-define(DEFAULT_DATA_RATE, 1000000).
			      

-type can_udp_optname() ::
	device | name | bitrate | datarate | bitrates | datarates |
	maddr | ifaddr | ttl | pause | fd.

-type can_udp_option() ::
	{name,     IfName::string()} |
	{maddr,    inet:ip_address()} |
	{ifaddr,   inet:ip_address()} |
	{ttl,      integer()} |
	{bitrate, CANBitrate::integer()} |
	{datarate, CANDatarate::integer()} |
	{pause,    Pause::boolean()} |
	{fd,       FD::boolean()}.

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------

-spec start() -> {ok,pid()} | {error,Reason::term()}.
start() ->
    start(0, []).

-spec start(BusId::integer()) -> {ok,pid()} | {error,Reason::term()}.
start(BusId) when is_integer(BusId)->
    start(BusId, []).

-spec start(BusId::integer(),Opts::[can_udp_option()]) ->
		   {ok,pid()} | {error,Reason::term()}.

start(BusId, Opts) when is_integer(BusId), is_list(Opts) ->
    can:start(),
    ChildSpec= {{?MODULE,BusId}, {?MODULE, start_link, [BusId,Opts]},
		permanent, 5000, worker, [?MODULE]},
    supervisor:start_child(can_if_sup, ChildSpec).

-spec start_link() -> {ok,pid()} | {error,Reason::term()}.
start_link() ->
    start_link(0, []).

-spec start_link(BusId::integer()) -> {ok,pid()} | {error,Reason::term()}.
start_link(BusId) when is_integer(BusId) ->
    start_link(BusId, []).

-spec start_link(BusId::integer(),Opts::[can_udp_option()]) ->
		   {ok,pid()} | {error,Reason::term()}.    
start_link(BusId,Opts) ->
    ?debug("can_udp: start_link ~p ~p\n", [BusId,Opts]),
    Res = gen_server:start_link(?MODULE, [BusId, Opts], []),
    ?debug("can_udp: res ~p\n", [Res]),
    Res.
    

-spec stop(BusId::integer()) -> ok | {error,Reason::term()}.

stop(BusId) ->
    case supervisor:terminate_child(can_if_sup, {?MODULE, BusId}) of
	ok ->
	    supervisor:delete_child(can_if_sup, {?MODULE, BusId});
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

-spec optnames() -> [can_udp_optname()].

optnames() ->
    [ device, name, bitrate, datarate, bitrates, datarates,
      maddr, ifaddr, ttl, pause, fd ].

-spec getopts(Id::cid(), Opts::[can_udp_optname()]) ->
	  [can_udp_option()].
getopts(Id, Opts) ->
    call(Id, {getopts, Opts}).

-spec setopts(Id::integer()|pid()|string(), Opts::[can_udp_option()]) ->
	  [{can_udp_optname(),ok|{error,Reason::term()}}].

setopts(Id, Opts) ->
    call(Id, {setopts, Opts}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([BusId, Opts]) ->
    MAddr  = proplists:get_value(maddr, Opts, ?CAN_MULTICAST_ADDR),
    Mttl   = proplists:get_value(ttl, Opts, 1),
    LAddr0 = proplists:get_value(ifaddr, Opts, ?CAN_MULTICAST_IF),
    Router = proplists:get_value(router, Opts, can_router),
    Pid = proplists:get_value(receiver, Opts, undefined),
    MPort = ?CAN_UDP_PORT+BusId,
    Pause = proplists:get_value(pause, Opts, false),
    BitRate = proplists:get_value(bitrate,Opts,?DEFAULT_BITRATE),
    DataRate = proplists:get_value(datarate,Opts,?DEFAULT_DATARATE),
    FD    = proplists:get_value(fd, Opts, false),
    LAddr = if is_tuple(LAddr0) -> 
		    LAddr0;
	       is_list(LAddr0) ->
		     case lookup_ip(LAddr0, inet) of
			 {error,_} ->
			     ?warning("No such interface ~p",[LAddr0]),
			     {0,0,0,0};
			 {ok,IP} -> IP
		     end;
		LAddr0 =:= any -> 
		    {0,0,0,0};
		true ->
		     ?warning("No such interface ~p",[LAddr0]),
		    {0,0,0,0}
	    end,
    RAddr = LAddr, %% ?CAN_MULTICAST_IF,

    SendOpts = [{active,false},{multicast_if,LAddr},
		{multicast_ttl,Mttl},{multicast_loop,true}],

    RecvOpts = [{reuseaddr,true},{ifaddr,RAddr}] ++reuse_port(),

    MultiOpts = [{add_membership,{MAddr,LAddr}}],
    Name = proplists:get_value(name, Opts, atom_to_list(?MODULE) ++ "-" ++
				   integer_to_list(BusId)),
    case gen_udp:open(0, SendOpts) of
	{ok,Out} ->
	    {ok,OutPort} = inet:port(Out),
	    OutOpts = [active,mode,multicast_if,multicast_ttl,
		       multicast_loop,reuseaddr],
	    {ok,OutName} = inet:sockname(Out),
	    io:format("output options: port=~p, addr=~p, ~p\n", 
		      [OutPort,OutName,get_sock_opts(Out, OutOpts)]),
	    case catch gen_udp:open(MPort,RecvOpts++MultiOpts++
					[{mode,binary},{active,true}]) of
		{ok,In} ->
		    {ok,InPort} = inet:port(In),
		    {ok,InName} = inet:sockname(In),
		    InOpts = [active,mode,multicast_if,multicast_ttl,
			      multicast_loop,reuseaddr],
		    io:format("input options: port=~p, addr=~p, ~p\n", 
			      [InPort, InName, get_sock_opts(In, InOpts)]),
		    Param = #{ mod=>?MODULE,
			       device => MAddr,
			       index => BusId,
			       name => Name,
			       bitrate => ?DEFAULT_BIT_RATE,
			       bitrates => ?SUPPORTED_BITRATES,
			       datarate => ?DEFAULT_DATA_RATE,
			       datarates => ?SUPPORTED_DATARATES,
			       listen_only => false,
			       fd => FD },
		    case join(Router, Pid, Param) of
			{ok, If} when is_integer(If) ->
			    Receiver = {Router,Pid,If},
			    send_state(up, Receiver),
			    {ok, #s{ receiver=Receiver,
				     in=In,
				     mport=MPort,
				     out=Out,
				     oport=OutPort,
				     maddr=MAddr,
				     pause = Pause,
				     fd=FD,
				     bitrate=BitRate,
				     datarate=DataRate,
				     fs=can_filter:new()
				   }};
			{error, Reason} = Error ->
			    ?error("Failed to join ~p(~p), reason ~p", 
					[Router, Pid, Reason]),
			    {stop, Error}
		    end;
		{'EXIT',Reason} ->
		    {stop,Reason};
		Error ->
		    {stop, Error}
	    end;
	Error ->
	    {stop, Error}
    end.


get_sock_opts(Socket, [OptName|Options]) ->    
    case inet:getopts(Socket, [OptName]) of
	{ok,[]} -> 
	    [{OptName,error}|get_sock_opts(Socket, Options)];
	{ok,[{OptName,Value}]} ->
	    [{OptName,Value}|get_sock_opts(Socket, Options)];
	{error,Reason} ->
	    [{OptName,{error,Reason}}|get_sock_opts(Socket, Options)]
    end;
get_sock_opts(_Socket, []) -> 
    [].
	
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
    {reply,{ok,can_counter:list()}, S};
handle_call({getopts, Opts},_From,S) ->
    Result =
	lists:map(
	  fun
	      (name)   -> {name,S#s.name};
	      (maddr)  -> {maddr,S#s.maddr};
	      (ifaddr) -> {ifaddr,S#s.ifaddr};
	      (bitrate) -> {bitrate,S#s.bitrate};
	      (datarate) -> if S#s.fd -> {datarate,S#s.datarate};
			       true -> {datarate, error}
			    end;
	      (bitrates) -> {bitrates,?SUPPORTED_BITRATES};
	      (datarates) -> {datarates,?SUPPORTED_DATARATES};
	      (ttl)    -> {ttl,S#s.ttl};
	      (mport)  -> {mport,S#s.mport};
	      (fd)     -> {fd,S#s.fd};
	      (Opt) -> {Opt, undefined}
	  end, Opts),
    {reply, Result, S};
handle_call({setopts, Opts},_From,S) ->
    {Result,S1} = changeopts(Opts, S),
    {reply, Result, S1};
handle_call({add_filter,F}, _From, S) ->
    {I,Fs} = can_filter:add(F,S#s.fs),
    {reply, {ok,I}, S#s { fs=Fs }};
handle_call({set_filter,I,F}, _From, S) ->
    Fs = can_filter:set(I,F,S#s.fs),
    S1 = S#s { fs=Fs },
    {reply, ok, S1};
handle_call({del_filter,I}, _From, S) ->
    {Reply,Fs} = can_filter:del(I,S#s.fs),
    {reply, Reply, S#s { fs=Fs }};
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
handle_cast({send,Mesg}, S) ->
    {_, S1} = send_message(Mesg, S),
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
    ?debug("can_udp: handle_cast: ~p\n", [_Mesg]),
    {noreply, S}.


%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({udp,U,_Addr,Port,Data}, S) when S#s.in == U ->
    if Port =:= S#s.oport ->
	    ?debug("can_udp: discard ~p ~p ~p\n", [_Addr,Port,Data]),
	    {noreply, S};
       true->
	    %% FIXME: add check that _Addr is a local address
	    case Data of
 		<<CId:32/little,Flags:16/little,FLen:16/little,CData/binary>> ->
		    ?debug("CUd=~8.16.0B, Flags=~4.16.0B, FLen=~4.16.0B, CData=~p\n",
			   [CId,Flags,FLen,CData]),
		    Ts = ?CAN_NO_TIMESTAMP, %% fixme: add timestamp
		    if Flags band ?FLAG_FD =/= 0 -> 
			    {noreply,input(CId bor ?CAN_FD_FLAG,FLen,CData,Ts,S)};
		       true ->
			    {noreply, input(CId,FLen,CData,Ts,S)}
		    end;
		_ ->
		    ?debug("can_udp: Got ~p\n", [Data]),
		    {noreply, ierr(?can_error_corrupt,S)}
	    end
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

changeopts(Opts, S) ->
    changeopts_(Opts,[],S).
    
changeopts_([{Key,Value}|Opts],Acc,S) ->
    case Key of
	name ->
	    changeopts_(Opts,[{Key,ok}|Acc],S#s{name=Value});
	maddr -> %% FIXME: reopen!
	    changeopts_(Opts,[{Key,ok}|Acc],S#s{maddr=Value});
	mport -> %% FIXME: reopen!
	    changeopts_(Opts,[{Key,ok}|Acc],S#s{mport=Value});
	ifaddr -> %% FIXME: reopen!
	    changeopts_(Opts,[{Key,ok}|Acc],S#s{ifaddr=Value});
	ttl -> %% FIXME: inet:setopts!
	    changeopts_(Opts,[{Key,ok}|Acc],S#s{ttl=Value});
	fd ->
	    changeopts_(Opts,[{Key,ok}|Acc],S#s{fd=Value});
	bitrate ->
	    changeopts_(Opts,[{Key,ok}|Acc],S#s{bitrate=Value});
	datarate ->
	    changeopts_(Opts,[{Key,ok}|Acc],S#s{datarate=Value});
	_ ->
	    changeopts_(Opts,[{Key,{error,einval}}|Acc],S)
    end;
changeopts_([],Acc,S) ->
    {lists:reverse(Acc), S}.


reuse_port() ->
    case os:type() of
	{unix,Type} when Type =:= darwin; Type =:= freebsd ->
	    [{raw,?SOL_SOCKET,?SO_REUSEPORT,<<1:32/native>>}];
	_ ->
	    []
    end.

lookup_ip(Name,Family) ->
    case inet_parse:address(Name) of
	{error,_} ->
	    lookup_ifaddr(Name,Family);
	Res -> Res
    end.

lookup_ifaddr(Name,Family) ->
    case inet:getifaddrs() of
	{ok,List} ->
	    case lists:keyfind(Name, 1, List) of
		false -> {error, enoent};
		{_, Flags} ->
		    AddrList = proplists:get_all_values(addr, Flags),
		    get_family_addr(AddrList, Family)
	    end;
	_ ->
	    {error, enoent}
    end.
	
get_family_addr([IP|_IPs], inet) when tuple_size(IP) =:= 4 -> {ok,IP};
get_family_addr([IP|_IPs], inet6) when tuple_size(IP) =:= 8 -> {ok,IP};
get_family_addr([_|IPs],Family) -> get_family_addr(IPs,Family);
get_family_addr([],_Family) -> {error, enoent}.


send_message(Mesg, S) when is_record(Mesg,can_frame) ->
    ?debug("can_udp:send_message: [~s]", [can_probe:format_frame(Mesg)]),
    if is_binary(Mesg#can_frame.data) ->
	    send_bin_message(Mesg, Mesg#can_frame.data, S);
       true ->
	    output_error(?can_error_data,S)
    end;
send_message(_Mesg, S) ->
    output_error(?can_error_data,S).


send_bin_message(Mesg, Bin, S) ->
    send_message(Mesg#can_frame.id,
		 Mesg#can_frame.len,
		 Bin,
		 S).

send_message(ID, Len, Data, S) ->
    FD = ?is_can_id_fd(ID) and S#s.fd,  %% request FD and support FD
    Len1 = if FD -> adjust_fd_len(Len);
	      true -> Len band 16#f
	   end,
    Size = byte_size(Data),
    Bin1 = pad_data(FD, Data, Size, Len1),
    %% Mask ID on output message, remove error bits and bad id bits
    ID1 = if ?is_can_id_eff(ID) ->
		  ID band (?CAN_EFF_FLAG bor ?CAN_RTR_FLAG bor ?CAN_EFF_MASK);
	     true ->
		  ID band (?CAN_RTR_FLAG bor ?CAN_SFF_MASK)
	  end,
    Flags = if FD -> ?FLAG_FD;
	       true -> ?FLAG_NONE
	    end,
    case gen_udp:send(S#s.out, S#s.maddr, S#s.mport,
		      <<ID1:32/little, 
			Flags:16/little, Len1:16/little,
			Bin1/binary>>) of
	ok ->
	    {ok,count(output_frames, S)};
	_Error ->
	    ?debug("gen_udp: failure=~p\n", [_Error]),
	    output_error(?can_error_transmission,S)
    end.

pad_data(false, _Data, 0, _Len) ->
    <<0,0,0,0,0,0,0,0>>;
pad_data(false, Data, Size, _Len) when Size < 8 ->
    << Data/binary, 0:(8-Size)/unit:8 >>;
pad_data(false, Data, 8, _Len) ->
    Data;
pad_data(false, <<Data:8/binary,_/binary>>, _, _Len) ->
    Data; %% truncate if we got this far
pad_data(true, Data, Size, Len) when Size < Len ->
    << Data/binary, 0:(Len-Size)/unit:8 >>;
pad_data(true, Data, _Size, _Len) ->
    Data.
    
%% 0, 8, 12, 16, 20, 24, 32, 48, 64
%%   8, 4,  4,  4,  4,  8,  16, 16
adjust_fd_len(0) -> 0;
adjust_fd_len(Len) when Len =< 8 -> 8;
adjust_fd_len(Len) when Len =< 12 -> 12;
adjust_fd_len(Len) when Len =< 16 -> 16;
adjust_fd_len(Len) when Len =< 20 -> 20;
adjust_fd_len(Len) when Len =< 24 -> 24;
adjust_fd_len(Len) when Len =< 32 -> 32;
adjust_fd_len(Len) when Len =< 48 -> 48;
adjust_fd_len(Len) when Len =< 64 -> 64.

send_state(State, {undefined, Pid, Id}) when
      is_integer(Id), is_pid(Pid) ->
    Pid ! {if_state_event, Id, State};
send_state(State,{Module, undefined, Id}) when
      is_integer(Id), is_atom(Module) ->
    Module:if_state_event(Id, State);
send_state(State,{Module, Pid, Id}) when 
      is_integer(Id), is_atom(Module), is_pid(Pid) ->
    Module:if_state_event(Pid, Id, State).

count(Counter,S) ->
    can_counter:update(Counter, 1),
    S.

output_error(Reason,S) ->
    {{error,Reason}, oerr(Reason,S)}.

oerr(Reason,S) ->
    S1 = count(output_error, S),
    count({output_error,Reason}, S1).

ierr(Reason,S) ->
    S1 = count(input_error, S),
    count({input_error,Reason}, S1).

join(undefined, Pid, _Arg) when is_pid(Pid) ->
    {ok,?DEFAULT_IF};
join(Module, Pid, Arg) when is_atom(Module), is_pid(Pid) ->
    Module:join(Pid, Arg);
join(Module, undefined, Arg) when is_atom(Module) ->
    Module:join(Arg).
    

input(CId,Len,CData,Ts, S=#s {receiver = {_Module, _Pid, If}}) ->
    case catch can:icreate(CId,Len,If,CData,Ts) of
	{'EXIT', {Reason,_}} when is_atom(Reason) ->
	    ierr(Reason,S);
	{'EXIT', Reason} when is_atom(Reason) ->
	    ierr(Reason,S);
	{'EXIT', _Reason} ->
	    ierr(?can_error_corrupt,S);
	M when is_record(M,can_frame) ->
	    input(M, S);
	_Other ->
	    ?debug("can_udp: Got ~p\n", [_Other]),
	    S
    end.

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
    Module:input(Pid,Frame).

call(Pid, Request) when is_pid(Pid) -> 
    gen_server:call(Pid, Request);
call(Id, Request) when is_integer(Id); is_list(Id) ->
    case can_router:interface_pid({?MODULE, Id})  of
	Pid when is_pid(Pid) -> gen_server:call(Pid, Request);
	Error -> Error
    end.
