OSNAME  := $(shell uname -s)

ifeq ($(OSNAME), Linux)
all:
	(cd c_src; make $@)
	(cd src; make $@)
else
all:
	(cd src; make $@)
endif

doc:
	(cd src; make edoc)
