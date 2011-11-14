%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2010, Tony Rogvall
%%% @doc
%%%    CAN frame demo
%%% @end
%%% Created :  3 Nov 2010 by Tony Rogvall <tony@rogvall.se>

-module(can_epx).

-include_lib("can/include/can.hrl").

-compile(export_all).

-record(s,
	{
	  pix,      %% pixmap
	  win,     %% current view params
	  frames,   %% ets table
	  ix,
	  font_height,
	  w,
	  h
	}).

-define(F_TOP,  20).
-define(F_LEFT, 20).

start() ->
    start(640, 480).

start(W, H) ->
    start(W, H, []).

start(W, H, Opts) ->
    start(50, 50, W, H, Opts).


start(X, Y, W, H, Opts) ->
    can_udp:start(),
    epx:start(),
    spawn_link(fun() -> init(X,Y,W,H,Opts) end).


init(X,Y,W,H,_Opts) ->
    %% create the window
    Win = epx:window_create(X, Y, W, H, [key_press,key_release,
					 motion, left,  %% motion-left-button
					 resize,
					 button_press,button_release]),
    epx:window_attach(Win),  %% connect to default backend
    %% create the drawing pixmap
    Pix  = epx:pixmap_create(W, H, argb),
    epx:pixmap_fill(Pix, {255,255,255}),
    epx:pixmap_attach(Pix),
    Tab = ets:new(frames, []),
    {ok, Font} = epx_font:match([{name, "Arial"}, {size, 18}]),
    epx_gc:set_fill_color({255,255,255,255}),
    epx_gc:set_fill_style(solid),
    epx_gc:set_foreground_color({0,0,0,0}),
    epx_gc:set_font(Font),
    can_router:attach(),
    FontHeight = epx:font_info(Font, ascent) + epx:font_info(Font, descent),
    S = #s { win = Win, pix = Pix, frames = Tab, ix = 0, 
	     w = W, h = H,
	     font_height = FontHeight },
    update_win(S),
    loop(S),
    epx:pixmap_detach(Pix),
    epx:window_detach(Win),
    ok.


loop(S) ->
    receive
	{epx_event,_Win, destroy} ->
	    io:format("DESTROY\n"),
	    ok;
	{epx_event,_Win, close} ->
	    io:format("CLOSE\n"),
	    ok;
	F = #can_frame { } ->
	    S1 = add_frame(F, S),
	    loop(S1)
    end.

update_win(S) ->
    epx:pixmap_draw(S#s.pix, S#s.win, 0, 0, 0, 0, S#s.w, S#s.h).

%% Draw a frame
%% TOP+IX*H   |ID|LEN|DATA|
draw_frame(S, IX, F) ->
    String = lists:flatten(format_frame(F)),
    Y = ?F_TOP + (S#s.font_height+4)*IX,
    X = ?F_LEFT,
    epx:draw_rectangle(S#s.pix, X, Y, S#s.w-?F_LEFT, S#s.font_height+4),
    io:format("@(~w,~w)  ~s\n", [X,Y,String]),
    epx:draw_string(S#s.pix, X, Y, String).
    

add_frame(F, S) ->
    ID = F#can_frame.id,
    Data = F#can_frame.data,
    case ets:lookup(S#s.frames, ID) of
	[] ->
	    IX = S#s.ix,
	    draw_frame(S, IX, F),
	    update_win(S),
	    ets:insert(S#s.frames, {ID,IX,F#can_frame.data}),
	    S#s { ix = IX+1 };
	[{ID,_Ix,Data}] -> %% same
	    S;
	[{ID,IX,Data1}] ->
	    ets:insert(S#s.frames, {ID,IX,Data1}),
	    draw_frame(S, IX, F),
	    update_win(S),
	    S
    end.


format_frame(Frame) ->
    [if ?is_can_frame_eff(Frame) ->
	     io_lib:format("~8.16.0B", 
			   [Frame#can_frame.id band ?CAN_EFF_MASK]);
	true ->
	     io_lib:format("~3.16.0B", 
			   [Frame#can_frame.id band ?CAN_SFF_MASK])
     end,
     "|",
     io_lib:format("~w", [Frame#can_frame.len]),
     "|",
     if ?is_can_frame_rtr(Frame) ->
	     "RTR";
	true ->
	     [format_data(Frame#can_frame.data)]
     end
    ].

format_data(<<H,T/binary>>) ->
    [io_lib:format("~2.16.0B", [H]) | format_data(T)];
format_data(<<>>) ->
    [].	    

