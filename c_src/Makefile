EAPI_DIR = ../../eapi
include $(EAPI_DIR)/make/eapi_drv.mk

CFLAGS += -I $(EAPI_DIR)/include -I .
LDFLAGS += 

# No prefix for the .so file (just causes problem right now)
CAN_SOCK_DRV = $(PRIVDIR)/can_sock_drv.so
CAN_SOCK_DRV_OBJS = \
        $(OBJDIR)/$(EAPI_PFX)can_sock_drv.o \
        $(OBJDIR)/$(EAPI_PFX)can_sock_drv_impl.o

EAPI_LIB = $(EAPI_DIR)/lib/$(TYPE)/$(EAPI_PFX)eapi_drv.a

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
	rm -f $(CAN_SOCK_DRV)
	rm -f $(CAN_SOCK_DRV_OBJS)

$(CAN_SOCK_DRV): $(CAN_SOCK_DRV_OBJS)
	$(LD_SHARED) -o $@ $(CAN_SOCK_DRV_OBJS) $(EAPI_LIB) $(LDFLAGS)

$(OBJDIR)/$(EAPI_PFX)can_sock_drv.o: $(EAPI_DIR)/include/eapi_drv.h

$(OBJDIR)/$(EAPI_PFX)can_sock_drv_impl.o: $(EAPI_DIR)/include/eapi_drv.h

$(OBJDIR)/$(EAPI_PFX)%.o: %.c
	$(CC) -c -o $@ $(CFLAGS) -I$(ERL_C_INCLUDE_DIR) $<
