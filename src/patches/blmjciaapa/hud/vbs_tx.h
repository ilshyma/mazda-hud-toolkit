// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Adapted from headunit (https://github.com/Trevelopment/headunit),
// licensed under GNU AGPL v3.
// See NOTICE.md at the repo root for the full attribution.
//
// Producer-side interface for the VBS (com.jci.vbs.navi) HUD sender.
// HUD output module — push interface used by hud.cpp.
//
// Three small non-blocking functions the AAP nav callback in
// `hud.cpp` calls once per phone-side event. Each updates a
// seqlock-protected snapshot inside `vbs_tx.cpp` and wakes the
// dedicated sender thread that owns the OEM D-Bus connections.
//
// This transport writes the HUD frame DIRECTLY to com.jci.vbs.navi
// (the libjcimod_navigation.so handler inside the jciVBS process),
// so it works with no navigation SD card. The alternative svcnavi
// transport (svcnavi_send.{h,cpp}) routes through svcjcinavi instead.
//
// Lifecycle (start/stop) is declared here as the sender-facing
// half of the HUD subsystem; hud_pre_aap_create_session lives in hud.h.
//
// Implementation reference: `mazda/hud/{hud.h,hud.cpp}` in the
// upstream headunit project (see the SPDX header at the top of
// vbs_tx.cpp for the URL). We mirror the proxy classes and the
// turn-icon lookup table from that implementation but adapted to
// live inside an LD_PRELOAD library rather than the headunit's
// own daemon.

#ifndef LIBPATCH_BLMJCIAAPA_VBS_TX_H
#define LIBPATCH_BLMJCIAAPA_VBS_TX_H

#include <stdint.h>

// Defined in vbs_tx.cpp. HUD output lifecycle. vbs_tx_start opens
// the OEM HMI + Service D-Bus connections, spawns a dispatcher
// thread and a sender thread, and starts forwarding per-event
// updates from hud.cpp. vbs_tx_stop tears the threads down and
// releases the D-Bus connections. Both are idempotent.
void vbs_tx_start(void);
void vbs_tx_stop(void);

// 0x500 NAVMessagesStatus. `status` per hu.proto: 1=START, 2=STOP.
// Anything else is treated as STOP (defensive).
void vbs_tx_status(uint32_t status);

// 0x501 NAVTurnMessage. `road_name` may be NULL or empty; `dir_icon` is the
// resolved Mazda HUD glyph (hud.cpp maps the AA turn_side/event/angle fields to
// it via compute_turn_icon). road_name lifetime: NOT held past return — the
// pointer is snapshot-copied into a fixed-size buffer inline.
void vbs_tx_next_turn(const char *road_name, uint32_t dir_icon);

// Distance to the next maneuver, in Mazda-HUD form:
//   dist_dec  - display distance * 10 (one decimal)
//   dist_unit - Mazda HUD unit (1=m, 2=mi, 3=km, 4=yd, 5=ft; 0=none)
// hud.cpp maps the AA proto values to this form before calling.
void vbs_tx_distance(int32_t dist_dec, uint8_t dist_unit);

// Recommended-lane array (GAL 1.6 only; the 1.5 path never sends lanes). Exactly
// 8 Mazda cluster GLYPH bytes, LEFT to RIGHT (0=hidden) — hud.cpp encodes the AA
// lanes to OEM codes and maps each to a cluster glyph, since this path bypasses
// svcjcinavi. Carried on a SEPARATE OEM method (VBS_NAVI_SetRecommLaneReq) — see
// vbs_tx.cpp for the emit-side 0 -> kVbsLaneHidden (0xFF) hidden-slot remap.
void vbs_tx_lanes(const uint8_t *lanes);

#endif // LIBPATCH_BLMJCIAAPA_VBS_TX_H
