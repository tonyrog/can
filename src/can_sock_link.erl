%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2022, Tony Rogvall
%%% @doc
%%%    SocketCAN netlink/ip link utils
%%% @end
%%% Created : 23 Jan 2022 by Tony Rogvall <tony@rogvall.se>

-module(can_sock_link).

-export([up/1, down/1]).
-export([setup/2]).
-export([set_bitrate/2]).
-export([set_dbitrate/2]).
-export([set_fd_bitrate/3]).
-export([set_listen_only/2]).
-export([set/2]).
-export([is_suid/1, ipset_exec/0]).
-include_lib("kernel/include/file.hrl").

-define(verbose(F, A), ok).
%% -define(verbose(F, A), io:format((F),(A))).

set_bitrate(Dev, BitRate) ->
    setup(Dev, [{bitrate,BitRate}]).
set_dbitrate(Dev, BitRate) ->
    setup(Dev, [{dbitrate,BitRate}]).
set_fd_bitrate(Dev, BitRate, DBitRate) ->
    setup(Dev, [{bitrate,BitRate},{dbitrate,DBitRate},{fd,on}]).

set_listen_only(Dev, Enable) ->
    setup(Dev, [{listen_only,Enable}]).

up(Dev) ->
    ipset("up", Dev, []).

down(Dev) ->
    ipset("down", Dev, []).

setup(Dev, Settings) when is_list(Settings) ->
    down(Dev),
    set(Dev, Settings),
    up(Dev).

set(Dev, Settings) ->
    ipset("set", Dev, Settings).

ipset(Cmd, Dev, Args) ->
    Ipset = ipset_exec(),
    Command = [Ipset," ",Cmd," ",Dev, settings(Args)],
    ?verbose("can_sock_link: Command: ~s\n", [Command]),
    os:cmd(Command).

%% select ipset command, priv=develop, bin=installed when can:install_ipset()
ipset_exec() ->
    Command1 = filename:join(code:priv_dir(can), "ipset"),
    Command2 = filename:join([os:getenv("HOME"),"bin","ipset"]),
    case is_suid(Command1) of
	true -> Command1;
	false ->
	    case is_suid(Command2) of
		true -> Command2;
		false -> false
	    end
    end.

-define(S_ISUID, 8#04000).    %% Set user ID on execution.
-define(S_ISGID, 8#02000).    %% Set group ID on execution.
-define(S_ISVTX, 8#01000).    %% Save swapped text after use (sticky).
-define(S_IREAD, 8#00400).    %% Read by owner.
-define(S_IWRITE,8#00200).    %% Write by owner.
-define(S_IEXEC, 8#00100).    %% Execute by owner.

%% check that File is suid and executable    
is_suid(File) ->
    case file:read_file_info(File) of
	{ok, Info} ->
	    if Info#file_info.mode band 
	       (?S_ISUID bor ?S_ISGID bor ?S_IEXEC) =:= 
	       (?S_ISUID bor ?S_ISGID bor ?S_IEXEC) ->
		    true;
	       true ->
		    false
	    end;
	{error,_} ->
	    false
    end.

settings([]) ->
    [];
settings([{K,V}]) ->
    [" ",setting(K,V)];
settings([{K,V}|Ls]) ->
    [" ",setting(K,V) | settings(Ls)].

setting(type,Type) when is_list(Type) -> ["type ", Type];
setting(dev,Dev) when is_list(Dev) -> ["dev ", Dev];
setting(mtu,Mtu) when Mtu =:= 16; Mtu =:= 72 -> 
    ["mtu ", integer_to_list(Mtu)];
setting(bitrate,Rate) when is_integer(Rate), Rate > 0 ->
    ["bitrate ", integer_to_list(Rate)];
setting(dbitrate,Rate) when is_integer(Rate), Rate > 0 ->
    ["dbitrate ", integer_to_list(Rate)];
setting(fd,true) -> ["fd ", "on"];
setting(fd,false) -> ["fd ", "off"];
setting(listen_only,true) -> ["listen-only ", "on"];
setting(listen_only,false) -> ["listen-only ", "off"];
setting(restart_ms,Ms) when is_integer(Ms), Ms>=0 -> 
    ["restart-ms ", integer_to_list(Ms)].
