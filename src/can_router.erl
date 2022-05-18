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
%%%   CAN router
%%%
%%% Created: 7 Jan 2008 by Tony Rogvall
%%% @end
%%%-------------------------------------------------------------------
-module(can_router).

-behaviour(gen_server).

%% API
-export([start/0, start/1, stop/0]).
-export([start_link/0, start_link/1]).
-export([join/1, join/2]).
-export([attach/0, attach/1, detach/0]).
-export([error_reception/1]).
-export([send/1, send_from/2]).
-export([sync_send/1, sync_send_from/2]).
-export([input/1, input/2, input_from/2]).
-export([add_filter/4, del_filter/2, get_filter/2, list_filter/1]).
-export([stop/1, restart/1]).
-export([i/0, i/1]).
-export([statistics/0]).
-export([pause/1, resume/1, ifstatus/1, ifstatus/0]).
-export([debug/2, interfaces/0, interface/1, interface_pid/1]).
-export([config_change/3]).
-export([if_state_supervision/1]).
-export([if_state_event/2, if_state_event/3]).
-export([getopts/2, setopts/2]).
%% gen_server callbacks
-export([init/1, 
	 handle_call/3, 
	 handle_cast/2, 
	 handle_info/2,
	 terminate/2, 
	 code_change/3]).

-import(lists, [foreach/2, map/2, foldl/3]).

-include("../include/can.hrl").

-define(SERVER, can_router).

-type ifparam()::#{ mod => atom(),
		    device => string(),
		    index  => integer(),
		    name   => string(),
		    fd     => boolean()
		  }.

-record(can_if,
	{
	 pid   :: pid(),        %% can interface pid
	 mod   :: atom(),       %% current
	 id    :: integer(),    %% interface id
	 name  :: string(),     %% name for easier identification
	 mon   :: reference(),  %% can app monitor
	 param :: ifparam(),    %% all params
	 atime,                 %% last input activity time
	 state = undefined
	}).

-record(can_app,
	{
	 pid,       %% can app pid
	 mon,       %% can app monitor
	 interface, %% interface id
	 fs,        %% can filter
	 error_reception :: on | off  %% allow error frames
	}).

-record(s,
	{
	 if_count = 1,  %% interface id counter
	 apps = [],     %% attached can applications
	 wakeup_timeout :: timeout(),
	 wakeup = false :: boolean(),
	 supervisors = [] ::list({pid(), reference()})
	}).

-define(CLOCK_TIME, 16#ffffffff).
-define(DEFAULT_WAKEUP_TIMEOUT, 15000).
-define(MSG_WAKEUP,            16#2802).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link() ->  start_link([]).

start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Args, []).

statistics() ->
    IFs = gen_server:call(?SERVER, interfaces),
    foldl(
      fun(If,Acc) ->
	      case gen_server:call(If#can_if.pid, statistics) of
		  {ok,Stat} ->
		      [{If#can_if.id,Stat} | Acc];
		  Error ->
		      [{If#can_if.id,Error}| Acc]
	      end
      end, [], IFs).

i() ->
    IFs = gen_server:call(?SERVER, interfaces),
    io:format("Interfaces\n",[]),
    lists:foreach(
      fun(If) ->
	      case gen_server:call(If#can_if.pid, statistics) of
		  {ok,Stat} ->
		      print_stat(If, Stat);
		  Error ->
		      io:format("~2w: ~p\n  error = ~p\n",
				[If#can_if.id,If#can_if.param,Error])
	      end
      end, lists:keysort(#can_if.id, IFs)),
    Apps = gen_server:call(?SERVER, applications),
    io:format("Applications\n",[]),
    lists:foreach(
      fun(App) ->
	      Name = case process_info(App#can_app.pid, registered_name) of
			 {registered_name, Nm} -> atom_to_list(Nm);
			 _ -> ""
		     end,
	      io:format("~w: ~s interface=~p\n",
			[App#can_app.pid,Name,App#can_app.interface])
      end, Apps).
    

interfaces() ->
    gen_server:call(?SERVER, interfaces).

interface(Id) ->
    case gen_server:call(?SERVER, {interface, Id}) of
	{ok,If} = Reply when is_record(If, can_if) ->
	    Reply;
	[If] when is_record(If, can_if) ->
	    {ok, If};
	[] ->
	    ?debug("~2w: no such interface\n", [Id]),
	    {error,enoent};
	Ifs when is_list(Ifs)->
	    ?warning("~p: several interfaces\n", [Ifs]),
	    {error,not_unique};
	{error,enoent} ->
	    ?debug("~2w: no such interface\n", [Id]),
	    {error,enoent};
	Error ->
	    Error
    end.

interface_pid(Id) ->
    case interface(Id) of
	{ok,IF} -> IF#can_if.pid;
	Error -> Error
    end.

debug(Id, Bool) ->
    call_if(Id, {debug, Bool}).

stop(Id) ->
    call_if(Id, stop).    

pause(Id) ->
    call_if(Id, pause).

resume(Id) ->
    call_if(Id, resume).    

ifstatus(Id) ->
    call_if(Id, ifstatus).    

getopts(Id, Opts) when is_list(Opts) ->
    call_if(Id, {getopts,Opts}).

setopts(Id, Opts) when is_list(Opts) ->
    call_if(Id, {setopts,Opts}).

ifstatus() ->
    %% For all interfaces
    lists:foldl(fun(#can_if{pid = Pid, param = Param}, Acc) ->
			Name = maps:get(name, Param, ""),
			[{{can, Name}, gen_server:call(Pid, ifstatus)} | Acc]
		end, [], interfaces()).

restart(Id) ->
    case gen_server:call(?SERVER, {interface,Id}) of
	{ok,If} ->
	    case If#can_if.param of
		#{mod:=can_usb,index:=N} ->
		    ok = gen_server:call(If#can_if.pid, stop),
		    can_usb:start(N);
		#{mod:=can_udp,index:=N} ->
		    ok = gen_server:call(If#can_if.pid, stop),
		    can_udp:start(N-51712);
		#{mod:=can_sock,device:=IfName} ->
		    ok = gen_server:call(If#can_if.pid, stop),
		    can_sock:start(IfName)
	    end;
	Error ->
	    Error
    end.

i(Id) ->
    case gen_server:call(?SERVER, {interface,Id}) of
	{ok,If} ->
	    case gen_server:call(If#can_if.pid, statistics) of
		{ok,Stat} ->
		    print_stat(If, Stat);
		Error ->
		    Error
	    end;
	Error ->
	    Error
    end.

print_stat(If, Stat) ->
    io:format("~2w: ~p\n", [If#can_if.id, If#can_if.param]),
    io:format("  state: ~p\n", [If#can_if.state]),
    lists:foreach(
      fun({Counter,Value}) ->
	      io:format("  ~p: ~w\n", [Counter, Value])
      end, lists:sort(Stat)).

call_if(Id, Request) ->	
    case gen_server:call(?SERVER, {interface,Id}) of
	{ok,If} when is_record(If, can_if)->
	    gen_server:call(If#can_if.pid, Request);
	[If] when is_record(If, can_if)->
	    gen_server:call(If#can_if.pid, Request);
	[] ->
	    ?debug("~2w: no such interface\n", [Id]),
	    {error,enoent};
	Ifs when is_list(Ifs)->
	    ?warning("~p: several interfaces\n", [Ifs]),
	    {error,not_unique};
	{error,enoent} ->
	    ?warning("~2w: no such interface\n", [Id]),
	    {error,enoent};
	Error ->
	    Error
    end.

%% attach - simulated can bus or application
attach() ->
    attach([]).

attach(FilterList) when is_list(FilterList) ->
    gen_server:call(?SERVER, {attach, self(), FilterList}).

%% detach the same
detach() ->
    gen_server:call(?SERVER, {detach, self()}).

%% allow application to get notified about interface errors,
%% sent as error frames 
error_reception(OnOff) when OnOff =:= on; OnOff =:= off ->
    gen_server:call(?SERVER, {error_reception, self(), OnOff}).

%% add an interface to the simulated can_bus (may be a real canbus)
join({Mod,Device,Index,Name}) ->
    Params = #{mod=>Mod,device=>Device,index=>Index,name=>Name},
    gen_server:call(?SERVER, {join, self(), Params});
join(Params) when is_map(Params) ->
    gen_server:call(?SERVER, {join, self(), Params}).

join(Pid, {Mod,Device,Index,Name}) ->
    Params = #{mod=>Mod,device=>Device,index=>Index,name=>Name},
    gen_server:call(Pid, {join, self(), Params});
join(Pid, Params) when is_pid(Pid) ->
    gen_server:call(Pid, {join, self(), Params}).

add_filter(ID, Invert, CanID, Mask) when 
      is_boolean(Invert), is_integer(CanID), is_integer(Mask) ->
    gen_server:call(?SERVER, {add_filter, ID, Invert, CanID, Mask}).

del_filter(Intf, I) ->
    gen_server:call(?SERVER, {del_filter, Intf, I}).

get_filter(Intf, I) ->
    gen_server:call(?SERVER, {get_filter, Intf, I}).

list_filter(Intf) ->
    gen_server:call(?SERVER, {list_filter, Intf}).

send(Frame) when is_record(Frame, can_frame) ->
    gen_server:cast(?SERVER, {send, self(), Frame}).

send_from(Pid,Frame) when is_pid(Pid), is_record(Frame, can_frame) ->
    gen_server:cast(?SERVER, {send, Pid, Frame}).

sync_send(Frame) when is_record(Frame, can_frame) ->
    gen_server:call(?SERVER, {send, self(), Frame}).

sync_send_from(Pid,Frame) when is_pid(Pid), is_record(Frame, can_frame) ->
    gen_server:call(?SERVER, {send, Pid, Frame}).

%% Input from  backends
input(Frame) when is_record(Frame, can_frame) ->
    gen_server:cast(?SERVER, {input, self(), Frame}).

input(Pid, Frame) when is_record(Frame, can_frame) ->
    gen_server:cast(Pid, {input, self(), Frame}).

input_from(Pid,Frame) when is_pid(Pid), is_record(Frame, can_frame) ->
    gen_server:cast(?SERVER, {input, Pid, Frame}).

config_change(Changed,New,Removed) ->
    gen_server:call(?SERVER, {config_change,Changed,New,Removed}).

%% Supervise
if_state_supervision(Value) 
  when Value =:= on; Value =:= off; Value =:= refresh ->
    gen_server:call(?SERVER, {supervise, Value, self()}).

if_state_event(Id, State) 
  when is_integer(Id), State =:= up; State =:= down; is_map(State) ->
    ?SERVER ! {if_state_event, Id, State}.
if_state_event(Pid, Id, State) 
  when is_integer(Id), State =:= up; State =:= down; is_map(State) ->
    Pid ! {if_state_event, Id, State}.

%%--------------------------------------------------------------------
%% Shortcut API
%%--------------------------------------------------------------------
start() -> start([]).

start(Args) ->
    application:load(can),
    application:set_env(can, arguments, Args),
    application:set_env(can, interfaces, []),
    application:start(can).

stop() ->
    application:stop(can).

%%--------------------------------------------------------------------
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
init(Args0) ->
    Args = Args0 ++ application:get_all_env(can),
    process_flag(trap_exit, true),
    start_clock(),
    Wakeup = proplists:get_value(wakeup, Args, false),
    Wakeup_timeout = proplists:get_value(wakeup_timeout, Args, 
					 ?DEFAULT_WAKEUP_TIMEOUT),
    can_counter:init(stat_in),   %% number of input packets received
    can_counter:init(stat_out),  %% number of output packets  sent
    can_counter:init(stat_err),  %% number of error packets received
    {ok, #s{ wakeup = Wakeup,
	     wakeup_timeout = Wakeup_timeout
	   }}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({send,Pid,Frame},_From, S)
  when is_pid(Pid),is_record(Frame, can_frame) ->
    S1 = do_send(Pid, Frame, true, S),
    {reply, ok, S1}; 

handle_call({attach,Pid,FilterList}, _From, S) when is_pid(Pid) ->
    case find_app_by_pid(Pid,S#s.apps) of
	false ->
	    ?debug("can_router: process ~p attached.",  [Pid]),
	    Mon = erlang:monitor(process, Pid),
	    %% We may extend app interface someday - now = 0
	    case make_filter(FilterList) of
		{ok,Fs,_Is} ->
		    App = #can_app { pid=Pid, mon=Mon, interface=0, fs=Fs },
		    Apps1 = [App | S#s.apps],
		    {reply, ok, S#s { apps = Apps1 }};
		Error ->
		    {reply, Error, S}
	    end;
	_App ->
	    {reply, {error,ealready}, S}
    end;
handle_call({detach,Pid}, _From, S) when is_pid(Pid) ->
    case take_app_by_pid(Pid,S#s.apps) of
	false ->
	    {reply, ok, S};
	{value,App,Apps} ->
	    ?debug("can_router: process ~p detached.",  [Pid]),
	    Mon = App#can_app.mon,
	    erlang:demonitor(Mon),
	    receive {'DOWN',Mon,_,_,_} -> ok
	    after 0 -> ok
	    end,
	    {reply,ok,S#s { apps = Apps }}
    end;
handle_call({error_reception,Pid,OnOff}, _From, S) when is_pid(Pid) ->
    case take_app_by_pid(Pid,S#s.apps) of
	false ->
	    {reply, ok, S};
	{value,App,Apps} ->
	    App1 = App#can_app { error_reception = OnOff },
	    Apps1 = [App1 | Apps],
	    {reply, ok, S#s { apps = Apps1 }}
    end;
handle_call({join,Pid,Param}, _From, S) ->
    case get_interface_by_param(Param) of
	false ->
	    ?debug("can_router: process ~p, param ~p joined.",  [Pid, Param]),
	    {ID,S1} = add_if(Pid,Param,S),
	    {reply, {ok,ID}, S1};
	If ->
	    receive
		{'EXIT', OldPid, _Reason} when If#can_if.pid =:= OldPid ->
		    ?debug("join: restart detected\n", []),
		    {ID,S1} = add_if(Pid,Param,S),
		    {reply, {ok,ID}, S1}
	    after 0 ->
		    {reply, {error,ealready}, S}
	    end
    end;
handle_call({interface,I}, _From, S) when is_integer(I) ->
    case get_interface_by_id(I) of
	false ->
	    {reply, {error,enoent}, S};
	If ->
	    {reply, {ok,If}, S}
    end;
handle_call({interface,Name}, _From, S) when is_list(Name) ->
    {reply, get_interface_by_name(Name), S};
handle_call({interface, {_BackEnd, _BusId} = B}, _From, S) ->
    {reply, get_interface_by_backend(B), S};
handle_call({interface,Param}, _From, S) ->
    case get_interface_by_param(Param) of
	false ->
	    {reply, {error,enoent}, S};
	If ->
	    {reply, {ok,If}, S}
    end;
handle_call(interfaces, _From, S) ->
    {reply, get_interface_list(), S};

handle_call(applications, _From, S) ->
    {reply, S#s.apps, S};

handle_call({add_filter,ID,Invert,CanID,Mask}, From, S) when 
      is_integer(ID), is_boolean(Invert), is_integer(CanID), is_integer(Mask) ->
    case get_interface_by_id(ID) of
	false ->
	    {reply, {error, enoent}, S};
	If ->
	    CanID1 = if Invert ->
			  CanID bor ?CAN_INV_FILTER;
		     true -> 
			  CanID
		  end,
	    F = #can_filter { id=CanID1, mask=Mask },
	    gen_server:cast(If#can_if.pid,{add_filter,From,F}),
	    {noreply, S}
    end;
handle_call({add_filter,Pid,Invert,CanID,Mask}, _From, S) when 
      is_pid(Pid), is_boolean(Invert), is_integer(CanID), is_integer(Mask) ->
    case take_app_by_pid(Pid, S#s.apps) of
	false ->
	    {reply, {error, enoent}, S};
	{value,App,Apps} ->
	    case add_filters_([{Invert,CanID,Mask}], App#can_app.fs, []) of
		{ok,Fs,[I]} ->
		    {reply, {ok,I},
		     S#s { apps= [App#can_app { fs=Fs}|Apps]}};
		Error ->
		    {reply, Error, S}
	    end
    end;

handle_call({del_filter,ID,I}, From, S) when is_integer(ID),
					     is_integer(I) ->
    case get_interface_by_id(ID) of
	false ->
	    {reply, {error, enoent}, S};
	If ->
	    gen_server:cast(If#can_if.pid, {del_filter,From,I}),
	    {noreply, S}
    end;

handle_call({del_filter,Pid,I}, _From, S) when is_pid(Pid), is_integer(I) ->
    case take_app_by_pid(Pid, S#s.apps) of
	false ->
	    {reply, {error, enoent}, S};
	{value,App,Apps} ->
	    case can_filter:del(I,App#can_app.fs) of
		{true,Fs} ->
		    {reply, ok, S#s { apps=[App#can_app { fs=Fs }|Apps]}};
		{false,_Fs} ->
		    {reply, {error, enoent}, S}
	    end
    end;

handle_call({get_filter,ID,I}, From, S) when is_integer(ID), is_integer(I) ->
    case get_interface_by_id(ID) of
	false ->
	    {reply, {error, enoent}, S};
	If ->
	    gen_server:cast(If#can_if.pid, {get_filter,From,I}),
	    {noreply, S}
    end;

handle_call({get_filter,Pid,I}, _From, S) when is_pid(Pid), is_integer(I) ->
    case find_app_by_pid(Pid,S#s.apps) of
	false ->
	    {reply, {error, enoent}, S};
	App ->
	    {reply, can_filter:get(I,App#can_app.fs)}
    end;
handle_call({list_filter,ID}, From, S) when is_integer(ID) ->
    case get_interface_by_id(ID) of
	false ->
	    {reply, {error, enoent}, S};
	If ->
	    gen_server:cast(If#can_if.pid, {list_filter,From}),
	    {noreply,S}
    end;
handle_call({list_filter,Pid}, _From, S) when is_pid(Pid) ->
    case find_app_by_pid(Pid, S#s.apps) of
	false ->
	    {reply, {error, enoent}, S};
	App ->
	    {reply, can_filter:list(App#can_app.fs), S}
    end;

handle_call({supervise, refresh, Pid} = _M, _From, S) ->
    ?debug("message ~p", [_M]),
    current_state(Pid, get_interface_list()),
    {reply, ok, S};

handle_call({supervise, on, Pid} = _M, _From, S=#s {supervisors = Sups}) ->
    ?debug("message ~p", [_M]),
    case lists:keyfind(Pid, 1, Sups) of
	{Pid, _Mon}  ->
	    {reply, ok, S};
	false ->
	    Mon = erlang:monitor(process, Pid),
	    current_state(Pid, get_interface_list()),
	    {reply, ok, S#s {supervisors = [{Pid, Mon} | Sups]}}
    end;

handle_call({supervise, off, Pid} = _M, _From, S=#s {supervisors = Sups}) ->
    ?debug("message ~p", [_M]),
    case lists:keytake(Pid, 1, Sups) of
	false ->
	    {reply, ok, S};
	{value, {Pid, Mon}, NewSups}  ->
	    erlang:demonitor(Mon, [flush]),
	    {reply, ok, S#s {supervisors = NewSups}}
    end;
handle_call({config_change,_Changed,_New,_Removed},_From,S) ->
    io:format("config_change changed=~p, new=~p, removed=~p\n",
	      [_Changed,_New,_Removed]),
    {reply, ok, S};

handle_call(stop, _From, S) ->
    {stop, normal, ok, S};

handle_call(_Request, _From, S) ->
    {reply, {error, bad_call}, S}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast({input,Pid,Frame}, S) 
  when is_pid(Pid),is_record(Frame, can_frame) ->
    if ?is_can_frame_err(Frame) ->
	    S1 = count(stat_err, S),
	    S2 = broadcast_error(Frame, S#s.apps, S1),
	    {noreply, S2};
       true ->
	    S1 = count(stat_in, S),
	    I = Frame#can_frame.intf,
	    case get_interface_by_id(I) of
		false -> ok;
		If -> set_interface(If#can_if { atime = read_clock() })
	    end,
	    S2 = broadcast(Pid, Frame, false, S1),
	    {noreply, S2}
    end;
handle_cast({send,Pid,Frame}, S) 
  when is_pid(Pid),is_record(Frame, can_frame) ->
    S1 = do_send(Pid, Frame, false, S),
    {noreply, S1};
handle_cast(_Msg, S) ->
    {noreply, S}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({if_state_event, Id, State} = _M, S) ->
    %% interface state changes reported by the interface processes
    ?debug("~p",[_M]),
    case get_interface_by_id(Id) of
	false ->
	   ?warning("Recieved ~p from unknown interface",[_M]);
	If=#can_if {state = SOld, param = P} when is_atom(State),
						  SOld =/= State ->
	    P1 = P#{ pid => If#can_if.pid, mod => If#can_if.mod },
	    set_interface(If#can_if { state = State, param = P1 }),
	    Msg = {if_state_event, {Id, P1}, State},
	    inform_supervisors(Msg, S#s.supervisors);
	If=#can_if {state = CurrentState, param = P} when is_map(State) ->
	    P1 = maps:merge(P, State),
	    P2 = P1#{ pid => If#can_if.pid, mod => If#can_if.mod },
	    set_interface(If#can_if { param = P2 }),
	    Msg = {if_state_event, {Id, P2},  CurrentState},
	    inform_supervisors(Msg, S#s.supervisors);
	_If ->
	    ?debug("Recieved ~p, no state change",[_M])
    end,
    {noreply, S};

handle_info({'DOWN',Ref,process,Pid,_Reason},S) ->
    case take_app_by_pid(Pid, S#s.apps) of
	false ->
	    case get_interface_by_pid(Pid) of
		false ->
		    case lists:keytake(Pid, 1, S#s.supervisors) of
			false ->
			    {noreply, S};
			{value, {Pid, Ref}, NewSups} ->
			    ?warning("supervisor ~p died, reason=~p", 
					  [Pid,_Reason]),
			    {noreply, S#s { supervisors = NewSups}}
		    end;
		If ->
		    ?debug("can_router: interface ~p died, reason ~p\n", 
			   [If, _Reason]),
		    erase_interface(If#can_if.id),
		    {noreply,S}
	    end;
	{value,_App,Apps} ->
	    ?debug("can_router: application ~p died, reason ~p\n", 
		   [_App, _Reason]),
	    %% FIXME: Restart?
	    {noreply,S#s { apps = Apps }}
    end;
handle_info({'EXIT', Pid, Reason}, S) ->
    case get_interface_by_pid(Pid) of
	false ->
	    %% Someone else died, log and terminate
	    ?debug("can_router: linked process ~p died, reason ~p, terminating\n", 
		   [Pid, Reason]),
	    {stop, Reason, S};
	If ->
	    %% One of our interfaces died, log and ignore
	    ?debug("can_router: interface ~p died, reason ~p\n", 
		   [If, Reason]),
	    erase_interface(If#can_if.id),
	    {noreply,S}
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
terminate(_Reason, _S) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, S, _Extra) ->
    {ok, S}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

count(Counter, S) ->
    can_counter:update(Counter, 1),
    S.

start_clock() ->
    Clock = erlang:start_timer(16#ffffffff, undefined, undefined),
    put(clock, Clock),
    Clock.

read_clock() ->
    Clock = get(clock),
    case erlang:read_timer(Clock) of
	false ->
	    Clock1 = start_clock(),
	    erlang:read_timer(Clock1);
	Time ->
	    Time
    end.

do_send(Pid, Frame, Sync, S) ->
    case Frame#can_frame.intf of
	0 ->
	    broadcast(Pid,Frame,Sync,S);
	undefined ->
	    broadcast(Pid,Frame,Sync,S);
	I ->
	    case get_interface_by_id(I) of
		false -> 
		    S;
		If ->
		    send_if(If,Frame,Sync,S),
		    S
	    end
    end.

add_if(Pid,Param,S) ->
    Mon = erlang:monitor(process, Pid),
    ID = S#s.if_count,
    ATime =  read_clock() + S#s.wakeup_timeout,
    Mod = maps:get(mod, Param, undefined),
    If = #can_if { pid=Pid, mod=Mod, id=ID, mon=Mon, 
		   param=Param, atime = ATime },
    set_interface(If),
    S1 = S#s { if_count = ID+1 },
    link(Pid),   %% FIME! montior? we alread have a monitor!
    {ID, S1}.

%% ugly but less admin for now
set_interface(If) ->
    put({interface,If#can_if.id}, If).

erase_interface(I) ->
    erase({interface,I}).

get_interface_by_id(I) ->
    case get({interface,I}) of
	undefined -> false;
	If -> If
    end.

find_app_by_pid(Pid,Apps) ->
    lists:keyfind(Pid, #can_app.pid, Apps).

take_app_by_pid(Pid,Apps) ->
    lists:keytake(Pid, #can_app.pid, Apps).
	     
get_interface_by_name(Name) ->
    lists:foldl(fun(If=#can_if{param = #{name:=N}}, Acc)
		      when N =:= Name -> [If | Acc];
		   (_OtherIf, Acc) ->
			Acc
		end, [], get_interface_list()).

%% get interface by local index and module (from config)
get_interface_by_param(#{ mod := Mod, index := Index }) ->
    get_interface_by_param_(Mod, Index, get_interface_list()).

get_interface_by_param_(Mod, Index, [IF|IFs]) ->
    case IF of
	#{ mod := Mod, index := Index } ->
	    {value, IF};
	_ ->
	    get_interface_by_param_(Mod, Index, IFs)
    end;
get_interface_by_param_(_Mod, _Index, []) ->
    false.

get_interface_by_pid(Pid) ->
    lists:keyfind(Pid, #can_if.pid, get_interface_list()).

get_interface_by_backend({BackEnd, BusId}) ->
    lists:foldl(fun(If=#can_if{param = #{mod:=BE, index:=BI}}, Acc)
		      when BE =:= BackEnd, BI =:= BusId -> [If | Acc];
		   (_OtherIf, Acc) ->
			Acc
		end, [], get_interface_list()).

get_interface_list() ->
    [If || {{interface,_},If} <- get()].

send_if(If, Frame, Sync, S) ->
    Time = read_clock(),  %% time is decrementing to zero
    ActivityTime = If#can_if.atime - Time,
    S1 = if S#s.wakeup, ActivityTime >= S#s.wakeup_timeout ->
		 send_wakeup_if(If, Frame#can_frame.id, S);
	    true ->
		 S
	 end,
    S2 = count(stat_out, S1),
    if Sync ->
	    gen_server:call(If#can_if.pid, {send, Frame});
       true ->
	    gen_server:cast(If#can_if.pid, {send, Frame})
    end,
    set_interface(If#can_if { atime = read_clock() }),
    S2.

-define(PDO1_TX,  2#0011).

-define(NODE_ID_MASK,  16#7f).
-define(CAN_ID(Func,Nid), (((Func) bsl 7) bor ((Nid) band ?NODE_ID_MASK))).

-define(XNODE_ID_MASK, 16#01FFFFFF).
-define(XCAN_ID(Func,Nid), (((Func) bsl 25) bor ((Nid) band ?XNODE_ID_MASK))).

can_id(Nid, Func) ->
    if Nid band ?CAN_EFF_FLAG =:= 0 ->
	    {false,?CAN_ID(Func, Nid)};
       true ->
	    {true,?XCAN_ID(Func, Nid)}
    end.

send_wakeup_if(If, Nid, S) ->
    {Ext,ID} = can_id(Nid, ?PDO1_TX),
    Frame = can:create(ID,8,Ext,false,If#can_if.id,
		       <<16#80,?MSG_WAKEUP:16/little,0:8,1:32/little>>),
    gen_server:cast(If#can_if.pid, {send, Frame}),
    count(stat_out, S).

current_state(_Pid, []) ->
    ok;
current_state(Pid, [#can_if {state = S, param = P, id = Id} | Rest]) ->
    Pid ! {if_state_event, {Id, P}, S},
    current_state(Pid, Rest).

inform_supervisors(_Msg, []) ->
    ok;
inform_supervisors(Msg, [{Pid, _Mon} | Sups]) ->
    ?debug("informing ~p of ~p", [Pid, Msg]),
    Pid ! Msg,
    inform_supervisors(Msg, Sups).

%% Broadcast a message to applications/simulated can buses
%% and joined CAN interfaces
%% 
broadcast(Sender,Frame,Sync,S) ->
    ?debug("can_router: broadcast: [~s]", [can_probe:format_frame(Frame)]),
    S1 = broadcast_apps(Sender, Frame, S#s.apps, S),
    broadcast_ifs(Frame, get_interface_list(), Sync, S1).

%% send to all applications, except sender application
broadcast_apps(Sender, Frame, [A|As], S) when A#can_app.pid =/= Sender ->
    case can_filter:input(Frame, A#can_app.fs) of
	true -> A#can_app.pid ! Frame;
	false -> ignore
    end,
    broadcast_apps(Sender, Frame, As, S);
broadcast_apps(Sender, Frame, [_|As], S) ->
    broadcast_apps(Sender, Frame, As, S);
broadcast_apps(_Sender, _Frame, [], S) ->
    S.

%% send errro to all applications that want one
broadcast_error(Frame, [A|As], S) ->
    if A#can_app.error_reception =:= on ->
	    A#can_app.pid ! Frame;
       true ->
	    ignore
    end,
    broadcast_error(Frame, As, S);
broadcast_error( _Frame, [], S) ->
    S.

%% send to all interfaces, except the origin interface
broadcast_ifs(Frame, [If|Is], Sync, S) when
      If#can_if.id =/= Frame#can_frame.intf ->
    S1 = send_if(If, Frame, Sync, S),
    broadcast_ifs(Frame, Is, Sync, S1);
broadcast_ifs(Frame, [_|Is], Sync, S) ->
    broadcast_ifs(Frame, Is, Sync, S);
broadcast_ifs(_Frame, [], _Sync, S) ->
    S.

make_filter(FilterList) when is_list(FilterList) ->
    Fs = can_filter:new(),
    add_filters_(FilterList, Fs, []);
make_filter(_) ->
    {error,badarg}.

add_filters_([{Invert,ID,Mask}|FilterList], Fs, Is) when
    is_boolean(Invert), is_integer(ID), is_integer(Mask) ->
    ID1 = if Invert ->
		  ID bor ?CAN_INV_FILTER;
	     true -> 
		  ID
	  end,
    F = #can_filter { id=ID1, mask=Mask },
    {I,Fs1} = can_filter:add(F,Fs),
    add_filters_(FilterList, Fs1, [I|Is]);
add_filters_([_|_], _Fs, _Is) ->
    {error,badarg};
add_filters_([], Fs, Is) ->
    {ok,Fs,Is}.
