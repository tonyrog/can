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

-include_lib("lager/include/log.hrl").
-include("../include/can.hrl").

%% API
-export([start/0, start/1, start/2]).
-export([start_link/0, start_link/1, start_link/2]).
-export([stop/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(s,
	{
	  id,          %% router id
	  device,      %% device name
	  port,        %% port-id (registered as can_sock_prt)
	  intf,        %% out-bound interface
	  stat,        %% counter dictionary
	  fs           %% can_router:fs_new()
	}).	

-type can_sock_option() ::
	{device,  DeviceName::string()}.
%% currentl set with ip link command...
%%	{bitrate, CANBitrate::integer()} |

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
    gen_server:start_link(?MODULE, [BusId,Opts], []).

-spec stop(BusId::integer()) -> ok | {error,Reason::term()}.

stop(BusId) ->
    case supervisor:terminate_child(can_sup, {?MODULE, BusId}) of
	ok ->
	    supervisor:delete_child(can_sup, {?MODULE, BusId});
	Error ->
	    Error
    end.

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

init([BusId,Opts]) ->
    Device = proplists:get_value(device, Opts, "can0"),
    case can_sock_drv:open() of
	{ok,Port} ->
	    case get_index(Port, Device) of
		{ok,Index} ->
		    case can_sock_drv:bind(Port,Index) of
			ok ->
			    case can_router:join({?MODULE,Device,BusId}) of
				{ok,ID} ->
				    {ok,#s { id = ID,
					     device = Device,
					     port = Port,
					     intf = Index,
					     stat = dict:new(),
					     fs=can_router:fs_new()
					   }};
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
handle_call({add_filter,F}, _From, S) ->
    {I,Fs} = can_router:fs_add(F,S#s.fs),
    {reply, {ok,I}, S#s { fs=Fs }};
handle_call({del_filter,I}, _From, S) ->
    {Reply,Fs} = can_router:fs_del(I,S#s.fs),
    {reply, Reply, S#s { fs=Fs }};
handle_call({get_filter,I}, _From, S) ->
    Reply = can_router:fs_get(I,S#s.fs),
    {reply, Reply, S};  
handle_call(list_filter, _From, S) ->
    Reply = can_router:fs_list(S#s.fs),
    {reply, Reply, S};
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
    ?debug("can_sock: handle_cast: ~p\n", [_Mesg]),
    {noreply, S}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({Port,{data,Frame}}, S) when
      is_record(Frame,can_frame), Port =:= S#s.port ->
    %% FIXME: add sub-interface ...
    S1 = input(Frame#can_frame{intf=S#s.id}, S),
    {noreply, S1};
handle_info(_Info, S) ->
    ?debug("can_sock: got message=~p\n", [_Info]),
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

get_index(_Port, "any") -> {ok, 0};
get_index(Port,IfName) -> can_sock_drv:ifindex(Port,IfName).


send_message(Mesg, S) when is_record(Mesg,can_frame) ->
    if S#s.intf == 0 ->
	    {ok,S};
       true ->
	    case can_sock_drv:send(S#s.port,S#s.intf,Mesg) of
		ok ->
		    S1 = count(output_frames, S),
		    {ok,S1};
		{error,_Reason} ->
		    output_error(?can_error_data,S)
	    end
    end;
send_message(_Mesg, S) ->
    output_error(?can_error_data,S).
    
count(Item,S) ->
    Stat = dict:update_counter(Item, 1, S#s.stat),
    S#s { stat = Stat }.

output_error(Reason,S) ->
    {{error,Reason}, oerr(Reason,S)}.

oerr(Reason,S) ->
    S1 = count(output_error, S),
    count({output_error,Reason}, S1).

%% ierr(Reason,S) ->
%%    S1 = count(input_error, S),
%%    count({input_error,Reason}, S1).

%% Push this into the driver!!!
input(Frame, S) ->
    case can_router:fs_input(Frame, S#s.fs) of
	true ->
	    can_router:input(Frame),
	    count(input_frames, S);
	false ->
	    S1 = count(input_frames, S),
	    count(filter_frames, S1)
    end.
