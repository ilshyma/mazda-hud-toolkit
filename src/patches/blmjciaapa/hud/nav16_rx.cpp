// SPDX-License-Identifier: AGPL-3.0-or-later
//
// GAL 1.6 nav receiver — the jciAAPA side of the cross-process HUD path.
//
// aap_service (a separate process) swallows the Android Auto 1.6 navigation
// frames and relays them RAW (an AaNav16Hdr + the original frame bytes) over an
// abstract AF_UNIX datagram socket. This thread binds that socket, validates the
// header, and hands the raw frame to hud_nav16_feed(), which decodes it and
// invokes the HUD sink callbacks (registered by hud.cpp) that render it through
// the existing HUD transport. So the 1.6 protocol is parsed in exactly one place
// (hud_nav16, here in blmjciaapa), reusing the same renderer (glyph map, street
// fold, lanes) as the 1.5 callback path.
//
// Lifecycle is bracketed by aap_create/destroy_session via hud.cpp, and only
// armed when use_protocol_v1_6 is set. Fail-safe: any socket error just leaves
// the receiver inactive — the seen-latch (hud_nav16_rx_seen) then stays false,
// our_nav_cb keeps serving the legacy 1.5 callbacks, and the HUD falls back to
// stock 1.5 behaviour instead of going dark.

#define LOG_TAG "NAV16RX"
#include "../log.h"
#include "hud.h"
#include "nav16_rx.h"
#include "hud_nav16.h"
#include "common/aa_nav16_msg.h"
#include "common/thread_util.h"
#include "common/nav_diag.h"

#include <atomic>
#include <cstring>
#include <pthread.h>
#include <poll.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <stddef.h>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <sys/un.h>

namespace {

std::atomic<bool> g_stop{false};
std::atomic<bool> g_seen{false};      // a validated 1.6 frame arrived this session
pthread_t         g_thread    = 0;
bool              g_thread_up = false;
int               g_fd        = -1;
int               g_stop_fd   = -1;   // eventfd: poll()ed by rx_main, written by stop()

int open_rx_socket()
{
    int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        LOGE("nav16_rx: socket() failed: %s", strerror(errno));
        return -1;
    }
    struct sockaddr_un addr;
    socklen_t addrlen;
    aa_nav16_fill_addr(addr, addrlen);

    if (bind(fd, reinterpret_cast<struct sockaddr *>(&addr), addrlen) != 0) {
        LOGE("nav16_rx: bind(@%s) failed: %s — receiver inactive",
             AA_NAV16_SOCKET_NAME, strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}

#ifdef HUD_NAV_DIAG
NAV_DIAG_SINK(g_diag, "aa_nav");
#endif

void *rx_main(void *)
{
    g_fd = open_rx_socket();
    if (g_fd < 0) {
        return nullptr;
    }
    LOGD("nav16_rx: listening on abstract socket @%s", AA_NAV16_SOCKET_NAME);

    while (!g_stop.load(std::memory_order_relaxed)) {
        // Block until a datagram or the stop eventfd fires — zero idle wakeups
        // on this CPU-starved box, and stop() interrupts instantly. If the
        // eventfd couldn't be created (g_stop_fd == -1: poll ignores negative
        // fds), fall back to a 200 ms timeout so the g_stop check still runs.
        struct pollfd pfd[2];
        pfd[0].fd = g_fd;      pfd[0].events = POLLIN; pfd[0].revents = 0;
        pfd[1].fd = g_stop_fd; pfd[1].events = POLLIN; pfd[1].revents = 0;
        int r = poll(pfd, 2, (g_stop_fd >= 0) ? -1 : 200);
        if (r <= 0) continue;                 // timeout or EINTR
        if (pfd[1].revents & POLLIN) break;   // hud_nav16_rx_stop() signaled
        if (!(pfd[0].revents & POLLIN)) continue;

        // The datagram is an AaNav16Hdr followed by `len` raw AA frame bytes.
        // The abstract socket is world-writable, so validate the header before
        // handing the payload to the decoder.
        char buf[sizeof(AaNav16Hdr) + AA_NAV16_MAX_FRAME];
        ssize_t n = recv(g_fd, buf, sizeof(buf), 0);
        if (n < (ssize_t)sizeof(AaNav16Hdr)) continue;
        AaNav16Hdr hdr;
        std::memcpy(&hdr, buf, sizeof(hdr));
        if (hdr.magic != (uint32_t)AA_NAV16_MAGIC || hdr.version != AA_NAV16_VERSION) {
            LOGW("nav16_rx: bad magic/version (0x%x v%u) — dropping",
                 (unsigned)hdr.magic, (unsigned)hdr.version);
            continue;
        }
        int len = (int)hdr.len;
        if (len < 2 || len > AA_NAV16_MAX_FRAME ||
            (ssize_t)(sizeof(AaNav16Hdr) + (size_t)len) > n) {
            LOGW("nav16_rx: bad len %d (n=%ld) — dropping", len, (long)n);
            continue;
        }
        // Latch BEFORE feeding: a validated frame is the proof the whole 1.6
        // chain took (aap_service shim preloaded, byte-verify passed, phone
        // accepted the advertisement) — our_nav_cb drops legacy 1.5 callbacks
        // from here on. exchange() returns the previous value, so the DEBUG
        // line fires exactly once per session (on the false->true transition).
        if (!g_seen.exchange(true, std::memory_order_release)) {
            LOGD("nav16_rx: first 1.6 frame received — 1.5 callback path now suppressed");
        }
        NAV_DIAG(nav_diag::bytes(&g_diag, "aa16", buf + sizeof(AaNav16Hdr),
                                 static_cast<size_t>(len)));
        hud_nav16_feed(reinterpret_cast<const uint8_t *>(buf) + sizeof(AaNav16Hdr),
                       len);
    }

    close(g_fd);
    g_fd = -1;
    LOGD("nav16_rx: thread exiting");
    return nullptr;
}

} // namespace

void hud_nav16_rx_start(HudNav16GuidanceFn on_guidance,
                        HudNav16PositionFn on_position,
                        HudNav16StatusFn   on_status)
{
    if (g_thread_up) {
        return;
    }
    // Register the decode callbacks before the thread exists (the only feeder),
    // so the first frame it hands to hud_nav16_feed() already has a destination.
    hud_nav16_set_sink(on_guidance, on_position, on_status);
    // The previous session may have ended without a clean INACTIVE/STOP
    // (cable pull) — reset the decoder state here, before the rx thread
    // exists, so it can't suppress the new session's first frame. The seen
    // latch resets with it: every session must re-prove it speaks 1.6, so a
    // phone that drops back to 1.5 gets the legacy path again.
    hud_feed_nav16_reset();
    g_seen.store(false, std::memory_order_release);
    g_stop.store(false, std::memory_order_release);
    g_stop_fd = eventfd(0, EFD_CLOEXEC);
    if (g_stop_fd < 0) {
        LOGW("hud_nav16_rx_start: eventfd failed (%s) — rx falls back to 200 ms poll",
             strerror(errno));
    }
    if (preload_thread_create(&g_thread, rx_main, nullptr) != 0) {
        LOGC("hud_nav16_rx_start: pthread_create failed — no 1.6 HUD this session");
        hud_nav16_set_sink(nullptr, nullptr, nullptr);   // no feeder will run — drop them
        if (g_stop_fd >= 0) {
            close(g_stop_fd);
            g_stop_fd = -1;
        }
        return;
    }
    g_thread_up = true;
    LOGD("hud_nav16_rx_start: receiver thread spawned");
}

bool hud_nav16_rx_seen(void)
{
    return g_seen.load(std::memory_order_acquire);
}

void hud_nav16_rx_stop(void)
{
    if (!g_thread_up) {
        return;
    }
    g_stop.store(true, std::memory_order_release);
    if (g_stop_fd >= 0) {
        // Wake the blocking poll(). An 8-byte eventfd write is atomic and the
        // counter (0 or 1 here) can't saturate, so only EINTR needs handling.
        uint64_t one = 1;
        while (write(g_stop_fd, &one, sizeof(one)) < 0 && errno == EINTR) {}
    }
    pthread_join(g_thread, nullptr);
    hud_nav16_set_sink(nullptr, nullptr, nullptr);   // joined: no more feed() -> safe to detach
    if (g_stop_fd >= 0) {
        close(g_stop_fd);                     // after join: rx_main can't touch it now
        g_stop_fd = -1;
    }
    g_thread_up = false;
    g_thread    = 0;
    LOGD("hud_nav16_rx_stop: receiver thread stopped");
}
