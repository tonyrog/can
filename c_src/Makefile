#@BEGIN-C_SRC-DEFAULT-RULES@
ERL=$(shell readlink -f `which erl`)
ERL_TOP=$(ERL:%/bin/erl=%)
OS=$(shell uname -s)
CFLAGS=-MMD -MP -MF .$<.d -I$(ERL_TOP)/usr/include
#@END-C_SRC-DEFAULT-RULES@

APP=can_sock
CC=gcc
CFLAGS+= -Wall -O3 -DLOG_DEFAULT=LOG_NONE
LDFLAGS+=-shared

OBJS = can_sock_drv.o
LIBS = 

all: ../priv/$(APP)_drv.so ../priv/ipset

../priv/$(APP)_drv.so: $(OBJS)
	$(CC) $(LDFLAGS) $(OBJS) $(LIBS) -o ../priv/$(APP)_drv.so

# sudo chown root:root ipset; sudo chmod +s ipset
../priv/ipset: ipset.o
	$(CC) ipset.o -o $@

%.o:	%.c
	$(CC) $(CFLAGS) -c -fPIC $<

.%.d:	;

-include .*.d
