// Internal reader -> sender frame contract for the touch shim.
//
// touch.cpp owns /dev/input/filtered-touchscreen0 and emits
// one MtState per SYN_REPORT. touch_send.cpp consumes those
// snapshots, diffs against the previous one, builds an
// AAP_TouchEvent and hands it to RaceAap::SendTouchInput.

#ifndef LIBPATCH_BLMJCIAAPA_TOUCH_TOUCH_SEND_H
#define LIBPATCH_BLMJCIAAPA_TOUCH_TOUCH_SEND_H

#include <stdint.h>

#include "../oem/blmjciaapa.h"   // kMaxFingers

// One physical contact's current state inside an evdev frame.
struct Finger {
    int      tracking_id;   // ABS_MT_TRACKING_ID; -1 = slot empty
    uint32_t x;             // ABS_MT_POSITION_X (device units)
    uint32_t y;             // ABS_MT_POSITION_Y (device units)
};

// Snapshot of all slots at one evdev SYN_REPORT.
struct MtState {
    Finger fingers[kMaxFingers];
    int    n_active;
};

// Defined in touch_send.cpp; called by the reader thread on each
// SYN_REPORT with the freshly-built current state.
void touch_on_frame(const MtState &cur);


// Drop any per-session diff/axis state so a fresh session starts clean
// (no stale fingers from a previous connection leaking into the first
// frame's diff). Called by touch_post_aap_create_session().
void touch_send_reset(void);

#endif // LIBPATCH_BLMJCIAAPA_TOUCH_TOUCH_SEND_H
