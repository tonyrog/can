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

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(s,
	{
	  receiver={can_router, undefined, undefined} ::
	    {Module::atom(), %% Module to join and send to
	     Pid::pid(),     %% Pid if not default server
	     Id::integer()}, %% Interface id
	  device,      %% device name
	  port,        %% port-id (registered as can_sock_prt)
	  intf,        %% out-bound interface
	  fs           %% can_filter:new()
	}).	

-type can_sock_option() ::
	{device,  DeviceName::string()}.

-define(DEFAULT_IF,0).


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
    Router = proplists:get_value(router, Opts, can_router),
    Pid = proplists:get_value(receiver, Opts, undefined),
    Device = proplists:get_value(device, Opts, "can0"),
    case can_sock_drv:open() of
	{ok,Port} ->
	    case get_index(Port, Device) of
		{ok,Index} ->
		    case can_sock_drv:bind(Port,Index) of
			ok ->
			    case join(Router, Pid, 
				      {?MODULE,Device,BusId}) of
				{ok, If} when is_integer(If) ->
				    {ok, #s{ receiver={Router,Pid,If},
					     device = Device,
					     port = Port,
					     intf = Index,
					     fs=can_filter:new()
					   }};
				{error, Reason} = Error ->
				    lager:error("Failed to join ~p(~p), "
						"reason ~p", [Router, 
							      Pid, 
							      Reason]),
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
    {reply,{ok,can_counter:list()}, S};
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
    lager:debug("can_sock: handle_cast: ~p\n", [_Mesg]),
    {noreply, S}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({Port,{data,Frame}}, S=#s {receiver = {_Router, _Pid, If}}) 
  when is_record(Frame,can_frame), Port =:= S#s.port ->
    %% FIXME: add sub-interface ...
    S1 = input(Frame#can_frame{intf=If}, S),
    {noreply, S1};
handle_info(_Info, S) ->
    lager:debug("can_sock: got message=~p\n", [_Info]),
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
    %% io:format("apply_filters: fs=~p\n", [Fs]),
    _Res =
	if Fs =:= [] ->
		All = #can_filter { id = 0, mask = 0 },
		can_sock_drv:set_filters(S#s.port, [All]);
	   true ->
		can_sock_drv:set_filters(S#s.port, Fs)
	end,
    %% io:format("Res = ~p\n", [_Res]),
    ok.

join(Module, Pid, Arg) when is_atom(Module), is_pid(Pid) ->
    Module:join(Pid, Arg);
join(undefined, Pid, _Arg) when is_pid(Pid) ->
    %% No join
    ?DEFAULT_IF;
join(Module, undefined, Arg) when is_atom(Module) ->
    Module:join(Arg).
    
%% The filters are pushed onto the driver, here we
%% should check that this is also the case.
input(Frame, S=#s {receiver = Receiver}) ->
    %% read number of filtered frames ?
    input_frame(Frame, Receiver),
    count(input_frames, S).

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

