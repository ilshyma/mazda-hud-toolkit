// OEM D-Bus HUD bindings (libjcivbsnaviclient, layered on libjcidbus).
//
// This header reads like the vendor header that never shipped: just
// the structs and prototypes of the OEM C functions we call. There is
// NO init step and NO global state — each prototype below is backed by
// a self-resolving thunk in libjcivbsnaviclient.cpp that lazily
// dlsym()s the real symbol on first use, caches it, and forwards. Just
// #include and call; an unresolved symbol degrades to a benign failure
// return (0 / -1) instead of crashing.
//
// The connection lifecycle (JCIDBUS_conn_*, worker, the bus selector
// constants) lives in the sibling libjcidbus.h — libjcivbsnaviclient
// is layered on libjcidbus, so we include it here and callers get the
// whole HUD surface from this one header.
//
// All signatures were hand-derived from the Ghidra decompile
// (decompiled/libjcivbsnaviclient.so.c) — no header ships for this
// library. Re-verify after any OEM firmware update.

#ifndef LIBPATCH_BLMJCIAAPA_LIBJCIVBSNAVICLIENT_H
#define LIBPATCH_BLMJCIAAPA_LIBJCIVBSNAVICLIENT_H

#include <stdint.h>

#include "libjcidbus.h"            // connection lifecycle + kJci*Bus selectors
#include "common/oem/vbs_navi_hud.h"   // VbsNaviHudDisplay, VbsNaviHudMsg2, kAapSpeedSentinel

// --- HUD setters ----------------------------------------------
// Setters: (conn, &struct, unused, completion_cb, user) -> int
// (0 = queued OK). Pass NULL completion_cb/user when no reply needed.
// GetHUDStatus(conn, cb, user); the reply callback is invoked as
// cb(conn, status_byte, user) — a zero status byte means the HUD is
// not installed / not powered.
int VBS_NAVI_SetHUDDisplayMsgReq(void *conn, VbsNaviHudDisplay *disp,
                                 void *unused, void *cb, void *user);
int VBS_NAVI_TMC_SetHUD_Display_Msg2(void *conn, VbsNaviHudMsg2 *msg2,
                                     void *unused, void *cb, void *user);
int VBS_NAVI_GetHUDStatus(void *conn, void *cb, void *user);

// Recommended-lane setter, wire signature ((ay)). UNLIKE the sibling setters
// (which take the wire struct by pointer and read fields at offsets), this
// one takes POINTERS to the data pointer and to the element count and
// dereferences both. `*lanes` points at `*count` bytes — the HUD consumes 8,
// one per lane slot, left→right; 0xFF hides a slot. The bytes are copied while
// marshalling (the send is queued).
// (conn, &data, &count, completion_cb, user) -> int (0 = queued OK).
int VBS_NAVI_SetRecommLaneReq(void *conn, const uint8_t *const *lanes,
                              const uint32_t *count, void *cb, void *user);

#endif  // LIBPATCH_BLMJCIAAPA_LIBJCIVBSNAVICLIENT_H
