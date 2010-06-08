%%%-------------------------------------------------------------------
%%% File    : can_udp.erl
%%% Author  : Tony Rogvall <tony@rogvall.se>
%%% Description : CAN/UDP adaptor module
%%%
%%% Created : 30 Jan 2009 by Tony Rogvall <tony@rogvall.se>
%%%-------------------------------------------------------------------
-module(can_udp).

-behaviour(gen_server).

%% API
-export([start/0, start/1, start/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-export([reuse_port/0]).

-record(s, 
	{
	  in,          %% incoming udp socket
	  out,         %% out going udp socket
	  id,          %% router id
	  maddr,       %% multicase address
	  ifaddr,      %% interface address (any, {192,168,1,4} ...)
	  mport,       %% port number used
	  oport,       %% output port number used
	  stat         %% counter dictionary
	 }).

-include("../include/can.hrl").

-ifdef(debug).
-define(dbg(Fmt,As), io:format((Fmt), (As))).
-else.
-define(dbg(Fmt,As), ok).
-endif.

%% MAC specific reuseport options
-define(SO_REUSEPORT, 16#0200).

-define(IPPROTO_IP,   0).
-define(IPPROTO_TCP,  6).
-define(IPPROTO_UDP,  17).
-define(SOL_SOCKET,   16#ffff).

-define(CAN_MULTICAST_ADDR, {224,0,0,1}).
-define(CAN_MULTICAST_IF,   {0,0,0,0}).
-define(CAN_UDP_PORT, 51712).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start() ->
    start(0, ?CAN_MULTICAST_ADDR).
start(BusId) ->
    start(BusId, ?CAN_MULTICAST_ADDR).
    
start(BusId,Ip) ->
    can_router:start(),
    gen_server:start(?MODULE, [BusId, Ip], []).

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
init([Id, MAddr]) ->
    LAddr = ?CAN_MULTICAST_IF,
    MPort = ?CAN_UDP_PORT+Id,
    
    SendOpts = [{active,false},{multicast_if,LAddr},
		{multicast_ttl,1},{multicast_loop,true}],

    RecvOpts = [{reuseaddr,true},{mode,binary},{active,false},
		{ifaddr,LAddr}] ++reuse_port(),

    MultiOpts = [{add_membership,{MAddr,LAddr}},{active,true}],
    case gen_udp:open(0, SendOpts) of
	{ok,Out} ->
	    {ok,OutPort} = inet:port(Out),
	    case catch gen_udp:open(MPort,RecvOpts++MultiOpts) of
		{ok,In} ->
		    case can_router:join({udp,MAddr,MPort}) of
			{ok,ID} ->
			    {ok,#s{ in=In, mport=MPort,
				    stat = dict:new(),
				    out=Out, oport=OutPort,
				    maddr=MAddr, id=ID  }};
			Error ->
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
    Stat = dict:to_list(S#s.stat),
    {reply,{ok,Stat}, S};
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
handle_cast(_Mesg, S) ->
    {noreply, S}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({udp,U,_Addr,Port,Data}, S) when S#s.in == U ->
    if Port =:= S#s.oport ->
	    ?dbg("can_udp: discard ~p ~p ~p\n", [_Addr,Port,Data]),
	    {noreply, S};
       true->
	    %% FIXME: add check that _Addr is a local address
	    case Data of
		<<CId:32/little,FLen:32/little,CData:8/binary>> ->
		    ?dbg("CUd=~8.16.0B, FLen=~8.16.0B, CData=~p\n",
			 [CId,FLen,CData]),
		    case catch can:create(CId,FLen band 16#f,
					  ((FLen bsr 31) band 1) == 1,
					  ((FLen bsr 30) band 1) == 1,
					  S#s.id,
					  CData) of
			{'EXIT', {Reason,_}} when is_atom(Reason) ->
			    {noreply, ierr(Reason,S)};
			{'EXIT', Reason} when is_atom(Reason) ->
			    {noreply, ierr(Reason,S)};
			{'EXIT', _Reason} ->
			    {noreply, ierr(?CAN_ERROR_CORRUPT,S)};
			M when is_record(M,can_frame) ->
			    can_router:cast(M),
			    {noreply, in(S)};
			_Other ->
			    ?dbg("CAN_UDP: Got ~p\n", [_Other]),
			    {noreply, S}
		    end;
		_ ->
		    ?dbg("CAN_UDP: Got ~p\n", [Data]),
		    {noreply, ierr(?CAN_ERROR_CORRUPT,S)}
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
    [{raw,?SOL_SOCKET,?SO_REUSEPORT,<<1:32/native>>}].

send_message(Mesg, S) when is_record(Mesg,can_frame) ->
    if is_binary(Mesg#can_frame.data) ->
	    send_bin_message(Mesg, Mesg#can_frame.data, S);
       true ->
	    oerr(?CAN_ERROR_DATA,S)
    end;
send_message(_Mesg, S) ->
    oerr(?CAN_ERROR_DATA,S).


send_bin_message(Mesg, Bin, S) when byte_size(Bin) =< 8 ->
    send_message(Mesg#can_frame.id,
		 Mesg#can_frame.len,
		 (if Mesg#can_frame.ext -> ?EXT_BIT; true -> 0 end),
		 (if Mesg#can_frame.rtr -> ?RTR_BIT; true -> 0 end),
		 Bin,
		 S);
send_bin_message(_Mesg, _Bin, S) ->
    oerr(?CAN_ERROR_DATA_TOO_LARGE,S).

send_message(ID, Len, Ext, Rtr, Data, S) ->
    FS = Len bor Ext bor Rtr,
    Bin = 
	case byte_size(Data) of 
	    0 -> <<0,0,0,0,0,0,0,0>>;
	    8 -> Data;
	    Bsz ->
		(<< Data/binary, 0:(8-(Bsz rem 8))/unit:8 >>)
	end,
    case gen_udp:send(S#s.out, S#s.maddr, S#s.mport, 
		      <<ID:32/little, FS:32/little, Bin/binary>>) of
	ok ->
	    {ok,out(S)};
	_Error ->
	    ?dbg("gen_udp: failure=~p\n", [_Error]),
	    oerr(?CAN_ERROR_TRANSMISSION,S)
    end.

count(Item,S) ->
    Stat = dict:update_counter(Item, 1, S#s.stat),
    S#s { stat = Stat }.

oerr(Reason,S) ->
    S1 = count(output_error, S),
    {{error,Reason},count({output_error,Reason}, S1)}.

ierr(Reason,S) ->
    S1 = count(input_error, S),
    count({input_error,Reason}, S1).

in(S) ->
    count(input_frames, S).

out(S) ->
    count(output_frames, S).


%% Find interface address and broadcast address from Addr
find_ifaddr(any)      -> {{0,0,0,0},{255,255,255,255}};
find_ifaddr(loopback) -> {{127,0,0,1},{127,255,255,255}};
find_ifaddr(Addr) ->
    {ok,List} = inet:getif(),
    find_ifaddr(Addr,List).

find_ifaddr(Addr, [{A,B,M}|T]) ->
    case match_ifaddr(Addr, M) of
	true -> {A,B};
	false -> find_ifaddr(Addr,T)
    end;
find_ifaddr(_Addr, []) ->
    false.

match_ifaddr({A1,B1,C1,D1},{A2,B2,C2,D2}) ->
    (A1 band A2 == A1) andalso
    (B1 band B2 == B1) andalso
    (C1 band C2 == C1) andalso
    (D1 band D2 == D1).


    
    
