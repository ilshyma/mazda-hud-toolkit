// SPDX-License-Identifier: AGPL-3.0-or-later
//
// GAL 1.6 nav receiver — public API of nav16_rx.cpp.
//
// The aap_service shim (a SEPARATE process) swallows the Android Auto 1.6
// navigation frames and relays them RAW over an abstract AF_UNIX datagram
// socket. nav16_rx.cpp binds that socket on a dedicated thread, validates each
// datagram, and hands the raw frame to hud_nav16_feed() (declared in
// hud_nav16.h) for decode + sink dispatch. The functions below are that
// receiver's lifecycle + status surface, called from hud.cpp.

#ifndef LIBPATCH_BLMJCIAAPA_HUD_NAV16_RX_H
#define LIBPATCH_BLMJCIAAPA_HUD_NAV16_RX_H

// Re-export the decoded-frame data contract + callback types (and the AA->Mazda
// mapping helpers/formatters) so a HUD consumer can depend on this receiver
// header alone: the receiver's whole reason to exist is to decode 1.6 frames
// into these structs and hand them to the callbacks.
#include "hud_nav16.h"

// Start/stop the receiver thread + socket. Started from
// hud_post_aap_create_session when use_protocol_v1_6 is set, stopped from
// hud_pre_aap_destroy_session. Both idempotent.
//
// start() takes the callbacks the decoder delivers decoded 1.6 frames to: they
// are registered before the thread spawns (so the first frame already has a
// destination) and detached by stop().
void hud_nav16_rx_start(HudNav16GuidanceFn on_guidance,
                        HudNav16PositionFn on_position,
                        HudNav16StatusFn   on_status);
void hud_nav16_rx_stop(void);

// TRUE once a validated 1.6 frame has arrived on the rx socket this session
// (reset by hud_nav16_rx_start). our_nav_cb keys the legacy-1.5-callback drop
// on THIS — evidence the 1.6 chain really took — not on the config flag, so a
// 1.6 setup that didn't take (aap_service shim not preloaded / byte-verify
// aborted / phone declined the advertisement) falls back to the stock 1.5 path
// instead of leaving the HUD dark.
bool hud_nav16_rx_seen(void);

#endif // LIBPATCH_BLMJCIAAPA_HUD_NAV16_RX_H
