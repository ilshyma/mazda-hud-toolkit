// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Producer-side interface for the svcjcinavi HUD transport.
//
// This is the active HUD output transport: hud.cpp calls these
// svcnavi_tx_* functions directly. (A direct com.jci.vbs.navi transport
// also exists in vbs_tx.{h,cpp}.)
//
// === What this transport does ================================
//
// Instead of marshalling the OEM com.jci.vbs.navi HUD frame
// ourselves, it hands our guidance to the OEM navi service
// (svcjcinavi) by emitting the very D-Bus signal that service
// already subscribes to for HUD updates:
//
//   bus:    service bus ($JCI_SERVICE_BUS)
//   type:   signal              (broadcast; svcjcinavi's match has no sender=)
//   path:   /com/NNG/Api/Server
//   iface:  com.NNG.Api.Server.Guidance
//   member: GuidanceChangedForHUD
//   sig:    i i i s i i i i i i i i i i      (14 args)
//           dirIcon, maneuverDist, distUnit, streetName,
//           speedLimit, speedUnit, lane0..lane7
//
// svcjcinavi's NNGAPISERVERGUIDANCE_GuidanceChangedForHUD_Handler
// receives it, runs it through NAVI_SendHUDGuidaceDataToVBS, and
// forwards it to the HUD ECU — giving us its sync-bit rotation and
// street-strip pairing for free, and (crucially) making svcjcinavi
// the single writer of the HUD frame so our updates no longer race
// the OEM nav engine's.
//
// The speedLimit argument is set to a reserved sentinel
// (kAapSpeedSentinel) so an in-process svcjcinavi-side splice hook
// (a separate, future component) can tell our frames apart from the
// OEM nav engine's and merge the two streams. A stock, un-hooked
// svcjcinavi will simply render the sentinel as a speed value, which
// is exactly the behaviour the round-trip bring-up test relies on.
//
// This transport only does anything useful when svcjcinavi is
// running, which on this platform requires the navigation SD card to
// be present. With no card, svcjcinavi is absent, the signal goes
// nowhere, and nothing is shown — so a build that selects this
// transport is for card-equipped vehicles. The direct transport
// (vbs_tx) remains the cardless path.

#ifndef LIBPATCH_BLMJCIAAPA_HUD_SVCNAVI_TX_H
#define LIBPATCH_BLMJCIAAPA_HUD_SVCNAVI_TX_H

#include <stdint.h>

// HUD output lifecycle. svcnavi_tx_start opens the OEM service-bus
// connection (libjcidbus, exit-on-disconnect disabled) on a
// dedicated sender thread and starts forwarding per-event updates
// from hud.cpp as GuidanceChangedForHUD signals. svcnavi_tx_stop
// tears the thread down and releases the connection. Both idempotent.
void svcnavi_tx_start(void);
void svcnavi_tx_stop(void);

// 0x500 NAVMessagesStatus. `status` per hu.proto: 1=START, 2=STOP.
// Anything else is treated as STOP (defensive). On STOP we emit a
// blanking signal so svcjcinavi clears the HUD.
void svcnavi_tx_status(uint32_t status);

// 0x501 NAVTurnMessage. Identical contract to vbs_tx_next_turn: `dir_icon` is
// the resolved Mazda HUD glyph (hud.cpp maps the AA turn fields via
// compute_turn_icon). road_name is NOT held past return (snapshot-copied inline).
void svcnavi_tx_next_turn(const char *road_name, uint32_t dir_icon);

// Distance to the next maneuver, in Mazda-HUD form:
//   dist_dec  - display distance * 10 (one decimal)
//   dist_unit - Mazda HUD unit (1=m, 2=mi, 3=km, 4=yd, 5=ft; 0=none)
// hud.cpp maps the AA proto values to this form before calling.
void svcnavi_tx_distance(int32_t dist_dec, uint8_t dist_unit);

// Recommended-lane array (GAL 1.6 only; the 1.5 path never sends lanes). Exactly
// 8 OEM lane CODES (0..70; 0=hidden), LEFT to RIGHT — hud.cpp encodes them and
// svcjcinavi maps each code to a cluster glyph itself. Forwarded verbatim to
// lane0..7 of GuidanceChangedForHUD.
void svcnavi_tx_lanes(const uint8_t *lanes);
  
#endif // LIBPATCH_BLMJCIAAPA_HUD_SVCNAVI_TX_H
