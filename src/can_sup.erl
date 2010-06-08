%%% File    : can_sup.erl
%%% Author  : Tony Rogvall <tony@PBook.local>
%%% Description : 
%%% Created : 28 Aug 2006 by Tony Rogvall <tony@PBook.local>

-module(can_sup).

-behaviour(supervisor).

%% External exports
-export([start_link/0, start_link/1]).

%% supervisor callbacks
-export([init/1]).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
start_link() ->
    start_link([]).
start_link(Args) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Args).


%%%----------------------------------------------------------------------
%%% Callback functions from supervisor
%%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%%----------------------------------------------------------------------
init(Args) ->
    CanRouter = {can_router, {can_router, start_link, [Args]},
		 permanent, 5000, worker, [can_router]},
    {ok,{{one_for_all,0,300}, [CanRouter]}}.
