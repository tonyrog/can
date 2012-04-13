%%% File    : can_sup.erl
%%% Author  : Tony Rogvall <tony@PBook.local>
%%% Description : 
%%% Created : 28 Aug 2006 by Tony Rogvall <tony@PBook.local>

-module(can_sup).

-behaviour(supervisor).

%% External exports
-export([start_link/0, start_link/1, stop/1]).

%% supervisor callbacks
-export([init/1]).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
start_link(Args) ->
    error_logger:info_msg("~p: start_link: args = ~p\n", [?MODULE, Args]),
    case supervisor:start_link({local, ?MODULE}, ?MODULE, Args) of
	{ok, Pid} ->
	    {ok, Pid, {normal, Args}};
	Error -> 
	    Error
    end.

start_link() ->
    supervisor:start_link({local,?MODULE}, ?MODULE, []).

stop(_StartArgs) ->
    ok.

%%%----------------------------------------------------------------------
%%% Callback functions from supervisor
%%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%%----------------------------------------------------------------------
init(Args) ->
    error_logger:info_msg("~p: init: args = ~p,\n pid = ~p\n", [?MODULE, Args, self()]),
    CanRouter = {can_router, {can_router, start_link, [Args]},
		 permanent, 5000, worker, [can_router]},
    {ok,{{one_for_all,0,300}, [CanRouter]}}.
