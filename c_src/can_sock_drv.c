/**** BEGIN COPYRIGHT ********************************************************
 *
 * Copyright (C) 2007 - 2012, Rogvall Invest AB, <tony@rogvall.se>
 *
 * This software is licensed as described in the file COPYRIGHT, which
 * you should have received as part of this distribution. The terms
 * are also available at http://www.rogvall.se/docs/copyright.txt.
 *
 * You may opt to use, copy, modify, merge, publish, distribute and/or sell
 * copies of the Software, and permit persons to whom the Software is
 * furnished to do so, under the terms of the COPYRIGHT file.
 *
 * This software is distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY
 * KIND, either express or implied.
 *
 **** END COPYRIGHT **********************************************************/

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <stdint.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>

#include <sys/types.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <net/if.h>

// CROSS COMPILE
// when missing can.h files add symbolic links to host ...
// cd /usr/local/arm/arm-2007q1/arm-none-linux-gnueabi/libc/usr/include/linux
// sudo ln -s /usr/include/linux/can.h
// sudo ln -s /usr/include/can
//

#include <linux/can.h>
#include <linux/can/raw.h>

#ifndef PF_CAN
#define PF_CAN 29
#endif
 
#ifndef AF_CAN
#define AF_CAN PF_CAN
#endif

#define ATOM(NAME) am_ ## NAME
#define INIT_ATOM(NAME) am_ ## NAME = driver_mk_atom(#NAME)

#define CTL_OK     0
#define CTL_ERROR  1
#define CTL_UINT32 2
#define CTL_STRING 3

#include "erl_driver.h"

#define LOG_DEBUG     7
#define LOG_INFO      6
#define LOG_NOTICE    5
#define LOG_WARNING   4
#define LOG_ERROR     3
#define LOG_CRITICAL  2
#define LOG_ALERT     1
#define LOG_EMERGENCY 0
#define LOG_NONE     -1

#ifndef LOG_DEFAULT
#define LOG_DEFAULT LOG_DEBUG // LOG_NONE
#endif

#define LOG(level,file,line,args...) do { \
	if (((level) == LOG_EMERGENCY) ||				\
	    ((debug_level >= 0) && ((level) <= debug_level))) {		\
	    emit_error((level),(file),(line),args);			\
	}								\
    } while(0)
	
#define DEBUGF(args...) LOG(LOG_DEBUG,__FILE__,__LINE__,args)


// Hack to handle R15 driver used with pre R15 driver
#if ERL_DRV_EXTENDED_MAJOR_VERSION == 1
typedef int  ErlDrvSizeT;
typedef int  ErlDrvSSizeT;
#endif

#if (ERL_DRV_EXTENDED_MAJOR_VERSION > 2) || ((ERL_DRV_EXTENDED_MAJOR_VERSION == 2) && (ERL_DRV_EXTENDED_MINOR_VERSION >= 1))
#define OUTPUT_TERM(thr, message, len) erl_drv_output_term((thr)->dport,(message),(len))
#define SEND_TERM(thr, to, message, len) erl_drv_send_term((thr)->dport,(to),(message),(len))

#else
#define OUTPUT_TERM(thr, message, len) driver_output_term((thr)->port,(message),(len))
#define SEND_TERM(thr, to, message, len) driver_send_term((thr)->port,(to),(message),(len))
#endif

typedef struct _drv_ctx_t
{
    ErlDrvPort     port;        // port controling the thread
    ErlDrvTermData dport;       // the port identifier as DriverTermData
    ErlDrvTermData owner;       // owner process pid 
    ErlDrvEvent    sock;        // Can socket
    int   intf;                 // bound interface index
    int   mtu;                  // can MTU
    int   fdon;                 // fd is on
} drv_ctx_t;

#define CAN_FD_FLAG 0x0001

// Push can frame if device is busy
typedef struct _x_can_frame
{
    int i;
    int flags;
    struct canfd_frame f;
} x_can_frame;

#define CAN_SOCK_DRV_CMD_IFNAME 1
#define CAN_SOCK_DRV_CMD_IFINDEX 2
#define CAN_SOCK_DRV_CMD_SET_ERROR_FILTER 3
#define CAN_SOCK_DRV_CMD_SET_LOOPBACK 4
#define CAN_SOCK_DRV_CMD_RECV_OWN_MESSAGES 5
#define CAN_SOCK_DRV_CMD_BIND 6
#define CAN_SOCK_DRV_CMD_SEND 7
#define CAN_SOCK_DRV_CMD_SET_FILTER 8
#define CAN_SOCK_DRV_CMD_SET_FD_FRAMES 9
#define CAN_SOCK_DRV_CMD_GET_MTU 10
#define CAN_SOCK_DRV_CMD_SEND_FD 11

#define MAX_FILTER 256  // fixme

#define INT_EVENT(e) ((int)((long)(e)))

static int debug_level = LOG_NONE;
    
static void emit_error(int level, char* file, int line, ...);

static void emit_error(int level, char* file, int line, ...)
{
    va_list ap;
    char* fmt;

    if ((level == LOG_EMERGENCY) ||
 	((debug_level >= 0) && (level <= debug_level))) {
	int save_errno = errno;
	va_start(ap, line);
	fmt = va_arg(ap, char*);
	fprintf(stderr, "%s:%d: ", file, line); 
	vfprintf(stderr, fmt, ap);
	fprintf(stderr, "\r\n");
	va_end(ap);
	errno = save_errno;
    }
}

static inline uint32_t get_uint32(char* ptr)
{
    uint8_t* p = (uint8_t*) ptr;
    uint32_t value = (p[0]<<24) | (p[1]<<16) | (p[2]<<8) | (p[3]<<0);
    return value;
}

static inline uint16_t get_uint16(char* ptr)
{
    uint8_t* p = (uint8_t*) ptr;
    uint16_t value = (p[0]<<8) | (p[1]<<0);
    return value;
}

static inline uint8_t get_uint8(char* ptr)
{
    return ((uint8_t*)ptr)[0];
}

static inline void put_uint16(char* ptr, uint16_t v)
{
    uint8_t* p = (uint8_t*) ptr;
    p[0] = v>>8;
    p[1] = v;
}

static inline void put_uint32(char* ptr, uint32_t v)
{
    uint8_t* p = (uint8_t*) ptr;
    p[0] = v>>24;
    p[1] = v>>16;
    p[2] = v>>8;
    p[3] = v;
}

static int  can_sock_drv_init(void);
static void can_sock_drv_finish(void);
static void can_sock_drv_stop(ErlDrvData);
static void can_sock_drv_output(ErlDrvData, char*, ErlDrvSizeT);
static void can_sock_drv_ready_input(ErlDrvData, ErlDrvEvent);
static void can_sock_drv_ready_output(ErlDrvData data, ErlDrvEvent event);
static ErlDrvData can_sock_drv_start(ErlDrvPort, char* command);
static ErlDrvSSizeT can_sock_drv_ctl(ErlDrvData,unsigned int,char*,ErlDrvSizeT,char**, ErlDrvSizeT);
static void can_sock_drv_timeout(ErlDrvData);
static void can_sock_drv_stop_select(ErlDrvEvent, void*);

static ErlDrvEntry can_sock_drv_entry;

static ErlDrvTermData am_ok;
static ErlDrvTermData am_error;
static ErlDrvTermData am_can_frame;
static ErlDrvTermData am_canfd_frame;
static ErlDrvTermData am_data;

/* general control reply function */
static ErlDrvSSizeT ctl_reply(int rep, char* buf, ErlDrvSizeT len,
			      char** rbuf, ErlDrvSizeT rsize)
{
    char* ptr;

    if ((len+1) > rsize) {
	ErlDrvBinary* bin;
	if ((bin = driver_alloc_binary(len+1)) == NULL)
	    return -1;
	ptr = bin->orig_bytes;
	*rbuf = (char*) bin;
    }
    else
	ptr = *rbuf;
    *ptr++ = rep;
    memcpy(ptr, buf, len);
    return len+1;
}

static ErlDrvSSizeT ctl_reply_ok(char** rbuf, ErlDrvSizeT rsize)
{
    return ctl_reply(CTL_OK,"",0,rbuf,rsize);
}

static ErlDrvSSizeT ctl_reply_error(int err, char** rbuf, ErlDrvSizeT rsize)
{
    char* errid = erl_errno_id(err);
    ErlDrvSizeT len = strlen(errid);
    return ctl_reply(CTL_ERROR,errid,len,rbuf,rsize);
}

static ErlDrvSSizeT ctl_reply_u32(uint32_t v, char** rbuf, ErlDrvSizeT rsize)
{
    char buf[4];
    put_uint32(buf, v);
    return ctl_reply(CTL_UINT32,buf,sizeof(buf),rbuf,rsize);
}

static int can_sock_drv_init(void)
{
    debug_level = LOG_DEFAULT;
    DEBUGF("can_sock_drv_init");

    INIT_ATOM(ok);
    INIT_ATOM(error);
    INIT_ATOM(can_frame);
    INIT_ATOM(canfd_frame);
    INIT_ATOM(data);

    debug_level = LOG_DEFAULT;
    return 0;
}

static void can_sock_drv_finish(void)
{
    // cleanup global stuff!
}

static ErlDrvData can_sock_drv_start(ErlDrvPort port, char* command)
{
    (void) command;
    drv_ctx_t* ctx = NULL;
    int s;

    if ((s = socket(PF_CAN, SOCK_RAW|SOCK_NONBLOCK, CAN_RAW)) < 0)
	return ERL_DRV_ERROR_ERRNO;

    set_port_control_flags(port, PORT_CONTROL_FLAG_BINARY);

    ctx = driver_alloc(sizeof(drv_ctx_t));
    memset(ctx, 0, sizeof(drv_ctx_t));
    ctx->port = port;
    ctx->dport = driver_mk_port(port);
    ctx->owner = driver_connected(port);
    ctx->sock = (ErlDrvEvent)((long)s);
    ctx->intf = 0;
    ctx->mtu  = CAN_MTU;
    ctx->fdon = 0;
    return (ErlDrvData) ctx;
}

static void can_sock_drv_stop(ErlDrvData d)
{
    drv_ctx_t* ctx = (drv_ctx_t*) d;

    DEBUGF("can_sock_drv_stop: called");
    driver_select(ctx->port,ctx->sock,ERL_DRV_USE,0);
    driver_free(ctx);
}

static int send_frame(drv_ctx_t* ctx, x_can_frame* frame)
{
    int len = CAN_MTU;

    if ((frame->flags & CAN_FD_FLAG) && ctx->fdon)
	len = ctx->mtu;
    if (frame->i == 0)
	return write(INT_EVENT(ctx->sock), &frame->f, len);
    else {
	struct sockaddr_can addr;
	addr.can_ifindex = frame->i;
	addr.can_family = AF_CAN;
	return sendto(INT_EVENT(ctx->sock), &frame->f, len,
		      0, (struct sockaddr*)&addr, sizeof(addr));
    }
}    

static char* format_command(int cmd)
{
    switch(cmd) {
    case CAN_SOCK_DRV_CMD_IFNAME: return "ifname";
    case CAN_SOCK_DRV_CMD_IFINDEX: return "ifindex";
    case CAN_SOCK_DRV_CMD_SET_ERROR_FILTER: return "set_error_filter";
    case CAN_SOCK_DRV_CMD_SET_LOOPBACK: return "set_loopback";
    case CAN_SOCK_DRV_CMD_RECV_OWN_MESSAGES: return "revc_own_messages";
    case CAN_SOCK_DRV_CMD_BIND:  return "bind";
    case CAN_SOCK_DRV_CMD_SEND:  return "send";
    case CAN_SOCK_DRV_CMD_SEND_FD:  return "sendfd";
    case CAN_SOCK_DRV_CMD_SET_FILTER: return "set_filter";
    case CAN_SOCK_DRV_CMD_SET_FD_FRAMES: return "set_fd_frames";
    case CAN_SOCK_DRV_CMD_GET_MTU: return "get_mtu";
    default: return "????";
    }
}

static ErlDrvSSizeT can_sock_drv_ctl(ErlDrvData d, 
				     unsigned int cmd, char* buf,
				     ErlDrvSizeT len,
				     char** rbuf, ErlDrvSizeT rsize)
{
    drv_ctx_t* ctx = (drv_ctx_t*) d;

    DEBUGF("ctl: cmd=%u(%s), len=%d", 
	   cmd, format_command(cmd), len);

    switch(cmd) {
    case CAN_SOCK_DRV_CMD_IFNAME: {
	int index;
	struct ifreq ifr;

	if (len != 4)
	    return ctl_reply_error(EINVAL, rbuf, rsize);
	if ((index = (int) get_uint32(buf)) <= 0)
	    return ctl_reply_error(EINVAL, rbuf, rsize);
	else {
	    ifr.ifr_ifindex = index;
	    if (ioctl(INT_EVENT(ctx->sock), SIOCGIFNAME, &ifr) < 0)
		return ctl_reply_error(errno, rbuf, rsize);
	    else 
		return ctl_reply(CTL_STRING,ifr.ifr_name, strlen(ifr.ifr_name),
				 rbuf, rsize);
	}
    }

    case CAN_SOCK_DRV_CMD_IFINDEX: {
	struct ifreq ifr;

	if (len == 0)
	    return ctl_reply_error(EINVAL, rbuf, rsize);
	if (len >= sizeof(ifr.ifr_name))
	    return ctl_reply_error(EINVAL, rbuf, rsize);
	memcpy(ifr.ifr_name, buf, len);
	ifr.ifr_name[len] = '\0';
	if (ioctl(INT_EVENT(ctx->sock), SIOCGIFINDEX, &ifr) < 0)
	    return ctl_reply_error(errno, rbuf, rsize);
	else
	    return ctl_reply_u32(ifr.ifr_ifindex, rbuf, rsize);
    }

    case CAN_SOCK_DRV_CMD_SET_ERROR_FILTER: {
	can_err_mask_t m;
	int r;

	if (len != 4)
	    return ctl_reply_error(EINVAL, rbuf, rsize);
	m = (can_err_mask_t) get_uint32(buf);
	r = setsockopt(INT_EVENT(ctx->sock),
		       SOL_CAN_RAW,CAN_RAW_ERR_FILTER,&m,sizeof(m));
	if (r < 0)
	    return ctl_reply_error(errno, rbuf, rsize);
	else
	    return ctl_reply_ok(rbuf, rsize);
    }

    case CAN_SOCK_DRV_CMD_SET_FILTER: {
	struct can_filter rfilter[MAX_FILTER];
	char* ptr = buf;
	int r, i;
	size_t n;

	if ((len & 7) != 0) 
	    return ctl_reply_error(EINVAL, rbuf, rsize);
	n = len >> 3;
	if (n > MAX_FILTER)
	    return ctl_reply_error(EINVAL, rbuf, rsize);
	for (i = 0; i < n; i++) {
	    rfilter[i].can_id   = get_uint32(ptr);
	    rfilter[i].can_mask = get_uint32(ptr+4);
	    ptr += 8;
	}
	r = setsockopt(INT_EVENT(ctx->sock),
		       SOL_CAN_RAW,CAN_RAW_FILTER,&rfilter,len);
	if (r < 0)
	    return ctl_reply_error(errno, rbuf, rsize);
	else
	    return ctl_reply_ok(rbuf, rsize);
    }

    case CAN_SOCK_DRV_CMD_SET_LOOPBACK: {
	int value;
	int r;

	if (len != 1)
	    return ctl_reply_error(EINVAL, rbuf, rsize);
	value = (buf[0] != 0);
	r=setsockopt(INT_EVENT(ctx->sock),
		     SOL_CAN_RAW,CAN_RAW_LOOPBACK,&value,sizeof(value));
	if (r < 0)
	    return ctl_reply_error(errno, rbuf, rsize);
	else
	    return ctl_reply_ok(rbuf, rsize);
    }

    case CAN_SOCK_DRV_CMD_SET_FD_FRAMES: {
	int value;
	int r;

	if (len != 1)
	    return ctl_reply_error(EINVAL, rbuf, rsize);
	value = (buf[0] != 0);
	r=setsockopt(INT_EVENT(ctx->sock),
		     SOL_CAN_RAW,CAN_RAW_FD_FRAMES,&value,sizeof(value));
	if (r < 0)
	    return ctl_reply_error(errno, rbuf, rsize);
	ctx->fdon = value;
	return ctl_reply_ok(rbuf, rsize);
    }	

    case CAN_SOCK_DRV_CMD_RECV_OWN_MESSAGES: {
	int value; 
	int r;
	if (len != 1)
	    return ctl_reply_error(EINVAL, rbuf, rsize);
	value = (buf[0] != 0);
	r=setsockopt(INT_EVENT(ctx->sock),
		     SOL_CAN_RAW,CAN_RAW_RECV_OWN_MSGS,
		     &value,sizeof(value));
	if (r < 0)
	    return ctl_reply_error(errno, rbuf, rsize);
	else
	    return ctl_reply_ok(rbuf, rsize);
    }

    case CAN_SOCK_DRV_CMD_BIND: {
	int index;
	struct sockaddr_can addr;
	struct ifreq ifreq;
	
	if (len != 4)
	    return ctl_reply_error(EINVAL, rbuf, rsize);
	if ((index = (int) get_uint32(buf)) <= 0)
	    return ctl_reply_error(EINVAL, rbuf, rsize);
	addr.can_family = AF_CAN;
	addr.can_ifindex = index;
	if (bind(INT_EVENT(ctx->sock),
		 (struct sockaddr *)&addr, sizeof(addr)) < 0)
	    return ctl_reply_error(errno, rbuf, rsize);
	ctx->intf = index;
	if (ioctl(INT_EVENT(ctx->sock), SIOCGIFMTU, (char *)&ifreq) >= 0) {
	    ctx->mtu = ifreq.ifr_mtu;
	    DEBUGF("detected MTU size = %d", ctx->mtu);
	}
	driver_select(ctx->port,ctx->sock,ERL_DRV_READ,1);
	return ctl_reply_ok(rbuf, rsize);
    }

    case CAN_SOCK_DRV_CMD_SEND_FD:
    case CAN_SOCK_DRV_CMD_SEND: {
	int       index;
	uint32_t  id;
	uint8_t   flen;
	char*     fptr;
	//int     intf;
	//int     ts;
        int       m;
	x_can_frame xframe;

	if ((m = (len - 17)) < 0)
	    return ctl_reply_error(EINVAL, rbuf, rsize);
//	if ((m != 8) && (m != 64))
//	    return ctl_reply_error(EINVAL, rbuf, rsize);
	index = (int) get_uint32(buf);
	id    = get_uint32(buf+4);
	// intf  = (int) get_uint32(buf+8);
	// ts    = (int) get_uint32(buf+12);	
	flen   = get_uint8(buf+16);
	fptr   = buf+17;
	
	if ((index == 0) && (ctx->intf == 0))
	    return ctl_reply_error(ENOTCONN, rbuf, rsize);
	else {
	    memset(&xframe.f, 0, sizeof(xframe.f));
	    xframe.i = index;
	    xframe.flags = (cmd==CAN_SOCK_DRV_CMD_SEND_FD) ? CAN_FD_FLAG : 0;
	    xframe.f.can_id = id;
	    xframe.f.len = flen;
	    memcpy(xframe.f.data, fptr, m);
	    
	    // FIXME: drop packets when full! (deq old, enq new)
	    if (driver_sizeq(ctx->port) == 0) {
		int r = send_frame(ctx, &xframe);
		if ((r < 0) && (errno == EAGAIN)) {
		    driver_enq(ctx->port, (char*)&xframe, sizeof(xframe));
		    DEBUGF("enq frame size=%ld",  driver_sizeq(ctx->port));
		    driver_select(ctx->port,ctx->sock,ERL_DRV_WRITE,1);
		    return ctl_reply_ok(rbuf, rsize);
		}
		else if (r < 0)
		    return ctl_reply_error(errno, rbuf, rsize);
	    }
	    else {
		driver_enq(ctx->port, (char*) &xframe, sizeof(xframe));
		DEBUGF("enq frame size=%ld",  driver_sizeq(ctx->port));		
	    }
	    return ctl_reply_ok(rbuf, rsize);
	}
    }
    case CAN_SOCK_DRV_CMD_GET_MTU: { // get mtu and refresh!
	struct ifreq ifreq;
	if (ioctl(INT_EVENT(ctx->sock), SIOCGIFMTU, (char *)&ifreq) >= 0) {
	    ctx->mtu = ifreq.ifr_mtu;
	    DEBUGF("detected MTU size = %d", ctx->mtu);
	}
	return ctl_reply_u32(ctx->mtu, rbuf, rsize);
    }
	
    default:
	return ctl_reply_error(EINVAL, rbuf, rsize);
    }
}

static void can_sock_drv_output(ErlDrvData d, char* buf, ErlDrvSizeT len)
{
    (void) d;
    (void) buf;
    (void) len;
    DEBUGF("output");
}

static void can_sock_drv_ready_input(ErlDrvData d, ErlDrvEvent e)
{
    (void) e;
    drv_ctx_t* ctx = (drv_ctx_t*) d;
    struct sockaddr_can addr;
    struct canfd_frame frame;
    socklen_t len = sizeof(addr);
    int n;

    DEBUGF("ready_input called");

    n = recvfrom(INT_EVENT(ctx->sock), &frame, sizeof(frame), 0,
		 (struct sockaddr*) &addr, &len);
    if ((n == CAN_MTU) || (n == CANFD_MTU)) {
	ErlDrvTermData frame_type = (n == CANFD_MTU) ?
	    ATOM(canfd_frame) : ATOM(can_frame);
	DEBUGF("ready_input got %sframe",
	       (n == CANFD_MTU) ? "FD " : "");
	// Format as: {Port,{data,#can_frame{}}}
	ErlDrvTermData spec[] = {
	    ERL_DRV_PORT, ctx->dport,
	      ERL_DRV_ATOM, ATOM(data),
	      // #can_frame{} | #canfd_frame{}
	          ERL_DRV_ATOM, frame_type,
	          ERL_DRV_UINT, frame.can_id,
	          ERL_DRV_UINT, frame.len, // can_dlc,
	          ERL_DRV_BUF2BINARY, (ErlDrvTermData)frame.data, frame.len,
	          ERL_DRV_INT, addr.can_ifindex,
	          ERL_DRV_INT, -1,  // fixme timestamp, if requested 
	       ERL_DRV_TUPLE, 6,
            ERL_DRV_TUPLE, 2,
	ERL_DRV_TUPLE, 2};

	OUTPUT_TERM(ctx, spec, sizeof(spec) / sizeof(spec[0]));
    }
}

static void can_sock_drv_ready_output(ErlDrvData d, ErlDrvEvent e)
{
    drv_ctx_t* ctx = (drv_ctx_t*) d;
    (void) e;
    DEBUGF("ready_output");
    ErlIOVec ev;
    int n;

    // FIXME: send N frames?
    if ((n=driver_peekqv(ctx->port, &ev)) >= (int)sizeof(x_can_frame)) {
	x_can_frame xframe;
	int r;

	driver_vec_to_buf(&ev, (char*)&xframe, sizeof(xframe));
	r = send_frame(ctx, &xframe);
	if ((r < 0) && (errno == EAGAIN))
	    return;
	if (r < ctx->mtu) {
	    DEBUGF("send frame did not send full MTU");
	    return;
	}
	driver_deq(ctx->port, sizeof(xframe));

	DEBUGF("deq frame size=%ld", driver_sizeq(ctx->port));

	n -= sizeof(xframe);
    }
    if (n == 0)
	driver_select(ctx->port,ctx->sock,ERL_DRV_WRITE,0);
}

// operation timed out
static void can_sock_drv_timeout(ErlDrvData d)
{
    (void) d;
    DEBUGF("can_sock_drv: timeout");
}

static void can_sock_drv_stop_select(ErlDrvEvent event, void* arg)
{
    (void) arg;
    DEBUGF("can_sock_drv: stop_select event=%d", INT_EVENT(event));
    close(INT_EVENT(event));
}


DRIVER_INIT(can_sock_drv)
{
    ErlDrvEntry* ptr = &can_sock_drv_entry;

    DEBUGF("driver_init");

    ptr->init  = can_sock_drv_init;
    ptr->start = can_sock_drv_start;
    ptr->stop  = can_sock_drv_stop;
    ptr->output = can_sock_drv_output;
    ptr->ready_input  = can_sock_drv_ready_input;
    ptr->ready_output = can_sock_drv_ready_output;
    ptr->finish = can_sock_drv_finish;
    ptr->driver_name = "can_sock_drv";
    ptr->control = can_sock_drv_ctl;
    ptr->timeout = can_sock_drv_timeout;
    ptr->extended_marker = ERL_DRV_EXTENDED_MARKER;
    ptr->major_version = ERL_DRV_EXTENDED_MAJOR_VERSION;
    ptr->minor_version = ERL_DRV_EXTENDED_MINOR_VERSION;
    ptr->driver_flags = ERL_DRV_FLAG_USE_PORT_LOCKING;
    ptr->process_exit = 0;
    ptr->stop_select = can_sock_drv_stop_select;
    return ptr;
}

