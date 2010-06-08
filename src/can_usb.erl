%%%-------------------------------------------------------------------
%%% File    : can_usb.erl
%%% Author  : Tony Rogvall <tony@rogvall.se>
%%% Description : CAN USB (VC) interface 
%%%
%%% Created : 17 Sep 2009 by Tony Rogvall <tony@rogvall.se>
%%%-------------------------------------------------------------------
-module(can_usb).

-behaviour(gen_server).

-include("../include/can.hrl").

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

%% API
-export([start/0, start/1]).

-compile(export_all).

-record(s, 
	{
	  id,          %% can node id, for sending
	  sl,          %% serial line port id
	  device_name, %% device name
	  baud_rate,   %% baud rate to canusb
	  can_speed,   %% CAN bus speed
	  acc = [],    %% accumulator for command replies
	  buf = <<>>,  %% parse buffer
	  stat         %% counter dictionary
	 }).

-define(SERVER, ?MODULE).

-define(COMMAND_TIMEOUT, 500).

-define(BITADD(Code, Bit, Name),
	if (Code) band (Bit) =:= 0 -> [];
	   true  -> [(Name)]
	end).

-ifdef(debug).
-define(dbg(Fmt,As), io:format((Fmt), (As))).
-else.
-define(dbg(Fmt,As), ok).
-endif.

%%
%% Some known devices (by me)
%% /dev/tty.usbserial-LWQ8CA1K   (R550)
%%
start() ->
    start(1).

start(BusId) ->
    can_router:start(),
    gen_server:start(?MODULE, [BusId], []).

set_bitrate(Pid, BitRate) ->
    gen_server:call(Pid, {set_bitrate, BitRate}).

get_bitrate(Pid) ->
    gen_server:call(Pid, get_bitrate).

get_status(Pid) ->  %% read error status flags (and clear)
    case gen_server:call(Pid, {command, "F"}) of
	{ok, Status} ->
	    try erlang:list_to_integer(Status, 16) of
		Code ->
		    {ok,
		     ?BITADD(Code,?CAN_ERROR_RECV_FIFO_FULL,recv_fifo_full) ++
		     ?BITADD(Code,?CAN_ERROR_SEND_FIFO_FULL,send_fifo_full) ++
		     ?BITADD(Code,?CAN_ERROR_WARNING,warning) ++
		     ?BITADD(Code,?CAN_ERROR_DATA_OVER_RUN,overrun) ++
		     ?BITADD(Code,?CAN_ERROR_PASSIVE,passive) ++
		     ?BITADD(Code,?CAN_ERROR_ARBITRATION_LOST,arbitration_lost) ++
		     ?BITADD(Code,?CAN_ERROR_BUS,bus_error)}
	    catch
		error:_ -> {error, bad_status}
	    end;
	Error ->
	    Error
    end.


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
init([Id]) ->
    DeviceName = case os:getenv("CANUSB_DEVICE_" ++ integer_to_list(Id)) of
		     false -> "/dev/tty.usbserial";
		     Device -> Device
		 end,
    Speed = case os:getenv("CANUSB_SPEED") of
		false -> 115200;
		Spd -> list_to_integer(Spd)
	    end,
    Opts = [binary,{baud,Speed},{buftm,1},{bufsz,128},
	    {stopb,1},{parity,0},{mode,raw}],
    case sl:open(DeviceName,Opts) of
	{ok,SL} ->
	    ?dbg("CANUSB open: ~s@~w\n", [DeviceName,Speed]),
	    case can_router:join({usb,DeviceName,Id}) of
		{ok,ID} ->
		    ?dbg("CANUSB joined: intf=~w\n", [ID]),
		    S = #s { id=ID, sl=SL, 
			     device_name=DeviceName,
			     stat = dict:new(),
			     baud_rate = Speed,
			     can_speed = 250000 },
		    case canusb_sync(S) of
			true ->
			    canusb_set_bitrate(S, 250000),
			    command_open(S),
			    {ok, S};
			Error ->
			    {stop, Error}
		    end;
		false ->
		    {stop, sync_error}
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
handle_call({set_bitrate,Rate}, _From, S) ->
    case canusb_set_bitrate(S, Rate) of
	{ok, S1} ->
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
handle_info({SL,{data,Data}}, S) when S#s.sl == SL ->
    NewBuf = <<(S#s.buf)/binary, Data/binary>>,
    ?dbg("can_usb:handle_info: NewBuf=~p\n", [NewBuf]),
    {_,S1} = parse_all(S#s { buf = NewBuf}),
    ?dbg("can_usb:handle_info: RemainBuf=~p\n", [S1#s.buf]),
    {noreply, S1};
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
		 Mesg#can_frame.ext,
		 Mesg#can_frame.rtr,
		 Bin,
		 S);
send_bin_message(_Mesg, _Bin, S) ->
    oerr(?CAN_ERROR_DATA_TOO_LARGE,S).

send_message(ID, L, _Ext=false, _Rtr=false, Data, S) ->
    send_frame(S, [$t,to_hex(ID,3), L+$0, to_hex_min(Data,L)]);
send_message(ID, L, _Ext=true, _Rtr=false, Data, S) ->
    send_frame(S, [$T,to_hex(ID,8), L+$0, to_hex_min(Data,L)]);
send_message(ID, L, _Ext=false, _Rtr=true, Data, S) ->
    send_frame(S, [$r,to_hex(ID,3), L+$0, to_hex_max(Data,8)]);
send_message(ID, L, _Ext=true, _Rtr=true, Data, S) ->
    send_frame(S, [$R,to_hex(ID,8), L+$0, to_hex_max(Data,8)]);
send_message(_ID, _L, _Ext, _Rtr, _Data, S) ->
    oerr(?CAN_ERROR_DATA,S).

send_frame(S, Frame) ->
    case command(S, Frame) of
	{ok,_Reply,S1} ->
	    {ok, S1};
	{{error,Reason},S1} ->
	    oerr(Reason,S1)
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
%%    {ok,S'}
%%  | {{error,Reason}, S'}
%%
command(S, Command) ->
    command(S, Command, ?COMMAND_TIMEOUT).

command(S, Command, Timeout) ->
    ?dbg("CANUSB:command: ~p\n", [Command]),
    sl:send(S#s.sl, [Command, $\r]),
    wait_reply(S,Timeout).

wait_reply(S,Timeout) ->
    receive
	{SL, {data,Data}} when SL==S#s.sl ->
	    Data1 = <<(S#s.buf)/binary,Data/binary>>,
	    case parse(Data1, [], S#s{ buf=Data1 }) of
		{more,S1} ->
		    wait_reply(S1,Timeout);
		{ok,Reply,S1} ->
		    ?dbg("CANUSB:wait_reply: ok\n", []),
		    {_, S2} = parse_all(S1),
		    {ok,Reply,S2};
		{Error,S1} ->
		    ?dbg("CAN_USB:wait_reply: ~p\n", [Error]),
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

oerr(Reason,S) ->
    ?dbg("CANUSB:output error: ~p\n", [Reason]),
    S1 = count(output_error, S),
    {{error,Reason},count({output_error,Reason}, S1)}.

ierr(Reason,S) ->
    ?dbg("CANUSB:input error: ~p\n", [Reason]),
    S1 = count(input_error, S),
    count({input_error,Reason}, S1).

in(S) ->
    ?dbg("CANUSB:input frame\n", []),
    count(input_frames, S).

out(S) ->
    ?dbg("CANUSB:output frame\n", []),
    count(output_frames, S).

%% Parse until more data is needed
parse_all(S) ->
    case parse(S#s.buf, [], S) of
	{more,S1} ->
	    {more, S1};
	{ok,_,S1} -> 
	    %% replies to command should? not be interleaved, check?
	    parse_all(S1);
	{_Error,S1} ->
	    ?dbg("CAN_USB:parse_all: ~p, ~p\n", [_Error,S#s.buf]),
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
		    parse(Ds,[],ierr(?CAN_ERROR_CORRUPT,S))
	    end;
       true ->
	    parse(Ds,[],ierr(?CAN_ERROR_LENGTH_OUT_OF_RANGE,S))
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
		    parse(Ds,[],ierr(?CAN_ERROR_CORRUPT,S))
	    end;
       true ->
	    parse(Ds,[],ierr(?CAN_ERROR_LENGTH_OUT_OF_RANGE,S))
    end;
parse_29(_Buf,_Rtr,S) ->
    {more, S}.
    

parse_message(ID,Len,Ext,Rtr,Ds,S) ->
    case parse_data(Len,Rtr,Ds,[]) of
	{ok,Data,Ts,More} ->
	    try can:create(ID,Len,Ext,Rtr,S#s.id,Data,Ts) of
		M ->
		    can_router:cast(M),
		    parse(More,[],in(S#s{buf=More}))
	    catch
		error:Reason  when is_atom(Reason) ->
		    parse_error(Reason, S);
		error:_Reason ->
		    parse_error(?CAN_ERROR_CORRUPT,S)
	    end;
	more ->
	    {more, S};
	{{error,Reason},_Buf} ->
	    parse_error(Reason, S)
    end.

parse_data(L,Rtr,<<Z3,Z2,Z1,Z0,$\r,Buf/binary>>, Acc) when L=:=0; Rtr=:=true->
    case catch erlang:list_to_integer([Z3,Z2,Z1,Z0],16) of
	{'EXIT',_} -> %% ignore ?
	    {ok, list_to_binary(lists:reverse(Acc)), error, Buf};
	Stamp ->
	    {ok, list_to_binary(lists:reverse(Acc)), Stamp, Buf}
    end;
parse_data(L,Rtr,<<$\r,Buf/binary>>, Acc) when L=:=0; Rtr=:=true ->
    {ok,list_to_binary(lists:reverse(Acc)), undefined, Buf};
parse_data(L,Rtr,<<$\n,Buf/binary>>, Acc)  when L=:=0; Rtr=:=true ->
    {ok,list_to_binary(lists:reverse(Acc)), undefined, Buf};
parse_data(L,Rtr,<<H1,H0,Buf/binary>>, Acc) when L > 0 ->
    try erlang:list_to_integer([H1,H0],16) of
	H ->
	    parse_data(L-1,Rtr,Buf,[H|Acc])
    catch 
	error:_ ->
	    {{error,?CAN_ERROR_CORRUPT}, Buf}
    end;
parse_data(L,Rtr,_Buf,_Acc) when L > 0, Rtr =:= false ->
    more;
parse_data(_L,_Rtr,Buf,_Acc) ->
    {{error,?CAN_ERROR_CORRUPT}, Buf}.



    


    

    
