#ifndef MTBRIDGE_H
#define MTBRIDGE_H

/// One finger contact, normalized to the trackpad surface.
/// x: 0 = left edge, 1 = right edge.  y: 0 = bottom edge, 1 = top edge.
typedef struct {
    int   identifier;   // stable per-finger id for the life of the contact
    int   state;        // MTTouchState; 4 == actively touching
    float x;
    float y;
    float size;         // contact area, roughly 0..1+
} MTBTouch;

/// Called on the multitouch HID thread for every frame that has contacts.
typedef void (*mtb_callback)(const MTBTouch *touches, int count, double timestamp);

/// Physical dimensions of the default trackpad, in millimetres.
/// Returns 0 on success.
int  mtb_surface_size_mm(double *width_mm, double *height_mm);

/// Opens the default trackpad and begins delivering frames. Returns 0 on success.
int  mtb_start(mtb_callback cb);
void mtb_stop(void);

#endif
