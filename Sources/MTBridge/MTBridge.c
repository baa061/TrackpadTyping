// Thin shim over the private MultitouchSupport framework.
//
// We resolve everything with dlopen/dlsym rather than linking against the
// framework: the binary then carries no reference to a private framework,
// which keeps codesigning simple and makes a missing/renamed symbol a
// runtime condition we can report instead of a launch failure.

#include "MTBridge.h"
#include <dlfcn.h>
#include <stddef.h>

typedef struct { float x, y; } MTPointC;
typedef struct { MTPointC pos, vel; } MTReadoutC;

// Layout as published by the framework. Only `normalized`, `identifier`,
// `state` and `size` are used here; the rest is present to keep offsets right.
typedef struct {
    int    frame;
    double timestamp;
    int    identifier, state, fingerID, handID;
    MTReadoutC normalized;
    float  size;
    int    zero1;
    float  angle, majorAxis, minorAxis;
    MTReadoutC absolute;
    int    zero2[2];
    float  zDensity;
} MTTouchC;

typedef void *MTDeviceRef;
typedef int (*MTContactCallback)(MTDeviceRef, MTTouchC *, int, double, int);

static MTDeviceRef (*p_CreateDefault)(void);
static void (*p_RegisterCB)(MTDeviceRef, MTContactCallback);
static void (*p_UnregisterCB)(MTDeviceRef, MTContactCallback);
static void (*p_Start)(MTDeviceRef, int);
static void (*p_Stop)(MTDeviceRef);
static void (*p_Release)(MTDeviceRef);
static void (*p_SurfaceDims)(MTDeviceRef, int *, int *);

static MTDeviceRef  g_device = NULL;
static mtb_callback g_cb     = NULL;

#define MTB_MAX_TOUCHES 32

static int frame_cb(MTDeviceRef dev, MTTouchC *touches, int count, double ts, int frame) {
    (void)dev; (void)frame;
    mtb_callback cb = g_cb;
    if (!cb) return 0;
    if (count > MTB_MAX_TOUCHES) count = MTB_MAX_TOUCHES;

    MTBTouch out[MTB_MAX_TOUCHES];
    for (int i = 0; i < count; i++) {
        out[i].identifier = touches[i].identifier;
        out[i].state      = touches[i].state;
        out[i].x          = touches[i].normalized.pos.x;
        out[i].y          = touches[i].normalized.pos.y;
        out[i].size       = touches[i].size;
    }
    cb(out, count, ts);
    return 0;
}

static int load_symbols(void) {
    static int loaded = 0;
    if (loaded) return p_CreateDefault ? 0 : -1;
    loaded = 1;

    void *h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
                     RTLD_NOW);
    if (!h) return -1;

    *(void **)&p_CreateDefault = dlsym(h, "MTDeviceCreateDefault");
    *(void **)&p_RegisterCB    = dlsym(h, "MTRegisterContactFrameCallback");
    *(void **)&p_UnregisterCB  = dlsym(h, "MTUnregisterContactFrameCallback");
    *(void **)&p_Start         = dlsym(h, "MTDeviceStart");
    *(void **)&p_Stop          = dlsym(h, "MTDeviceStop");
    *(void **)&p_Release       = dlsym(h, "MTDeviceRelease");
    *(void **)&p_SurfaceDims   = dlsym(h, "MTDeviceGetSensorSurfaceDimensions");

    if (!p_CreateDefault || !p_RegisterCB || !p_Start) return -1;
    return 0;
}

int mtb_surface_size_mm(double *width_mm, double *height_mm) {
    if (load_symbols() != 0 || !p_SurfaceDims) return -1;
    MTDeviceRef dev = g_device ? g_device : p_CreateDefault();
    if (!dev) return -1;

    int w = 0, h = 0;
    p_SurfaceDims(dev, &w, &h);          // reported in hundredths of a millimetre
    if (dev != g_device && p_Release) p_Release(dev);
    if (w <= 0 || h <= 0) return -1;

    if (width_mm)  *width_mm  = (double)w / 100.0;
    if (height_mm) *height_mm = (double)h / 100.0;
    return 0;
}

int mtb_start(mtb_callback cb) {
    if (load_symbols() != 0) return -1;
    if (g_device) return 0;

    MTDeviceRef dev = p_CreateDefault();
    if (!dev) return -1;

    g_cb     = cb;
    g_device = dev;
    p_RegisterCB(dev, frame_cb);
    p_Start(dev, 0);
    return 0;
}

void mtb_stop(void) {
    if (!g_device) return;
    if (p_Stop)        p_Stop(g_device);
    if (p_UnregisterCB) p_UnregisterCB(g_device, frame_cb);
    if (p_Release)     p_Release(g_device);
    g_device = NULL;
    g_cb     = NULL;
}
