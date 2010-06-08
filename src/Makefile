#
# Make the canopen erlang implementation
#

MODULES = \
	can \
	can_app \
	can_sup \
	can_router \
	can_udp \
	can_usb 

EBIN = ../ebin
ERLC = erlc

include ../vsn.mk
VSN=$(CAN_VSN)

APP_FILE= can.app
APP_SRC= $(APP_FILE).src
APP_TARGET= $(EBIN)/$(APP_FILE)

override ERLC_FLAGS = -Wall -I ../include 

debug: ERLC_FLAGS += +debug_info -Ddebug

OBJS = $(MODULES:%=$(EBIN)/%.beam)
TARGET_FILES = $(OBJS) $(APP_TARGET)

all: $(TARGET_FILES)

debug: all

depend:
	edep -MM -o ../ebin $(ERLC_FLAGS) $(MODULES:%=%.erl) > depend.mk

dialyze:
	dialyzer --src -o dia.out -I ../include -c $(MODULES:%=%.erl) 

clean:
	rm -f $(OBJS) 

$(APP_TARGET): $(APP_SRC) ../vsn.mk
	sed -e 's;%VSN%;$(VSN);'  $< > $@

-include depend.mk

../ebin/%.beam:	%.erl
	erlc -o ../ebin $(ERLC_FLAGS) $<
