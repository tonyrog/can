EAPI_DIR = ../../eapi
include $(EAPI_DIR)/make/eapi_drv.mk

CFLAGS += -m32 -I $(EAPI_DIR)/include 
LDFLAGS += 


CAN_SOCK_DRV = $(LIBDIR)/$(WORDSIZE)/libusb_drv.so
CAN_SOCK_DRV_OBJS = \
        $(OBJDIR)/$(WORDSIZE)/libusb_api.o \
        $(OBJDIR)/$(WORDSIZE)/libusb_drv_impl.o
EAPI_LIB = $(EAPI_DIR)/lib/$(TYPE)/$(WORDSIZE)/eapi_drv.a

all:    all_32 all_64

all_32: debug_32 release_32

debug_32:
        $(MAKE) driver TYPE=debug   WORDSIZE=32

release_32:
        $(MAKE) driver TYPE=release WORDSIZE=32

all_64: debug_64 release_64

debug_64:
        $(MAKE) driver TYPE=debug   WORDSIZE=64

release_64:
        $(MAKE) driver TYPE=release WORDSIZE=64

clean: 
        $(MAKE) clean_internal TYPE=release WORDSIZE=32
        $(MAKE) clean_internal TYPE=debug   WORDSIZE=32
        $(MAKE) clean_internal TYPE=release WORDSIZE=64
        $(MAKE) clean_internal TYPE=debug   WORDSIZE=64

debug:
        $(MAKE) driver TYPE=debug WORDSIZE=32

clean_debug:
        $(MAKE) clean_internal TYPE=debug WORDSIZE=32

release:
        $(MAKE) driver TYPE=release

driver: $(CAN_SOCK_DRV)

depend:

clean_internal:
        -rm -f $(OBJDIR)/$(WORDSIZE)/*.o

$(CAN_SOCK_DRV): $(CAN_SOCK_DRV_OBJS)
        $(LD_SHARED) -o $@ $(CAN_SOCK_DRV_OBJS) $(EAPI_LIB) $(LDFLAGS)

$(OBJDIR)/$(WORDSIZE)/libusb_api.o: $(EAPI_DIR)/include/eapi_drv.h

$(OBJDIR)/$(WORDSIZE)/libusb_drv_impl.o: $(EAPI_DIR)/include/eapi_drv.h

$(OBJDIR)/$(WORDSIZE)/%.o: %.c
        $(CC) -c -o $@ $(CFLAGS) -I$(ERL_C_INCLUDE_DIR) $<
