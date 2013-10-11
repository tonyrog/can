%%%---- BEGIN COPYRIGHT -------------------------------------------------------
%%%
%%% Copyright (C) 2007 - 2013, Rogvall Invest AB, <tony@rogvall.se>
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
%%% @author Malotte W Lönne <malotte@malotte.net>
%%% @copyright (C) 2013, Tony Rogvall
%%% @doc
%%%  Can bus interface supervisor
%%%
%%% Created: 2013 by Malotte W Lönne 
%%% @end

-module(can_if_sup).

-behaviour(supervisor).

-include_lib("lager/include/log.hrl").
%% external exports
-export([start_link/0, 
	 start_link/1, 
	 stop/1]).

%% supervisor callbacks
-export([init/1]).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
start_link(Args) ->
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
init(_Args) ->
    Interfaces = 
	lists:foldr(
	  fun({CanMod,If,CanOpts},Acc) ->
		  Spec={{CanMod,If}, 
			{CanMod, start_link, [If,CanOpts]},
			permanent, 5000, worker, [CanMod]},
		  [Spec | Acc]
	  end, [], 
	  case application:get_env(can, interfaces) of
	      undefined -> [];
	      {ok,IfList} when is_list(IfList) ->
		  IfList
	  end),
    {ok,{{one_for_one,3,5}, Interfaces}}.
