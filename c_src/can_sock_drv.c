/*
 * can_sock_drv.c
 *
 *   Unix CAN socket driver
 *
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>

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

#include "eapi_drv.h"
#include "can_sock.h"

static ErlDrvEntry can_sock_drv_entry;

typedef struct _can_ctx_t
{
    int   s;   // Can socket
    int   b;   // bound interface index
} can_ctx_t;

// Push can frame if device is busy
typedef struct _x_can_frame
{
    int i;
    struct can_frame f;
} x_can_frame;


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

static void can_sock_init(ErlDrvData d)
{
    eapi_ctx_t* ctx = (eapi_ctx_t*) d;
    can_ctx_t *dctx;

    dctx = (can_ctx_t*) driver_alloc(sizeof (can_ctx_t));
    dctx->s = socket(PF_CAN, SOCK_RAW, CAN_RAW);
    dctx->b = 0;
    ctx->user_data = dctx;
}

static void can_sock_finish(ErlDrvData d)
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
		     can_sock_finish);
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
	ifr.ifr_ifindex = index;
	if (ioctl(dctx->s, SIOCGIFNAME, &ifr) < 0)
	    put_error(c_out, "enoent"); // FIXME: posixname
	else {
	    cbuf_put_tuple_begin(c_out, 2);
	    cbuf_put_tag_ok(c_out);
	    cbuf_put_string(c_out, ifr.ifr_name, strlen(ifr.ifr_name));
	    cbuf_put_tuple_end(c_out, 2);
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
	put_error(c_out, erl_errno_id(errno));
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
	    put_error(c_out, erl_errno_id(errno));
	else {
	    // At least on bind is needed (even for any)
	    driver_select(ctx->port,(ErlDrvEvent)dctx->s,ERL_DRV_READ,1);
	    dctx->b = index;
	    put_ok(c_out);
	}
    }
}

int send_frame(can_ctx_t* dctx, x_can_frame* frame)
{
    if (frame->i == 0)
	return write(dctx->s, &frame->f, sizeof(struct can_frame));
    else {
	struct sockaddr_can addr;
	addr.can_ifindex = frame->i;
	addr.can_family = AF_CAN;
	return sendto(dctx->s, &frame->f, sizeof(struct can_frame),
		      0, (struct sockaddr*)&addr, sizeof(addr));
    }
}    

void can_sock_drv_impl_send(eapi_ctx_t* ctx,cbuf_t* c_out,
			    struct can_frame_t* frame)
{
    can_ctx_t* dctx = (can_ctx_t*) ctx->user_data;
    x_can_frame xframe;
    size_t len = frame->data.len; // argument length

    if (len > 8)
	put_error(c_out, "badarg");
    else if ((frame->intf == 0) && (dctx->b == 0))
	put_error(c_out, erl_errno_id(ENOTCONN));
    else {
	uint32_t id = frame->id;
	uint8_t* ptr = (uint8_t*)frame->data.bin->orig_bytes+frame->data.offset;
	int i;

	if (frame->ext) id |= CAN_EFF_FLAG;
	if (frame->rtr) id |= CAN_RTR_FLAG;
	xframe.i = frame->intf;
	xframe.f.can_id = id;
	xframe.f.can_dlc = frame->len & 0xF;
	memcpy(xframe.f.data, ptr, len);
	for (i = len; i < 8; i++)
	    xframe.f.data[i] = 0;

	if (driver_sizeq(ctx->port) == 0) {
	    int r = send_frame(dctx, &xframe);
	    if ((r < 0) && (errno == EAGAIN)) {
		driver_enq(ctx->port, (char*)&xframe, sizeof(xframe));
		driver_select(ctx->port,(ErlDrvEvent)dctx->s,ERL_DRV_WRITE,1);
		put_ok(c_out);
	    }
	    else
		put_error(c_out, erl_errno_id(errno));
	}
	else {
	    driver_enq(ctx->port, (char*) &xframe, sizeof(xframe));
	    put_ok(c_out);
	}
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
    struct can_frame frame;
    size_t len;

    if (recvfrom(dctx->s, &frame, sizeof(frame),
		 0, (struct sockaddr*) &addr, &len) == sizeof(frame)) {
	cbuf_t     reply;
	cbuf_init(&reply, 0, 0, 0, CBUF_FLAG_BINARY | CBUF_FLAG_PUT_TRM, 0);
	cbuf_put_begin(&reply);

	cbuf_put_tuple_begin(&reply, 3);
	cbuf_put_atom(&reply, "data");
	trm_put_2(&reply, ERL_DRV_PORT, (ErlDrvTermData)ctx->port); // special!
	cbuf_put_tuple_begin(&reply, 8);
	cbuf_put_atom(&reply, "can_frame");
	if (frame.can_id & CAN_EFF_FLAG)
	    cbuf_put_uint32(&reply, (frame.can_id &  CAN_EFF_MASK));
	else
	    cbuf_put_uint32(&reply, (frame.can_id &  CAN_SFF_MASK));
	cbuf_put_boolean(&reply, frame.can_id & CAN_RTR_FLAG);
	cbuf_put_boolean(&reply, frame.can_id & CAN_EFF_FLAG);
	cbuf_put_int32(&reply, addr.can_ifindex);
	cbuf_put_int8(&reply, frame.can_dlc);
	cbuf_put_binary(&reply, frame.data, (frame.can_dlc & 0xf));
	cbuf_put_int32(&reply, 0); // fixme timestamp
	cbuf_put_tuple_end(&reply, 8);
	cbuf_put_tuple_end(&reply, 3);
	driver_output_term(ctx->port, (ErlDrvTermData*)reply.v[0].base,
			   reply.v[0].len/sizeof(ErlDrvTermData));
	cbuf_final(&reply);
    }
}


static void can_sock_ready_output(ErlDrvData data, ErlDrvEvent event)
{
    (void) event;
    eapi_ctx_t* ctx = (eapi_ctx_t*) data;
    can_ctx_t* dctx = (can_ctx_t*) ctx->user_data;
    ErlIOVec ev;
    int n;

    if ((n=driver_peekqv(ctx->port, &ev)) >= (int)sizeof(x_can_frame)) {
	x_can_frame xframe;
	int r;

	driver_vec_to_buf(&ev, (char*)&xframe, sizeof(xframe));
	r = send_frame(dctx, &xframe);
	if ((r < 0) && (errno == EAGAIN))
	    return;
	if (r < (int)sizeof(xframe))
	    return;
	driver_deq(ctx->port, sizeof(xframe));
	n -= r;
    }
    if (n == 0)
	driver_select(ctx->port,(ErlDrvEvent)dctx->s,ERL_DRV_WRITE,0);
}
