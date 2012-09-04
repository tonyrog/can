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
%%% File    : can_router.erl
%%% Author  : Tony Rogvall <tony@PBook.lan>
%%% Description : CAN router
%%%
%%% Created :  7 Jan 2008 by Tony Rogvall <tony@PBook.lan>
%%%-------------------------------------------------------------------
-module(can_router).

-behaviour(gen_server).

%% API
-export([start/0, start/1, stop/0]).
-export([start_link/0, start_link/1]).
-export([join/1]).
-export([attach/0, detach/0]).
-export([send/1, send_from/2]).
-export([sync_send/1, sync_send_from/2]).
-export([input/1, input_from/2]).
-export([add_filter/4, del_filter/2, get_filter/2, list_filter/1]).
-export([stop/1, restart/1]).
-export([i/0, i/1]).
-export([statistics/0]).
-export([debug/2, interfaces/0, interface/1, interface_pid/1]).


%% Backend interface
-export([fs_new/0, fs_add/2, fs_add/3, fs_del/2, fs_get/2, fs_list/1]).
-export([fs_input/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-import(lists, [foreach/2, map/2, foldl/3]).

-include("../include/can.hrl").

-define(SERVER, can_router).

-ifdef(debug).
-define(dbg(Fmt,As), io:format((Fmt), (As))).
-else.
-define(dbg(Fmt,As), ok).
-endif.

%% Filter structure (also used by backends)
-record(can_fs,
	{
	  next_id = 1,
	  filter = []  %% [{I,#can_filter{}}]
	}).

-record(can_if,
	{
	  pid,      %% can interface pid
	  id,       %% interface id
	  mon,      %% can app monitor
	  param     %% match param normally {Mod,Name,Index} 
	}).

-record(can_app,
	{
	  pid,       %% can app pid
	  mon,       %% can app monitor
	  interface  %% interface id
	 }).

-record(s,
	{
	  if_count = 1,  %% interface id counter
	  apps = [],     %% attached can applications
	  ifs  = [],     %% joined interfaces
	  stat_in=0,     %% number of input packets received
	  stat_err=0,    %% number of error packets received
	  stat_out=0     %% number of output packets  sent
	}).

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

start() -> start([]).

start(Args) ->
    gen_server:start({local, ?SERVER}, ?MODULE, Args, []).

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
    IFs = interfaces(),
    case lists:keysearch(Id, #can_if.id, IFs) of
	false ->
	    {error, enoent};
	{value, IF} ->
	    {ok,IF}
    end.

interface_pid(Id) ->
    {ok,IF} = interface(Id),
    IF#can_if.pid.

debug(Id, Bool) ->
    call_if(Id, {debug, Bool}).

stop(Id) ->
    call_if(Id, stop).    

restart(Id) ->
    case gen_server:call(?SERVER, {interface,Id}) of
	{ok,If} ->
	    case If#can_if.param of
		{can_usb,_,N} ->
		    ok = gen_server:call(If#can_if.pid, stop),
		    can_usb:start(N);
		{can_udp,_,N} ->
		    ok = gen_server:call(If#can_if.pid, stop),
		    can_udp:start(N-51712);
		{can_sock,IfName,_Index} ->
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
    lists:foreach(
      fun({Counter,Value}) ->
	      io:format("  ~p: ~w\n", [Counter, Value])
      end, lists:sort(Stat)).

call_if(Id, Request) ->	
    case gen_server:call(?SERVER, {interface,Id}) of
	{ok,If} ->
	    gen_server:call(If#can_if.pid, Request);
	{error,enoent} ->
	    io:format("~2w: no such interface\n", [Id]),
	    {error,enoent};
	Error ->
	    Error
    end.

stop() ->
    gen_server:call(?SERVER, stop).

%% attach - simulated can bus or application
attach() ->
    gen_server:call(?SERVER, {attach, self()}).

%% detach the same
detach() ->
    gen_server:call(?SERVER, {detach, self()}).

%% add an interface to the simulated can_bus (may be a real canbus)
join(Params) ->
    gen_server:call(?SERVER, {join, self(), Params}).

add_filter(Intf, Invert, ID, Mask) when 
      is_boolean(Invert), is_integer(ID), is_integer(Mask) ->
    gen_server:call(?SERVER, {add_filter, Intf, Invert, ID, Mask}).

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

input_from(Pid,Frame) when is_pid(Pid), is_record(Frame, can_frame) ->
    gen_server:cast(?SERVER, {input, Pid, Frame}).

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
init(_Args) ->
    process_flag(trap_exit, true),
    {ok, #s{}}.

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
    S1 = broadcast(Pid,Frame,S),
    {reply, ok, S1}; 

handle_call({attach,Pid}, _From, S) when is_pid(Pid) ->
    Apps = S#s.apps,
    case lists:keysearch(Pid, #can_app.pid, Apps) of
	false ->
	    Mon = erlang:monitor(process, Pid),
	    %% We may extend app interface someday - now = 0
	    App = #can_app { pid=Pid, mon=Mon, interface=0 },
	    Apps1 = [App | Apps],
	    {reply, ok, S#s { apps = Apps1 }};
	{value,_} ->
	    {reply, ok, S}
    end;
handle_call({detach,Pid}, _From, S) when is_pid(Pid) ->
    Apps = S#s.apps,
    case lists:keysearch(Pid, #can_app.pid, Apps) of
	false ->
	    {reply, ok, S};
	{value,App=#can_app {}} ->
	    Mon = App#can_app.mon,
	    erlang:demonitor(Mon),
	    receive {'DOWN',Mon,_,_,_} -> ok
	    after 0 -> ok
	    end,
	    {reply,ok,S#s { apps = Apps -- [App] }}
    end;
handle_call({join,Pid,Param}, _From, S) ->
    case lists:keysearch(Param, #can_if.param, S#s.ifs) of
	false ->
	    Mon = erlang:monitor(process, Pid),
	    ID = S#s.if_count,
	    If = #can_if { pid=Pid, id=ID, mon=Mon, param=Param },
	    Ifs1 = [If | S#s.ifs ],
	    S1 = S#s { if_count = ID+1, ifs = Ifs1 },
	    link(Pid),
	    {reply, {ok,ID}, S1};
	{value,_} ->
	    {reply, {error,ealready}, S}
    end;
handle_call({interface,I}, _From, S) when is_integer(I) ->
    case lists:keysearch(I, #can_if.id, S#s.ifs) of
	false ->
	    {reply, {error,enoent}, S};
	{value,If} ->
	    {reply, {ok,If}, S}
    end;
handle_call({interface,Param}, _From, S) ->
    case lists:keysearch(Param, #can_if.param, S#s.ifs) of
	false ->
	    {reply, {error,enoent}, S};
	{value,If} ->
	    {reply, {ok,If}, S}
    end;
handle_call(interfaces, _From, S) ->
    {reply, S#s.ifs, S};
handle_call(applications, _From, S) ->
    {reply, S#s.apps, S};
handle_call({add_filter,Intf,Invert,ID,Mask}, From, S) when 
      is_integer(Intf), is_boolean(Invert), is_integer(ID), is_integer(Mask) ->
    case lists:keysearch(Intf, #can_if.id, S#s.ifs) of
	false ->
	    {reply, {error, enoent}, S};
	{value,If} ->
	    ID1 = if Invert ->
			  ID bor ?CAN_INV_FILTER;
		     true -> 
			  ID
		  end,
	    F = #can_filter { id=ID1, mask=Mask},
	    gen_server:cast(If#can_if.pid, {add_filter,From,F}),
	    {noreply, S}
    end;

handle_call({del_filter,Intf,I}, From, S) ->
    case lists:keysearch(Intf, #can_if.id, S#s.ifs) of
	false ->
	    {reply, {error, enoent}, S};
	{value,If} ->
	    gen_server:cast(If#can_if.pid, {del_filter,From,I}),
	    {noreply, S}
    end;

handle_call({get_filter,Intf,I}, From, S) ->
    case lists:keysearch(Intf, #can_if.id, S#s.ifs) of
	false ->
	    {reply, {error, enoent}, S};
	{value,If} ->
	    gen_server:cast(If#can_if.pid, {get_filter,From,I}),
	    {noreply, S}
    end;

handle_call({list_filter,Intf}, From, S) ->
    case lists:keysearch(Intf, #can_if.id, S#s.ifs) of
	false ->
	    {reply, {error, enoent}, S};
	{value,If} ->
	    gen_server:cast(If#can_if.pid, {list_filter,From}),
	    {noreply,S}
    end;

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
	    S1 = error(Pid, Frame, S),
	    {noreply, S1};
       true ->
	    S1 = S#s { stat_in = S#s.stat_in + 1 },
	    S2 = broadcast(Pid, Frame, S1),
	    {noreply, S2}
    end;
handle_cast({send,Pid,Frame}, S) 
  when is_pid(Pid),is_record(Frame, can_frame) ->
    S1 = broadcast(Pid, Frame, S),
    {noreply, S1};
handle_cast(_Msg, S) ->
    {noreply, S}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({'DOWN',_Ref,process,Pid,_Reason},S) ->
    case lists:keytake(Pid, #can_app.pid, S#s.apps) of
	false ->
	    case lists:keytake(Pid, #can_if.pid, S#s.ifs) of
		false ->
		    {noreply, S};
		{value,_If,Ifs} ->
		    %% FIXME: Restart?
		    {noreply,S#s { ifs = Ifs }}
	    end;
	{value,_App,Apps} ->
	    %% FIXME: Restart?
	    {noreply,S#s { apps = Apps }}
    end;
handle_info({'EXIT', Pid, Reason}, S) ->
    case lists:keytake(Pid, #can_if.pid, S#s.ifs) of
	{value,_If,Ifs} ->
	    %% One of our interfaces died, log and ignore
	    ?dbg("can_router: interface ~p died, reason ~p\n", [_If, Reason]),
	    {noreply,S#s { ifs = Ifs }};
	false ->
	    %% Someone else died, log and terminate
	    ?dbg("can_router: linked process ~p died, reason ~p, terminating\n", 
		 [Pid, Reason]),
	    {stop, Reason, S}
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

%% fs_xxx functions are normally called from backends
%% if filter returns true then pass the message through
%% (a bit strange, but follows the logic from lists:filter/2)
%%

%% create filter structure
fs_new() ->
    #can_fs {}.

%% add filter to filter structure
fs_add(F, Fs) when is_record(F, can_filter), is_record(Fs, can_fs) ->
    I = Fs#can_fs.next_id,
    Filter = Fs#can_fs.filter ++ [{I,F}],
    {I, Fs#can_fs { filter=Filter, next_id=I+1 }}.

fs_add(I,F,Fs) when is_integer(I), is_record(F,can_filter),
		    is_record(Fs,can_fs) ->
    Filter = [{I,F} | Fs#can_fs.filter],
    NextId = Fs#can_fs.next_id,
    Fs#can_fs { filter=Filter, next_id=erlang:max(I+1,NextId)}.

%% remove filter from filter structure
fs_del(F, Fs) when is_record(F, can_filter), is_record(Fs, can_fs) ->
    case lists:keytake(F, 2, Fs#can_fs.filter) of
	{value,_FI,Filter} ->
	    {true, Fs#can_fs { filter=Filter }};
	false ->
	    {false, Fs}
    end;
fs_del(I, Fs) when is_record(Fs, can_fs) ->
    case lists:keytake(I, 1, Fs#can_fs.filter) of
	{value,_FI,Filter} ->
	    {true, Fs#can_fs { filter=Filter }};
	false ->
	    {false, Fs}
    end.

fs_get(I, Fs) when is_record(Fs, can_fs) ->
    case lists:keysearch(I, 1, Fs#can_fs.filter) of
	{value,FI} ->
	    {ok,FI};
	false ->
	    {error, enoent}
    end.

%% return the filter list [{Num,#can_filter{}}]
fs_list(Fs) when is_record(Fs, can_fs) ->
    {ok, Fs#can_fs.filter}.

    
%% filter a frame
%% return true for no filtering (pass through)
%% return false for filtering
%%
fs_input(F, Fs) when is_record(F, can_frame), is_record(Fs, can_fs) ->
    case Fs#can_fs.filter of
	[] -> true;  %% default to accept all
	Filter -> filter_(F,Filter)
    end.

filter_(Frame, [{_I,F}|Fs]) ->
    Mask = F#can_filter.mask,
    Cond = (Frame#can_frame.id band Mask) =:= (F#can_filter.id band Mask),
    if ?is_not_can_id_inv_filter(F#can_filter.id), Cond ->
	    true;
       ?is_can_id_inv_filter(F#can_filter.id), not Cond ->
	    true;
       true ->
	    filter_(Frame, Fs)
    end;
filter_(_Frame, []) ->
    false.

%% Error frame handling
error(_Sender, _Frame, S) ->
    ?dbg("can_router: error frame = ~p\n", [_Frame]),
    %% FIXME: send to error handler
    S1 = S#s { stat_err = S#s.stat_err + 1 },
    S1.

%% Broadcast a message to applications/simulated can buses
%% and joined CAN interfaces
%% 
broadcast(Sender,Frame,S) ->
    Sent0 = broadcast_apps(Sender, Frame, S#s.apps, 0),
    Sent  = broadcast_ifs(Frame, S#s.ifs, Sent0),
    ?dbg("CAN_ROUTER:broadcast: frame=~p, send=~w\n", [Frame, Sent]),
    if Sent > 0 ->
	    S#s { stat_out = S#s.stat_out + 1 };
       true ->
	    S
    end.


%% send to all applications, except sender application
broadcast_apps(Sender, Frame, [A|As], Sent) when A#can_app.pid =/= Sender ->
    A#can_app.pid ! Frame,
    broadcast_apps(Sender, Frame, As, Sent+1);
broadcast_apps(Sender, Frame, [_|As], Sent) ->
    broadcast_apps(Sender, Frame, As, Sent);
broadcast_apps(_Sender, _Frame, [], Sent) ->
    Sent.

%% send to all interfaces, except the origin interface
broadcast_ifs(Frame, [I|Is], Sent) when I#can_if.id =/= Frame#can_frame.intf ->
    gen_server:cast(I#can_if.pid, {send, Frame}),
    broadcast_ifs(Frame, Is, Sent+1);
broadcast_ifs(Frame, [_|Is], Sent) ->
    broadcast_ifs(Frame, Is, Sent);
broadcast_ifs(_Frame, [], Sent) ->
    Sent.
    
