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
-export([start/0, start/1]).
-export([start_link/0, start_link/1]).
-export([join/1]).
-export([attach/0, detach/0]).
-export([send/1, send_from/2]).
-export([cast/1, cast_from/2]).
-export([i/0, i/1]).
-export([statistics/0]).

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


-record(can_if,
	{
	  pid,      %% can interface pid
	  id,       %% interface id
	  mon,      %% can app monitor
	  param     %% match param
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
    case gen_server:call(?SERVER, interfaces) of
	{ok, IFs} ->
	    Stat = foldl(
		     fun({Id,_Param,Pid},Acc) ->
			     case gen_server:call(Pid, statistics) of
				 {ok,Stat} ->
				     [{Id,Stat} | Acc];
				 Error ->
				     [{Id,Error}| Acc]
			     end
		     end, [], IFs),
	    {ok, Stat};
	Error ->
	    Error
    end.

i() ->
    {ok,IFs} =  gen_server:call(?SERVER, interfaces),
    lists:foreach(
      fun({Id,Param,Pid}) ->    
	    case gen_server:call(Pid, statistics) of
		{ok,Stat} ->
		    print_stat(Id, Param, Stat);
		Error ->
		    io:format("~2w: ~p\n  error = ~p\n", [Id,Param,Error])
	    end
      end, IFs).

i(Id) ->
    {ok,IFs} =  gen_server:call(?SERVER, interfaces),
    case lists:keyseach(Id, 1, IFs) of
	{value,{Id,Param,Pid}} ->
	    case gen_server:call(Pid, statistics) of
		{ok,Stat} ->
		    print_stat(Id, Param, Stat);
		Error ->
		    io:format("~2w: ~p\n  error = ~p\n", [Id,Param,Error])
	    end
    end.

print_stat(Id, Param, Stat) ->
    io:format("~2w: ~p\n", [Id, Param]),
    lists:foreach(
      fun({Counter,Value}) ->
	      io:format("  ~p: ~w\n", [Counter, Value])
      end, lists:sort(Stat)).
	

%% attach - simulated can bus or application
attach() ->
    gen_server:call(?SERVER, {attach, self()}).

%% detach the same
detach() ->
    gen_server:call(?SERVER, {detach, self()}).

%% add an interface to the simulated can_bus (may be a real canbus)
join(Params) ->
    gen_server:call(?SERVER, {join, self(), Params}).

send(Frame) when is_record(Frame, can_frame) ->
    gen_server:call(?SERVER, {send, self(), Frame}).

send_from(Pid,Frame) when is_pid(Pid), is_record(Frame, can_frame) ->
    gen_server:call(?SERVER, {send, Pid, Frame}).

cast(Frame) when is_record(Frame, can_frame) ->
    gen_server:cast(?SERVER, {send, self(), Frame}).

cast_from(Pid,Frame) when is_pid(Pid), is_record(Frame, can_frame) ->
    gen_server:cast(?SERVER, {send, Pid, Frame}).

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
	    %% We may extend app interface someday - now it = 0
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
	    {reply, {ok,ID}, S1};
	{value,_} ->
	    {reply, {error,ealready}, S}
    end;
handle_call(interfaces, _From, S) ->
    IFs = map(fun(I) -> {I#can_if.id, I#can_if.param, I#can_if.pid} end,
	      S#s.ifs),
    {reply, {ok, IFs}, S};
handle_call(_Request, _From, S) ->
    {reply, {error, bad_call}, S}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast({send,Pid,Frame}, S) 
  when is_pid(Pid),is_record(Frame, can_frame) ->
    %% router received message from some interface or app
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
    case lists:keysearch(Pid, #can_app.pid, S#s.apps) of
	false ->
	    case lists:keysearch(Pid, #can_if.pid, S#s.ifs) of
		false ->
		    {noreply, S};
		{value,If} ->
		    Ifs = S#s.ifs,
		    {noreply,S#s { ifs = Ifs -- [If] }}
	    end;
	{value,App} ->
	    Apps = S#s.apps,
	    {noreply,S#s { apps = Apps -- [App] }}
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
    
