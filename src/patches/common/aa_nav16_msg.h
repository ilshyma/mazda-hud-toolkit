// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Cross-process transport for the Android Auto GAL 1.6 HUD path.
//
// aap_service and jciAAPA are SEPARATE processes. The aap_service shim catches
// the 1.6 navigation frames and RELAYS them, unparsed, to the blmjciaapa shim
// (in jciAAPA), which decodes them, maps them to the Mazda HUD domain, and
// renders them through the existing HUD transport (glyph + street fold + lanes).
// So there is exactly ONE place that knows the Android-Auto protocol (blmjciaapa)
// — aap_service is a dumb relay. The wire therefore carries the RAW AA frame
// bytes (a small header + the original [2-byte BE msgId][protobuf] payload).
//
// Transport: an abstract-namespace AF_UNIX SOCK_DGRAM socket. Both ends build
// the address via aa_nav16_fill_addr() below — a leading NUL byte followed by
// AA_NAV16_SOCKET_NAME (Linux abstract sockets — no filesystem node,
// auto-released on close). The receiver validates magic + version + length
// before parsing a datagram.

#ifndef LIBPATCH_COMMON_AA_NAV16_MSG_H
#define LIBPATCH_COMMON_AA_NAV16_MSG_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>

#define AA_NAV16_SOCKET_NAME "mazda-aa-nav16-hud"

enum {
    AA_NAV16_MAGIC     = 0x41483136,   // 'AH16'
    AA_NAV16_VERSION   = 1,
    AA_NAV16_MAX_FRAME = 1024,         // cap on the relayed AA frame payload
};

// GAL navigation-channel msgIds — the 2-byte big-endian prefix of every frame.
// This is the sender/receiver contract: aap_service swallows + relays the whole
// SWALLOW range below (anything the OEM 1.5 endpoint doesn't handle gets its
// routeMessage -253 -> {00 FF} -> full AA teardown, the worst failure mode in
// the system), and blmjciaapa dispatches on the individual ids. Both ends must
// use THESE names, never re-derived literals.
enum {
    AA_NAV16_MSG_CLUSTER_START  = 0x8001,  // InstrumentClusterStart — nothing to render
    AA_NAV16_MSG_CLUSTER_STOP   = 0x8002,  // InstrumentClusterStop — blank the HUD
    AA_NAV16_MSG_STATUS         = 0x8003,  // NavigationStatus (lifecycle; also GAL 1.5)
    AA_NAV16_MSG_NEXT_TURN      = 0x8004,  // NavigationNextTurnEvent (1.5 — OEM handles)
    AA_NAV16_MSG_NEXT_TURN_DIST = 0x8005,  // NavigationNextTurnDistanceEvent (1.5 — OEM handles)
    AA_NAV16_MSG_NAV_STATE      = 0x8006,  // NavigationState (1.6: maneuver + road + lanes)
    AA_NAV16_MSG_POSITION       = 0x8007,  // NavigationCurrentPosition (1.6: distance)

    // The contiguous range hook_routeMessage swallows and relays raw.
    AA_NAV16_MSG_SWALLOW_FIRST  = AA_NAV16_MSG_CLUSTER_START,
    AA_NAV16_MSG_SWALLOW_LAST   = AA_NAV16_MSG_POSITION,
};

// Datagram header, immediately followed by `len` raw AA frame bytes (the full
// frame including its leading 2-byte big-endian msgId). 8 bytes, gap-free.
struct AaNav16Hdr {
    uint32_t magic;      // AA_NAV16_MAGIC
    uint8_t  version;    // AA_NAV16_VERSION
    uint8_t  reserved;   // 0
    uint16_t len;        // number of raw frame bytes that follow (2..AA_NAV16_MAX_FRAME)
};
static_assert(sizeof(AaNav16Hdr) == 8, "AaNav16Hdr is the on-wire header — keep it 8 bytes, gap-free");

// Fill the abstract-namespace socket address both processes rendezvous on.
// Sender and receiver MUST produce byte-identical addresses (a mismatch is
// silent: bind succeeds, sendto just gets ECONNREFUSED) — so this is the one
// definition, next to the socket name it encodes.
static inline void aa_nav16_fill_addr(struct sockaddr_un &addr, socklen_t &addrlen)
{
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    const size_t namelen = sizeof(AA_NAV16_SOCKET_NAME) - 1;
    addr.sun_path[0] = '\0';                                  // abstract namespace
    memcpy(addr.sun_path + 1, AA_NAV16_SOCKET_NAME, namelen);
    addrlen = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + namelen);
}

#endif  // LIBPATCH_COMMON_AA_NAV16_MSG_H
