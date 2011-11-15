OSNAME  := $(shell uname -s)

ifeq ($(OSNAME), Linux)
all:
	rebar compile

it:
	(cd c_src; make $@)
	(cd src; make $@)
else
all:
	rebar compile
endif

edoc:
	(cd src; make edoc)
