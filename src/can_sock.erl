%%%-------------------------------------------------------------------
%%% File    : can_sock.erl
%%% Author  : Tony Rogvall <tony@rogvall.se>
%%% Description : SocketCAN manager
%%%
%%% Created :  8 Jun 2010 by Tony Rogvall <tony@rogvall.se>
%%%-------------------------------------------------------------------
-module(can_sock).

-behaviour(gen_server).

%% API
-export([start/0, start/1, start/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(s,
	{
	  id,          %% router id
	  port,        %% port-id (registered as can_sock_prt)
	  intf,        %% out-bound interface
	  stat         %% counter dictionary
	 }).	

-include("../include/can.hrl").

-ifdef(debug).
-define(dbg(Fmt,As), io:format((Fmt), (As))).
-else.
-define(dbg(Fmt,As), ok).
-endif.

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start() ->
    start("can0").

start(IfName) ->
    start(IfName,[]).

start(IfName, Opts) ->
    can_router:start(),
    gen_server:start(?MODULE, [IfName,Opts], []).
    
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

init([IfName,Opts]) ->
    case eapi_drv:open([{driver_name, "can_sock_drv"},
			{prt_name, can_sock_prt},
			{app, can} | Opts]) of
	{ok,Port} ->
	    case get_index(IfName) of
		{ok,Index} ->
		    case can_sock_drv:bind(Index) of
			ok ->
			    case can_router:join({can_sock,Index}) of
				{ok,ID} ->
				    {ok,#s { port = Port,
					     intf = Index,
					     id = ID,
					     stat = dict:new() }};
				Error ->
				    {stop, Error}
			    end;
			Error ->
			    {stop, Error}
		    end;
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
handle_call({send,Mesg}, _From, S) when is_record(Mesg,can_frame) ->
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
handle_cast({send,Mesg}, S) when is_record(Mesg,can_frame) ->
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
handle_info({Port,{data,M}}, S) when
      is_record(M,can_frame), Port =:= S#s.port ->
    %% FIXME: add sub-interface ...
    can_router:cast(M#can_frame{intf=S#s.id}),
    {noreply, in(S)};
handle_info(_Info, S) ->
    io:format("can_sock: got message=~p\n", [_Info]),
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

get_index("any") -> {ok, 0};
get_index(IfName) -> can_sock_drv:ifindex(IfName).


send_message(Mesg, S) when is_record(Mesg,can_frame) ->
    if S#s.intf == 0 ->
	    {ok,S};
       true ->
	    Res = can_sock_drv:send(S#s.intf,Mesg),
	    io:format("res=~p\n", [Res]),
	    {ok,out(S)}
    end;
send_message(_Mesg, S) ->
    oerr(?CAN_ERROR_DATA,S).
    

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
