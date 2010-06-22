OSNAME  := $(shell uname -s)

ifeq ($(OSNAME), Linux)
all:
	(cd c_src; make $@)
	(cd src; make $@)
else
all:
	(cd src; make $@)
endif

edoc:
	(cd src; make edoc)
