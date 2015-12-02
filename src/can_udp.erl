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

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-export([reuse_port/0]).

%% Test API
-export([pause/1, resume/1]).
-export([dump/1]).

-record(s, 
	{
	  receiver={can_router, undefined, undefined} ::
	    {Module::atom(), %% Module to join and send to
	     Pid::pid(),     %% Pid if not default server
	     Id::integer()}, %% Interface id
	  in,          %% incoming udp socket
	  out,         %% outgoing udp socket
	  maddr,       %% multicast address
	  ifaddr,      %% interface address (any, {192,168,1,4} ...)
	  mport,       %% port number used
	  oport,       %% output port number used
	  pause = false,   %% Pause input
	  fs           %% can_filter:new()
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

-type can_udp_option() ::
	{maddr,    inet:ip_address()} |
	{ifaddr,   inet:ip_address()} |
	{ttl,     integer()} |
	{timeout, ReopenTimeout::integer()} |
	{bitrate, CANBitrate::integer()} |
	{status_interval, Time::timeout()} |
	{pause, Pause::boolean()}.

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
    lager:debug("can_udp: start_link ~p ~p\n", [BusId,Opts]),
    Res = gen_server:start_link(?MODULE, [BusId, Opts], []),
    lager:debug("can_udp: res ~p\n", [Res]),
    Res.
    

-spec stop(BusId::integer()) -> ok | {error,Reason::term()}.

stop(BusId) ->
    case supervisor:terminate_child(can_if_sup, {?MODULE, BusId}) of
	ok ->
	    supervisor:delete_child(can_if_sup, {?MODULE, BusId});
	Error ->
	    Error
    end.

-spec pause(Id::integer()| pid()) -> ok | {error, Error::atom()}.
pause(Id) when is_integer(Id); is_pid(Id) ->
    gen_server:call(server(Id), pause).
-spec resume(Id::integer()| pid()) -> ok | {error, Error::atom()}.
resume(Id) when is_integer(Id); is_pid(Id) ->
    gen_server:call(server(Id), resume).

-spec dump(Id::integer()| pid()) -> ok | {error, Error::atom()}.
dump(Id) when is_integer(Id); is_pid(Id) ->
    gen_server:call(server(Id),dump).

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
    LAddr = if is_tuple(LAddr0) -> 
		    LAddr0;
	       is_list(LAddr0) ->
		     case lookup_ip(LAddr0, inet) of
			 {error,_} ->
			     lager:warning("No such interface ~p",[LAddr0]),
			     {0,0,0,0};
			 {ok,IP} -> IP
		     end;
		LAddr0 =:= any -> 
		    {0,0,0,0};
		true ->
		     lager:warning("No such interface ~p",[LAddr0]),
		    {0,0,0,0}
	    end,
    RAddr = ?CAN_MULTICAST_IF,

    SendOpts = [{active,false},{multicast_if,LAddr},
		{multicast_ttl,Mttl},{multicast_loop,true}],

    RecvOpts = [{reuseaddr,true},{mode,binary},{active,false},
		{ifaddr,RAddr}] ++reuse_port(),

    MultiOpts = [{add_membership,{MAddr,LAddr}},{active,true}],
    case gen_udp:open(0, SendOpts) of
	{ok,Out} ->
	    {ok,OutPort} = inet:port(Out),
	    case catch gen_udp:open(MPort,RecvOpts++MultiOpts) of
		{ok,In} ->
		    case join(Router, Pid, {?MODULE,MAddr,BusId}) of
			{ok, If} when is_integer(If) ->
			    {ok, #s{ receiver={Router,Pid,If},
				     in=In, mport=MPort,
				     out=Out, oport=OutPort,
				     maddr=MAddr,
				     pause = Pause,
				     fs=can_filter:new()
				   }};
			{error, Reason} = Error ->
			    lager:error("Failed to join ~p(~p), reason ~p", 
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
    lager:debug("pause when not active.", []),
    {reply, ok, S#s {pause = true}};
handle_call(resume, _From, S=#s {pause = true}) ->
    lager:debug("resume.", []),
    {reply, {error, not_implemented_yet}, S=#s {pause = false}};
handle_call(resume, _From, S=#s {pause = false}) ->
    lager:debug("resume when not paused.", []),
    {reply, ok, S};
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
    lager:debug("can_udp: handle_cast: ~p\n", [_Mesg]),
    {noreply, S}.


%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({udp,U,_Addr,Port,Data}, S) when S#s.in == U ->
    if Port =:= S#s.oport ->
	    lager:debug("can_udp: discard ~p ~p ~p\n", [_Addr,Port,Data]),
	    {noreply, S};
       true->
	    %% FIXME: add check that _Addr is a local address
	    case Data of
 		<<CId:32/little,FLen:32/little,CData:8/binary>> ->
		    lager:debug("CUd=~8.16.0B, FLen=~8.16.0B, CData=~p\n",
			 [CId,FLen,CData]),
		    Ts = ?CAN_NO_TIMESTAMP,
		    Len = FLen band 16#f,
		    {noreply, input(CId,Len,CData,Ts,S)};
		_ ->
		    lager:debug("can_udp: Got ~p\n", [Data]),
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
    lager:debug([{tag, frame}],"can_udp:send_message: [~s]", 
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

send_message(ID, Len, Data, S) ->
    Bin = 
	case byte_size(Data) of 
	    0 -> <<0,0,0,0,0,0,0,0>>;
	    8 -> Data;
	    Bsz ->
		(<< Data/binary, 0:(8-(Bsz rem 8))/unit:8 >>)
	end,
    %% Mask ID on output message, remove error bits and bad id bits
    ID1 = if ?is_can_id_eff(ID) ->
		  ID band (?CAN_EFF_FLAG bor ?CAN_RTR_FLAG bor ?CAN_EFF_MASK);
	     true ->
		  ID band (?CAN_RTR_FLAG bor ?CAN_SFF_MASK)
	  end,
    Len1 = Len band 16#f,
    case gen_udp:send(S#s.out, S#s.maddr, S#s.mport,
		      <<ID1:32/little, Len1:32/little, Bin/binary>>) of
	ok ->
	    {ok,count(output_frames, S)};
	_Error ->
	    lager:debug("gen_udp: failure=~p\n", [_Error]),
	    output_error(?can_error_transmission,S)
    end.

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

join(Module, Pid, Arg) when is_atom(Module), is_pid(Pid) ->
    Module:join(Pid, Arg);
join(undefined, Pid, _Arg) when is_pid(Pid) ->
    %% No join
    ?DEFAULT_IF;
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
	    lager:debug("can_udp: Got ~p\n", [_Other]),
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

server(Pid) when is_pid(Pid)->
    Pid;
server(BusId) when is_integer(BusId) ->
    can_router:interface_pid(BusId).
