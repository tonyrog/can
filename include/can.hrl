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
%%
%%  Can frame definition 
%%
-ifndef(__CAN_HRL__).
-define(__CAN_HRL__, true).

-define(CAN_EFF_FLAG,   16#80000000).  %% Extended frame format
-define(CAN_RTR_FLAG,   16#40000000).  %% Request for transmission
-define(CAN_ERR_FLAG,   16#20000000).  %% Error frame, input frame only

-define(CAN_SFF_MASK,    16#7ff).
-define(CAN_EFF_MASK,    16#1fffffff).
-define(CAN_ERR_MASK,    16#1fffffff).

-define(CAN_SFF_INVALID,  16#7f0).
-define(CAN_EFF_INVALID,  16#1fc00000).

-define(CAN_NO_TIMESTAMP, -1).

-record(can_frame,
	{
	  id,          %% integer 11 | 29 bit (ide=true) + EXT_BIT|RTR_BIT
	  len=0,       %% length of data 0..8
	  data=(<<>>), %% binary with data bytes
	  intf=0,      %% Input interface number
	  ts=?CAN_NO_TIMESTAMP %% timestamp in (millisenconds)
	}).

%%
%% Accept filter:
%%    (Frame.id & Filter.mask) =:= (Filter.id & Filter.mask)
%% Reject filter: 
%%    (Frame.id & Filter.mask) =/= (Filter.id & Filter.mask)
%%    when CAN_INV_FILTER is set on Filter.id
%%
%% To filter Error frames the ERR_BIT must be set in the Filter.mask
%%
-define(CAN_INV_FILTER,   16#20000000).
-define(is_can_id_inv_filter(ID), (((ID) band ?CAN_INV_FILTER) =/= 0)).
-define(is_not_can_id_inv_filter(ID), (((ID) band ?CAN_INV_FILTER) =:= 0)).

-record(can_filter,
	{
	  id,           %% match when (recived id & mask) == (id & mask)
	  mask
	}).

-define(is_can_id_eff(ID), ((ID) band ?CAN_EFF_FLAG) =/= 0).
-define(is_can_id_sff(ID), ((ID) band ?CAN_EFF_FLAG) =:= 0).
-define(is_can_id_rtr(ID), ((ID) band ?CAN_RTR_FLAG) =/= 0).
-define(is_can_id_err(ID), ((ID) band ?CAN_ERR_FLAG) =/= 0).

-define(is_not_can_id_rtr(ID), (((ID) band ?CAN_RTR_FLAG) =:= 0)).
-define(is_not_can_id_err(ID), (((ID) band ?CAN_ERR_FLAG) =:= 0)).


-define(is_can_valid_timestamp(F), ((F)#can_frame.ts > 0)).
-define(is_can_frame_eff(F), ?is_can_id_eff((F)#can_frame.id)).
-define(is_can_frame_rtr(F), ?is_can_id_rtr((F)#can_frame.id)).
-define(is_can_frame_err(F), ?is_can_id_err((F)#can_frame.id)).

%%
%% The timestamp may be present from some interfaces.
%% The CANUSB interface keep an 16 bit timestamp (if enabled) that
%% wraps at 0xEA5F = 59999 meaning that ot wraps after one minute.
%% ts will be undefined if unsupported or disabled
%% ts will be error if an error is detected while parsing timestamp info
%%

-define(is_can_id_sff_valid(I),
	((((I) band ?CAN_SFF_MASK) =:= ((I) band ?CAN_EFF_MASK)) 
	 andalso
	   (((I) band ?CAN_SFF_INVALID) =/= ?CAN_SFF_INVALID))).

%% Probably more bits to check? or is the extension part bit stuffed?
-define(is_can_id_eff_valid(I),
	(((I) band ?CAN_EFF_INVALID) =/= ?CAN_EFF_INVALID)).

-define(can_error_data,                data_format).
-define(can_error_corrupt,             data_corrupt).
-define(can_error_data_too_large,      data_too_large).
-define(can_error_data_too_small,      data_too_small).
-define(can_error_id_out_of_range,     id_out_of_range).
-define(can_error_length_out_of_range, length_out_of_range).
-define(can_error_transmission,        transmission).

%% error class (mask) in can_id
-define(CAN_ERR_TX_TIMEOUT,  16#00000001). %% TX timeout (by netdevice driver) 
-define(CAN_ERR_LOSTARB,     16#00000002). %% lost arbitration    / data[0]    
-define(CAN_ERR_CRTL,        16#00000004). %% controller problems / data[1]    
-define(CAN_ERR_PROT,        16#00000008). %% protocol violations / data[2..3] 
-define(CAN_ERR_TRX,         16#00000010). %% transceiver status  / data[4]    
-define(CAN_ERR_ACK,         16#00000020). %% received no ACK on transmission 
-define(CAN_ERR_BUSOFF,      16#00000040). %% bus off 
-define(CAN_ERR_BUSERROR,    16#00000080). %% bus error (may flood!) 
-define(CAN_ERR_RESTARTED,   16#00000100). %% controller restarted 

%% arbitration lost in bit ... / data[0] 
-define(CAN_ERR_LOSTARB_UNSPEC,  16#00). %% unspecified 
				      %% else bit number in bitstream 

%% error status of CAN-controller / data[1] 
-define(CAN_ERR_CRTL_UNSPEC,     16#00). %% unspecified 
-define(CAN_ERR_CRTL_RX_OVERFLOW,16#01). %% RX buffer overflow 
-define(CAN_ERR_CRTL_TX_OVERFLOW,16#02). %% TX buffer overflow 
-define(CAN_ERR_CRTL_RX_WARNING, 16#04). %% reached warning level for RX errors 
-define(CAN_ERR_CRTL_TX_WARNING, 16#08). %% reached warning level for TX errors 
-define(CAN_ERR_CRTL_RX_PASSIVE, 16#10). %% reached error passive status RX 
-define(CAN_ERR_CRTL_TX_PASSIVE, 16#20). %% reached error passive status TX 
				      %% (at least one error counter exceeds 
				      %% the protocol-defined level of 127)  

%% error in CAN protocol (type) / data[2] 
-define(CAN_ERR_PROT_UNSPEC,     16#00). %% unspecified 
-define(CAN_ERR_PROT_BIT,        16#01). %% single bit error 
-define(CAN_ERR_PROT_FORM,       16#02). %% frame format error 
-define(CAN_ERR_PROT_STUFF,      16#04). %% bit stuffing error 
-define(CAN_ERR_PROT_BIT0,       16#08). %% unable to send dominant bit 
-define(CAN_ERR_PROT_BIT1,       16#10). %% unable to send recessive bit 
-define(CAN_ERR_PROT_OVERLOAD,   16#20). %% bus overload 
-define(CAN_ERR_PROT_ACTIVE,     16#40). %% active error announcement 
-define(CAN_ERR_PROT_TX,         16#80). %% error occured on transmission 

%% error in CAN protocol (location) / data[3] 
-define(CAN_ERR_PROT_LOC_UNSPEC, 16#00). %% unspecified 
-define(CAN_ERR_PROT_LOC_SOF,    16#03). %% start of frame 
-define(CAN_ERR_PROT_LOC_ID28_21,16#02). %% ID bits 28 - 21 (SFF: 10 - 3) 
-define(CAN_ERR_PROT_LOC_ID20_18,16#06). %% ID bits 20 - 18 (SFF: 2 - 0 )
-define(CAN_ERR_PROT_LOC_SRTR,   16#04). %% substitute RTR (SFF: RTR) 
-define(CAN_ERR_PROT_LOC_IDE,    16#05). %% identifier extension 
-define(CAN_ERR_PROT_LOC_ID17_13,16#07). %% ID bits 17-13 
-define(CAN_ERR_PROT_LOC_ID12_05,16#0F). %% ID bits 12-5 
-define(CAN_ERR_PROT_LOC_ID04_00,16#0E). %% ID bits 4-0 
-define(CAN_ERR_PROT_LOC_RTR,    16#0C). %% RTR 
-define(CAN_ERR_PROT_LOC_RES1,   16#0D). %% reserved bit 1 
-define(CAN_ERR_PROT_LOC_RES0,   16#09). %% reserved bit 0 
-define(CAN_ERR_PROT_LOC_DLC,    16#0B). %% data length code 
-define(CAN_ERR_PROT_LOC_DATA,   16#0A). %% data section 
-define(CAN_ERR_PROT_LOC_CRC_SEQ,16#08). %% CRC sequence 
-define(CAN_ERR_PROT_LOC_CRC_DEL,16#18). %% CRC delimiter 
-define(CAN_ERR_PROT_LOC_ACK,    16#19). %% ACK slot 
-define(CAN_ERR_PROT_LOC_ACK_DEL,16#1B). %% ACK delimiter 
-define(CAN_ERR_PROT_LOC_EOF,    16#1A). %% end of frame 
-define(CAN_ERR_PROT_LOC_INTERM, 16#12). %% intermission 

%% error status of CAN-transceiver / data[4] 
%%                                             CANH CANL 
-define(CAN_ERR_TRX_UNSPEC,            16#00). %% 0000 0000 
-define(CAN_ERR_TRX_CANH_NO_WIRE,      16#04). %% 0000 0100 
-define(CAN_ERR_TRX_CANH_SHORT_TO_BAT, 16#05). %% 0000 0101 
-define(CAN_ERR_TRX_CANH_SHORT_TO_VCC, 16#06). %% 0000 0110 
-define(CAN_ERR_TRX_CANH_SHORT_TO_GND, 16#07). %% 0000 0111 
-define(CAN_ERR_TRX_CANL_NO_WIRE,      16#40). %% 0100 0000 
-define(CAN_ERR_TRX_CANL_SHORT_TO_BAT, 16#50). %% 0101 0000 
-define(CAN_ERR_TRX_CANL_SHORT_TO_VCC, 16#60). %% 0110 0000 
-define(CAN_ERR_TRX_CANL_SHORT_TO_GND, 16#70). %% 0111 0000 
-define(CAN_ERR_TRX_CANL_SHORT_TO_CANH,16#80). %% 1000 0000

%% controller specific additional information / data[5..7] 

-endif.
