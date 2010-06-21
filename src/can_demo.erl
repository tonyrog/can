%% 
%% Start the MERISC can demo
%%
-module(can_demo).
-export([start/0]).


start() ->
    {ok,_} = can_router:start(),
    {ok,_} = can_sock:start("can0"),
    {ok,_} = can_udp:start(),
    ok.
