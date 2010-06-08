/*
 * can_sock_drv.c
 *
 *   Windows/Unix CAN socket driver
 *
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <unistd.h>
#include <string.h>

#include <sys/types.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <net/if.h>
 
#include <linux/can.h>
#include <linux/can/raw.h>

#ifndef PF_CAN
#define PF_CAN 29
#endif
 
#ifndef AF_CAN
#define AF_CAN PF_CAN
#endif

#ifdef DEBUG
// #define CBUF_DBG(buf,msg) cbuf_print((buf),(msg))
#define CBUF_DBG(buf,msg)
#define DBG(...) sl_emit_error(__FILE__,__LINE__,__VA_ARGS__)
#else
#define CBUF_DBG(buf,msg)
#define DBG(...)
#endif

#include "eapi_drv.h"


#define CAN_SOCK_CONNECT      1
#define CAN_SOCK_DISCONNECT   2
#define CAN_SOCK_OPEN         3
#define CAN_SOCK_CLOSE        4

#define REPLY_OK     1
#define REPLY_ERROR  2
#define REPLY_EVENT  3

typedef struct _can_ctx_t
{
    int   s;   // Can socket
    int   b;   // bound interface index
} can_ctx_t;

static void can_sock_ready_input(ErlDrvData drv_data, ErlDrvEvent event); 
static void can_sock_ready_output(ErlDrvData drv_data, ErlDrvEvent event);

#ifdef DEBUG
static void can_sock_emit_error(char* file, int line, ...);

static void can_sock_emit_error(char* file, int line, ...)
{
    va_list ap;
    char* fmt;

    va_start(ap, line);
    fmt = va_arg(ap, char*);

    fprintf(stderr, "%s:%d: ", file, line); 
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\r\n");
    va_end(ap);
}
#endif


// Write OK
static inline void put_ok(cbuf_t* out)
{
    cbuf_put_tag_ok(out);
}

// Write ERROR,ATOM,String
static inline void put_error(cbuf_t* out, char* err)
{
    cbuf_put_tuple_begin(out, 2);
    cbuf_put_tag_error(out);
    cbuf_put_atom(out, err);
    cbuf_put_tuple_end(out, 2);
}

// Write EVENT,event-ref:32
static inline void put_i32(cbuf_t* out, int32_t v)
{
    cbuf_put_tuple_begin(out, 2);
    cbuf_put_tag_ok(out);
    cbuf_put_int32(out, v);
    cbuf_put_tuple_end(out, 2);
}

static void can_sock_init(ErlDrvPort port)
{
    eapi_ctx_t* ctx = (eapi_ctx_t*) d;
    can_ctx_t *dctx;
    (void) buf;

    dctx = (can_ctx_t*) driver_alloc(sizeof (can_ctx_t));
    dctx->s = socket(PF_CAN, SOCK_RAW, CAN_RAW);
    dctx->b = 0;
    ctx->user_data = dctx;
}

static void can_sock_final(can_ctx_t* ctx)
{
    eapi_ctx_t* ctx = (eapi_ctx_t*) d;
    can_ctx_t* dctx = (can_ctx_t*) ctx->user_data;

    if (dctx->s > 0) {
	driver_select(ctx->port, (ErlDrvEvent)dctx->s,
		      ERL_DRV_READ|ERL_DRV_WRITE, 0);
	close(dctx->s);
	dctx->s = -1;
    }
    free(dctx);
}

DRIVER_INIT(can_sock_drv)
{
    eapi_driver_init(&can_sock_drv_entry,
		     can_sock_init,
		     can_sock_final);
    can_sock_drv_entry.driver_name = "can_sock_drv";
    can_sock_drv_entry.ready_input = can_sock_ready_input;
    can_sock_drv_entry.ready_output = can_sock_ready_output;
    return (ErlDrvEntry*) &can_sock_drv_entry;
}

void can_sock_drv_impl_ifname(eapi_ctx_t* ctx,cbuf_t* c_out,int index)
{
    can_ctx_t* dctx = (can_ctx_t*) ctx->user_data;
    struct ifreq ifr;

    if (index <= 0)
	put_error(c_out, "badarg"); // FIXME: posixname	
    else {
	ifr.ift_ifindex = index;
	if (ioctl(dctx->s, SIOCGIFNAME, &ifr) < 0)
	    put_error(c_out, "enoent"); // FIXME: posixname
	else {
	    cbuf_put_tuple_begin(c_out, 2);
	    cbuf_put_tag_ok(c_out);
	    cbuf_put_string(c_out, ifr.ifr_name);
	    cbuf_put_tuple_end(out, 2);
	}
    }
}

void can_sock_drv_impl_ifindex(eapi_ctx_t* ctx,cbuf_t* c_out,eapi_string_t name)
{
    can_ctx_t* dctx = (can_ctx_t*) ctx->user_data;
    struct ifreq ifr;
    size_t len = sizeof(ifr.ifr_name) - 1;
    if (name.len < len)
	len = name.len;
    memcpy(ifr.ifr_name, name.buf, len);
    ifr.ifr_name[len] = '\0';
    if (ioctl(dctx->s, SIOCGIFINDEX, &ifr) < 0)
	put_error(c_out, "enoent"); // FIXME: posixname
    else
	put_i32(c_out, ifr.ifr_ifindex); // return index
}


void can_sock_drv_impl_bind(eapi_ctx_t* ctx,cbuf_t* c_out,int index)
{
    can_ctx_t* dctx = (can_ctx_t*) ctx->user_data;
    struct sockaddr_can addr;

    if (index < 0)
	put_error(c_out, "badarg"); // FIXME: posixname	
    else {
	addr.can_family = AF_CAN;
	addr.can_ifindex = index;
	if (bind(dctx->s, (struct sockaddr *)&addr, sizeof(addr)) < 0)
	    put_error(c_out, "badarg"); // FIXME: posixname
	else {
	    dctx->b = index;
	    put_ok(c_out);
	}
    }
}

void can_sock_drv_impl_send(eapi_ctx_t* ctx,cbuf_t* c_out,
			    struct can_frame_t* frame)
{
    can_ctx_t* dctx = (can_ctx_t*) ctx->user_data;
    struct can_frame cframe;
    size_t len = frame->data.len; // argument length

    if (len > 8)
	put_error(c_out, "badarg");
    else if ((frame->intf == 0) && (dctx->b == 0))
	put_error(c_out, "enobind");
    else {
	uint32_t id = frame->id;
	uint8_t* ptr = frame->data.bin->orig_bytes+frame->data.offset;
	if (frame->ext) id |= CAN_EFF_FLAG;
	if (frame->rtr) id |= CAN_RTR_FLAG;
	cframe.can_id = id;
	cframe.can_dlc = frame->len & 0xF;
	memcpy(cframe.data, ptr, len);
	for (i = len; i < 8; i++)
	    cframe.data[i] = 0;
    }
    // check the driver-q if non empty push the can frame 
    // and send the first can_frame
    // otherwise try send it
    // pushed frames must include index!!!
    if (frame->intf == 0) {
	if (write(dctx->s, &cframe, sizeof(cframe)) != sizeof(cframe))
	    put_error(c_out, "send_error"); // POSIX fixme
	else 
	    put_ok(c_out);
    }
    else {
	struct sockaddr_can addr;
	addr.can_ifindex = frame->index;
	addr.can_family = AF_CAN;
	if (sendto(dctx->s, &cframe, sizeof(cframe),
		   0, (struct sockaddr*)&addr, sizeof(addr)) != sizeof(cframe))
	    put_error(c_out, "send_error"); // POSIX fixme
	else 
	    put_ok(c_out);
    }
}

// Read a can_frame from the socket
// and send it to Erlang as a preformatted #can_frame {} data
//
static void can_sock_ready_input(ErlDrvData data, ErlDrvEvent event)
{
    (void) event;
    eapi_ctx_t* ctx = (eapi_ctx_t*) data;
    can_ctx_t* dctx = (can_ctx_t*) ctx->user_data;
    struct sockaddr_can addr;
    struct can_frame cframe;
    size_t len;

    if (recvfrom(dctx->s, &cframe, sizeof(cframe),
		 0, (struct sockaddr*) &addr, &len) == sizeof(cframe)) {
	/* construct the erlang can_frame event */
    }
}


static void can_sock_ready_output(ErlDrvData data, ErlDrvEvent event)
{
    can_ctx_t* ctx = (can_ctx_t*) data;
    // Check the ioq & send new frame when possible

}
