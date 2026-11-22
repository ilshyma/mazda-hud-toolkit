// HUD hooks used by lifecycle.cpp around aap_create_session.
// The per-event producer interface and sender lifecycle live in
// the selected transport header (vbs_tx.h / svcnavi_tx.h).

#ifndef LIBPATCH_BLMJCIAAPA_HUD_HUD_H
#define LIBPATCH_BLMJCIAAPA_HUD_HUD_H

#include <stdint.h>

// Defined in hud.cpp. Called from the aap_create_session PLT shim
// BEFORE chaining to the real SDK entry point, to substitute the
// (NULL on OEM) navigation callback slot in cb_list with one that
// dumps received 0x500 / 0x501 / 0x502 events to the LOGD sink.
// Safe to call with cb_list==NULL (becomes a no-op).
void hud_pre_aap_create_session(void *cb_list);

// Defined in hud.cpp. Called after a successful real
// aap_create_session to start the HUD sender side.
void hud_post_aap_create_session(void);

// Defined in hud.cpp. Called before the real aap_destroy_session to
// stop the HUD sender side.
void hud_pre_aap_destroy_session(void);

// === Android Auto GAL 1.6 path ================================
//
// The aap_service shim (a SEPARATE process) swallows the 1.6 navigation frames
// and relays them RAW over an abstract AF_UNIX datagram socket. The receiver
// thread (nav16_rx.cpp) hands each raw frame to hud_nav16_feed() (hud_nav16.h),
// which decodes the AA protocol and invokes the sink callbacks hud.cpp
// registers; those map it to the Mazda HUD domain and render it through the SAME
// transport (glyph emit, street fold, lanes) the 1.5 path uses.

// Defined in hud.cpp. Reset the GAL 1.6 HUD accumulator + change-gate.
// Called from hud_nav16_rx_start() while the receiver thread is NOT running
// (it is the only other toucher of that state), so a session that ended
// abnormally — cable pull, no INACTIVE/STOP received — can't leave a stale
// gate that suppresses the next session's first frame.
void hud_feed_nav16_reset(void);

#endif // LIBPATCH_BLMJCIAAPA_HUD_HUD_H
