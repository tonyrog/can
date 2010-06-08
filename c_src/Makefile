EAPI_DIR = ../../eapi
include $(EAPI_DIR)/make/eapi_drv.mk

CFLAGS += -I $(EAPI_DIR)/include 
LDFLAGS += 


CAN_SOCK_DRV = $(PRIVDIR)/can_sock_drv.so

CAN_SOCK_DRV_OBJS = \
        $(OBJDIR)/can_sock.o \
        $(OBJDIR)/can_sock_drv.o

EAPI_LIB = $(EAPI_DIR)/lib/$(TYPE)/eapi_drv.a

all:
	$(MAKE) driver TYPE=debug
	$(MAKE) driver TYPE=release

debug:
        $(MAKE) driver TYPE=debug

release:
        $(MAKE) driver TYPE=release

clean: 
        $(MAKE) clean_internal TYPE=release
        $(MAKE) clean_internal TYPE=debug

clean_debug:
        $(MAKE) clean_internal TYPE=debug

driver: $(CAN_SOCK_DRV)

depend:

clean_internal:
	rm -f $(OBJDIR)/*.o

$(CAN_SOCK_DRV): $(CAN_SOCK_DRV_OBJS)
	$(LD_SHARED) -o $@ $(CAN_SOCK_DRV_OBJS) $(EAPI_LIB) $(LDFLAGS)

$(OBJDIR)/can_sock.o: $(EAPI_DIR)/include/eapi_drv.h

$(OBJDIR)/can_sock_drv.o: $(EAPI_DIR)/include/eapi_drv.h

$(OBJDIR)/%.o: %.c
	$(CC) -c -o $@ $(CFLAGS) -I$(ERL_C_INCLUDE_DIR) $<
