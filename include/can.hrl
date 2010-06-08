%%
%%  Can frame definition 
%%
-ifndef(__CAN_HRL__).
-define(__CAN_HRL__, true).

-record(can_frame,
	{
	  id,         %% integer 11 | 29 bit (ide=true)
	  rtr=false,  %% remote transmission request (=>len=data=undefined)
	  ext=false,  %% Identifier extension bit
	  intf=0,     %% Interface number
	  len,        %% length of data 0..8
	  data,       %% binary with data bytes
	  ts          %% interface timestamp if present (millisenconds)
	 }).
%%
%% The timestamp may be present from some interfaces.
%% The CANUSB interface keep an 16 bit timestamp (if enabled) that
%% wraps at 0xEA5F = 59999 meaning that ot wraps after one minute.
%% ts will be undefined if unsupported or disabled
%% ts will be error if an error is detected while parsing timestamp info
%%

-define(EXT_BIT,   16#80000000).
-define(RTR_BIT,   16#40000000).
-define(ERR_BIT,   16#20000000).

-define(CAN11_ID_MASK,    16#7ff).
-define(CAN11_ID_INVALID, 16#7f0).
-define(CAN11_ID_VALID(I),
	((((I) band (bnot ?CAN11_ID_MASK)) == 0) and 
	 (((I) band ?CAN11_ID_INVALID) =/= ?CAN11_ID_INVALID))).

-define(CAN29_ID_MASK,     16#1fffffff).
-define(CAN29_ID_INVALID,  16#1fc00000).
-define(CAN29_ID_VALID(I),
	((((I) band (bnot ?CAN29_ID_MASK)) == 0) and 
	 (((I) band ?CAN29_ID_INVALID) =/= ?CAN29_ID_INVALID))).

-define(CAN_ERROR_DATA,                data_format).
-define(CAN_ERROR_CORRUPT,             data_corrupt).
-define(CAN_ERROR_DATA_TOO_LARGE,      data_too_large).
-define(CAN_ERROR_DATA_TOO_SMALL,      data_too_small).
-define(CAN_ERROR_ID_OUT_OF_RANGE,     id_out_of_range).
-define(CAN_ERROR_LENGTH_OUT_OF_RANGE, length_out_of_range).
-define(CAN_ERROR_TRANSMISSION,        transmission).

-define(CAN_ERROR_RECV_FIFO_FULL,   16#01).
-define(CAN_ERROR_SEND_FIFO_FULL,   16#02).
-define(CAN_ERROR_WARNING,          16#04).
-define(CAN_ERROR_DATA_OVER_RUN,    16#08).
-define(CAN_ERROR_PASSIVE,          16#20).
-define(CAN_ERROR_ARBITRATION_LOST, 16#40).
-define(CAN_ERROR_BUS,              16#80).

-endif.
