// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Mute -> Android Auto media play/pause bridge.
//
// The stock head unit only mutes the AMPLIFIER on a user mute — the phone
// keeps streaming, so you miss podcast/audiobook/music content while muted.
// The OEM AA projection key path (HMIEventHandler::InputKey ->
// RaceAap::SendKeyInput) can send KEYCODE_MEDIA_PLAY but has NO pause
// keycode, and the head unit never advertises one, so stock Android Auto is
// never paused on mute. This module fills that gap:
//
//   user mute   -> KEYCODE_MEDIA_PAUSE (0x7f)  (only if AA media is playing)
//   user unmute -> KEYCODE_MEDIA_PLAY  (0x7e)  (normally only if WE paused)
//
// It can also suppress stock CMU-generated resume attempts. jciAAPA reloads
// a per-phone `lastAudio` flag from SerialID_AA, while MMUI sends
// KEYCODE_MEDIA_PLAY when restoring or reactivating Android Auto audio.
// Clearing the initial loaded flags disables jciAAPA's own retry path, and an
// aap_send_key_input interposer filters later CMU-generated MEDIA_PLAY events.
// The PLAY deliberately emitted above on unmute has a thread-local exemption.
//
// IMPORTANT: the PAUSE half only reaches the phone because this mod ALSO adds
// AAP_KEYCODE_MEDIA_PAUSE to the head unit's advertised key_codes in
// /etc/aap_system_attributes*.xml (see resources/ in this repo). That XML is
// read at session start to build the AAP InputSourceService descriptor, which
// tells the phone which keycodes the head unit can emit; Android silently
// drops key events for keycodes it was never told about. The stock XML lists
// only ...MEDIA_PLAY (so the OEM can resume but never pause) — without the XML
// change, SendKeyInput(0x7f) is discarded phone-side and the mute does nothing.
//
// Trigger: the OEM audio manager (com.jci.vbs.am) broadcasts the user-visible
// mute state as EntertainmentMuteStatus, a single byte enum. Confirmed on
// device with dbus-monitor: it is emitted as a BROADCAST (dest=(null)) on BOTH
// the HMI bus ($JCI_HMI_BUS, unix:path=/tmp/dbus_hmi_socket) and the service
// bus, carrying values 2 = muted and 1 = unmuted (0 = uninitialised, never
// seen in normal use) — NOT the 1/0 the server's introspection hints at.
// Because it is broadcast, a passive dbus_bus_add_match on either bus receives
// it; we use the HMI bus, where the mute-wink consumer libjciuiasystem.so also
// lives. NOTE: an earlier revision decoded this as `muted = (val != 0)`, which
// treated BOTH real values (1 and 2) as "muted" and so NEVER resumed on unmute
// — that, not the choice of bus, is why the feature did nothing.
// Transient anti-pop / source-switch mutes travel on the separate
// MuteStatus / UnMuteStatus(muteType) signals and do NOT drive
// EntertainmentMuteStatus, so keying off it gives exactly the deliberate mute
// the user perceives.
//
// Action: RaceAap::SendKeyInput with the same AAP_KeyEvent the OEM builds
// (eType = 0xe00, an Android keycode, a press then a release). We only PAUSE
// when AudioManager::IsAAMediaInPlaying reports AA media is actively playing
// (mirroring the OEM's own InputKey media handling) — so muting media the user
// already paused never arms a resume. A "we paused it" latch, updated only when
// a key is actually delivered, means we only ever resume what we paused; a
// source change while muted (AA loses focus) can't spuriously resume AA.
//
// Configured independently in libpatch.conf: `mute_pauses_phone` controls the
// session-lifecycle-bracketed mute watcher. `unmute_starts_playback` lets an
// unmute start playback even if we did not pause it or AA lacks focus, while
// `block_headunit_media_play` controls the process-wide preload hooks. Both
// of these overrides default off in code.

#define LOG_TAG "PLAYPAUSE"
#include "../log.h"
#include "playpause.h"
#include "../oem/blmjciaapa.h"   // AAP_KeyEvent, keycodes, OEM thunks
#include "../oem/libdbus.h"      // raw libdbus-1 receive path
#include "common/config.h"
#include "common/preload.h"
#include "common/thread_util.h"  // preload_thread_create (bounded stack)

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <string.h>
#include <sys/eventfd.h>
#include <unistd.h>

namespace {

// HMI-bus address. EntertainmentMuteStatus is emitted on the am server's HMI
// connection, so we subscribe on the HMI bus, not the service bus. The OEM
// exports the address in $JCI_HMI_BUS (see /usr/bin/dbus, which launches the
// HMI daemon and exports the var to every process, e.g. via dbus.env); the
// shipped socket is unix:path=/tmp/dbus_hmi_socket, our fallback if the var is
// unset in this PID.
constexpr const char *kHmiBusFallback = "unix:path=/tmp/dbus_hmi_socket";

// com.jci.vbs.am EntertainmentMuteStatus — signal member + a subscribe
// match rule. One arg of D-Bus type 'y' (byte). The runtime enum, verified
// via on-device dbus-monitor, is 2 = muted (ON) and 1 = unmuted (OFF); 0 is
// uninitialised and never seen in normal use. See kEntMuteOn/kEntMuteOff.
constexpr const char *kAmIface     = "com.jci.vbs.am";
constexpr const char *kMuteMember  = "EntertainmentMuteStatus";
constexpr const char *kMatchRule =
    "type='signal',interface='com.jci.vbs.am',member='EntertainmentMuteStatus'";

// EntertainmentMuteStatus byte values, confirmed by on-device dbus-monitor
// (byte 2 on mute, byte 1 on unmute; 0 never observed). The introspection XML
// is silent on the mapping, so decode strictly against these two constants and
// ignore anything else — acting on an unknown value could pause/resume out of
// sync with the real mute state.
constexpr uint8_t kEntMuteOn  = 2;   // muted   -> pause the phone
constexpr uint8_t kEntMuteOff = 1;   // unmuted -> resume the phone

// Backoff before re-opening the bus connection after a disconnect. The HMI
// bus is stable during an AA session (blmjciaapa itself holds an HMI dbus
// connection), so this is purely defensive; the wait is interruptible by stop.
constexpr int kReconnectDelayMs = 1000;

// SDK "session not connected yet" — expected briefly after create until the
// session reaches CONNECTED; do not log it at error level.
constexpr int kAapSessionNotConnected = 0x108;

// SerialID_AA stores up to ten remembered phones. Only the initial ten
// successful reads are startup restoration records; later reads must retain
// their real lastAudio values.
constexpr unsigned kSavedDeviceCount = 10;

using SerialIdBufGetFn = char *(*)(char *, char *, uint32_t *, uint32_t *,
                                    uint32_t *, uint32_t *);
using SendKeyInputFn = int (*)(void *, const void *);

SerialIdBufGetFn g_real_serial_id_buf_get = nullptr;
SendKeyInputFn g_real_send_key_input = nullptr;

void *g_settings_handle = nullptr;
void *g_aap_handle = nullptr;

pthread_mutex_t g_resume_state_mu = PTHREAD_MUTEX_INITIALIZER;
unsigned g_initial_records_seen = 0;

// The lower-level aap_send_key_input hook also sees PLAY events sent through
// RaceAap::SendKeyInput. Exempt only this thread while the watcher delivers
// its deliberate unmute PLAY; stock PLAY events on every other thread remain
// filtered. POD TLS avoids any libstdc++ runtime dependency.
__thread bool g_allow_module_media_play = false;

extern "C" char *SerialID_BufGet(char *, char *, uint32_t *, uint32_t *,
                                  uint32_t *, uint32_t *);
extern "C" int aap_send_key_input(void *, const void *);

pthread_t g_thread;
bool      g_thread_up = false;

// Stop signal: a single eventfd shared between the lifecycle thread (writer)
// and the watcher thread (poller), exactly like the touch reader. One write
// makes it permanently readable, waking the watcher whether it is in the
// reconnect backoff or between dispatch iterations. Using a POSIX eventfd +
// poll (not std::condition_variable::wait_for) also keeps this TU off
// std::chrono::system_clock::now(), whose libstdc++ symbol is versioned
// GLIBCXX_3.4.19 — ABSENT from the device's libstdc++.so.6.0.14. Linking it
// in makes ld.so refuse to map the whole preload shim, so sm_svclauncher
// never brings up jciAAPA and Android Auto disappears from the menu. -1 when
// no watcher is running.
int g_stop_fd = -1;

void *g_conn = nullptr;

// A Unix libdbus transport uses a small fixed set of read/write watches for
// its socket. Four slots leave margin while avoiding heap work in callbacks,
// which libdbus invokes with the connection lock held.
constexpr int kMaxDbusWatches = 4;
struct DbusWatchSet {
    void *items[kMaxDbusWatches];
};
DbusWatchSet g_dbus_watches = {{nullptr, nullptr, nullptr, nullptr}};

// True once WE issued a media PAUSE in response to a mute, so we only resume
// (PLAY) what we paused. Touched only on the watcher thread.
bool g_we_paused = false;

// True if the stop eventfd has been signalled (non-blocking peek).
bool stop_requested()
{
    struct pollfd pfd = { g_stop_fd, POLLIN, 0 };
    return poll(&pfd, 1, 0) > 0 && (pfd.revents & POLLIN);
}

// Interruptible sleep: wait up to `ms` for the stop eventfd, returning true if
// a stop was requested (caller should bail), false on timeout.
bool wait_stop(int ms)
{
    struct pollfd pfd = { g_stop_fd, POLLIN, 0 };
    int pr = poll(&pfd, 1, ms);
    return pr > 0 && (pfd.revents & POLLIN);
}

bool observe_initial_record(unsigned &initial_records_seen,
                            uint32_t &last_audio)
{
    if (initial_records_seen >= kSavedDeviceCount)
        return false;

    ++initial_records_seen;
    if (last_audio == 0)
        return false;

    last_audio = 0;
    return true;
}

void resolve_real_serial_id_buf_get()
{
    if (g_real_serial_id_buf_get)
        return;

    g_real_serial_id_buf_get = reinterpret_cast<SerialIdBufGetFn>(
        resolve_real_symbol("SerialID_BufGet",
                            "libjcisettings_client.so",
                            "/jci/lib/libjcisettings_client.so",
                            reinterpret_cast<void *>(&SerialID_BufGet),
                            &g_settings_handle));
}

void resolve_real_send_key_input()
{
    if (g_real_send_key_input)
        return;

    g_real_send_key_input = reinterpret_cast<SendKeyInputFn>(
        resolve_real_symbol("aap_send_key_input",
                            "libaap_interface.so",
                            "/usr/lib/libaap_interface.so",
                            reinterpret_cast<void *>(&aap_send_key_input),
                            &g_aap_handle));
}

bool should_filter_media_play(const void *event)
{
    if (!event)
        return false;

    const AAP_KeyEvent *key = static_cast<const AAP_KeyEvent *>(event);
    return key->eType == kAAPKeyEventType &&
           key->eKeyCode == kAAPKeyMediaPlay;
}

void clear_dbus_watches()
{
    for (int i = 0; i < kMaxDbusWatches; ++i)
        g_dbus_watches.items[i] = nullptr;
}

bool dbus_watch_is_registered(void *watch)
{
    for (int i = 0; i < kMaxDbusWatches; ++i) {
        if (g_dbus_watches.items[i] == watch)
            return true;
    }
    return false;
}

// Watch callbacks must not call DBusConnection APIs: libdbus invokes them
// while holding the connection lock. The watcher thread re-queries enabled
// state and flags whenever it rebuilds its poll set, so toggles need no work.
DBusBool add_dbus_watch(void *watch, void *)
{
    if (dbus_watch_is_registered(watch))
        return 1;
    for (int i = 0; i < kMaxDbusWatches; ++i) {
        if (g_dbus_watches.items[i] == nullptr) {
            g_dbus_watches.items[i] = watch;
            return 1;
        }
    }
    return 0;
}

void remove_dbus_watch(void *watch, void *)
{
    for (int i = 0; i < kMaxDbusWatches; ++i) {
        if (g_dbus_watches.items[i] == watch) {
            g_dbus_watches.items[i] = nullptr;
            return;
        }
    }
}

void toggle_dbus_watch(void *, void *)
{
}

// Return true if AA media is the active/focused audio source right now.
// IsAAMediaInFocus reads the AudioManager focus field (set by
// AudioFocusChangeCb), which stays true through a pause — so it correctly
// gates the resume (on unmute) even after we paused.
bool aa_media_in_focus()
{
    void *aap = Singleton_AapProc_GetInstance();
    if (!aap) return false;
    void *am = AapProc_GetAudioManager(aap);
    if (!am) return false;
    return AudioManager_IsAAMediaInFocus(am) != 0;
}

// Return true if AA media is actively PLAYING right now (not paused/stopped).
// Used to decide whether a mute should pause: if the user already paused the
// media, IsAAMediaInFocus is still true but IsAAMediaInPlaying is false, so we
// must not arm the resume latch (else unmute would force playback back on).
bool aa_media_in_playing()
{
    void *aap = Singleton_AapProc_GetInstance();
    if (!aap) return false;
    void *am = AapProc_GetAudioManager(aap);
    if (!am) return false;
    return AudioManager_IsAAMediaInPlaying(am) != 0;
}

// Send one media key press (down then up) to the phone via the OEM
// RaceAap::SendKeyInput, mirroring HMIEventHandler::InputKey's press/release
// pair and its eType = 0xe00. Returns true only if BOTH the press and release
// were accepted (rc 0). A rejected key — most commonly rc 0x108 while the
// session hasn't reached CONNECTED — means the phone did NOT act on it, so the
// caller must not treat the media as (un)paused.
bool send_media_key(uint32_t keycode)
{
    void *aap = Singleton_AapProc_GetInstance();
    if (!aap) { LOGV("send_media_key: AapProc instance not available"); return false; }
    void *race = AapProc_GetRaceAap(aap);
    if (!race) { LOGV("send_media_key: RaceAap not available"); return false; }

    AAP_KeyEvent evt;
    std::memset(&evt, 0, sizeof(evt));
    evt.eType    = kAAPKeyEventType;   // 0xe00, exactly as the OEM does
    evt.eKeyCode = keycode;

    const bool exempt_play = keycode == kAAPKeyMediaPlay;
    const bool previous_exemption = g_allow_module_media_play;
    if (exempt_play)
        g_allow_module_media_play = true;

    evt.bDown = 1;                      // press
    int rc_down = RaceAap_SendKeyInput(race, &evt);
    if (rc_down != 0 && rc_down != kAapSessionNotConnected)
        LOGE("SendKeyInput(down key=0x%x) -> %d", keycode, rc_down);

    evt.bDown = 0;                      // release
    int rc_up = RaceAap_SendKeyInput(race, &evt);
    g_allow_module_media_play = previous_exemption;
    if (rc_up != 0 && rc_up != kAapSessionNotConnected)
        LOGE("SendKeyInput(up key=0x%x) -> %d", keycode, rc_up);

    bool delivered = (rc_down == 0 && rc_up == 0);
    LOGD("media key 0x%x (down+up) delivered=%d", keycode, delivered ? 1 : 0);
    return delivered;
}

// Act on a fresh EntertainmentMuteStatus value.
void on_mute_changed(bool muted)
{
    if (muted) {
        if (g_we_paused) {
            LOGV("mute: already paused by us — ignoring");
            return;
        }
        // Only pause when AA media is actually PLAYING. If the user (or the
        // phone) already paused it, IsAAMediaInFocus would still be true, but
        // arming the latch here would make the later unmute force playback of
        // media the user deliberately paused. IsAAMediaInPlaying implies AA
        // media is also the focused source, so it subsumes the focus check.
        if (!aa_media_in_playing()) {
            LOGD("mute: AA media not actively playing — not pausing");
            return;
        }
        // Arm the latch ONLY if the PAUSE was actually delivered; a rejected
        // key did not pause the phone, so we must not later resume it.
        if (send_media_key(kAAPKeyMediaPause))
            g_we_paused = true;
    } else {
        const bool skip_checks = libpatch_config::unmute_starts_playback();
        if (!skip_checks && !g_we_paused) {
            LOGV("unmute: we did not pause — ignoring");
            return;
        }
        if (!skip_checks && !aa_media_in_focus()) {
            // Source switched away while muted; abandon the pending resume so
            // we never resume AA in the background.
            LOGD("unmute: AA media not in focus — dropping pending resume");
            g_we_paused = false;
            return;
        }
        if (skip_checks)
            LOGD("unmute: skipping pause-latch and audio-focus checks");
        // Clear the latch ONLY once the PLAY is delivered, so a rejected resume
        // is retried on the next unmute rather than silently lost.
        if (send_media_key(kAAPKeyMediaPlay))
            g_we_paused = false;
    }
}

// Interpret one popped message; act on it iff it is the mute signal.
void handle_message(void *msg)
{
    if (dbus_message_is_signal(msg, kAmIface, kMuteMember) == 0)
        return;

    DBusMessageIter it;
    if (dbus_message_iter_init(msg, &it) == 0) {
        LOGW("EntertainmentMuteStatus signal carried no args");
        return;
    }
    int argtype = dbus_message_iter_get_arg_type(&it);
    if (argtype != DBUS_TYPE_BYTE) {
        LOGW("EntertainmentMuteStatus arg is not a byte (type=%d)", argtype);
        return;
    }

    // get_basic writes the byte into *value; use an over-sized zeroed union
    // so a mis-sized write can never scribble past a lone uint8_t.
    union { uint8_t y; uint64_t pad; } bv;
    bv.pad = 0;
    dbus_message_iter_get_basic(&it, &bv);
    uint8_t val = bv.y;

    // Decode strictly against the confirmed enum (2 = muted, 1 = unmuted).
    // Any other value (notably 0 = uninitialised) is ignored so we never act
    // on an ambiguous state.
    if (val == kEntMuteOn) {
        LOGD("EntertainmentMuteStatus = %u (muted)", val);
        on_mute_changed(true);
    } else if (val == kEntMuteOff) {
        LOGD("EntertainmentMuteStatus = %u (unmuted)", val);
        on_mute_changed(false);
    } else {
        LOGD("EntertainmentMuteStatus = %u (ignored: not muted/unmuted)", val);
    }
}

void drain_messages()
{
    void *msg;
    while ((msg = dbus_connection_pop_message(g_conn)) != nullptr) {
        handle_message(msg);
        dbus_message_unref(msg);
    }
}

// Open a private HMI-bus connection and subscribe to the mute signal.
// Returns true on success; on any failure the connection is released.
bool setup_connection()
{
    clear_dbus_watches();

    const char *addr = getenv("JCI_HMI_BUS");
    if (addr == nullptr || addr[0] == '\0') {
        addr = kHmiBusFallback;
        LOGW("$JCI_HMI_BUS unset — falling back to %s", addr);
    }

    g_conn = dbus_connection_open_private(addr, nullptr);
    if (g_conn == nullptr) {
        LOGC("dbus_connection_open_private(%s) failed — play/pause bridge inactive", addr);
        return false;
    }

    // exit_on_disconnect FALSE before register, so a bus teardown (e.g. on a
    // source switch) can't raise a fatal signal in this PID.
    dbus_connection_set_exit_on_disconnect(g_conn, 0);

    if (dbus_bus_register(g_conn, nullptr) == 0) {
        LOGE("dbus_bus_register failed — play/pause bridge inactive");
        dbus_connection_close(g_conn);
        dbus_connection_unref(g_conn);
        g_conn = nullptr;
        return false;
    }

    if (dbus_connection_set_watch_functions(
            g_conn, add_dbus_watch, remove_dbus_watch, toggle_dbus_watch,
            nullptr, nullptr) == 0) {
        LOGE("dbus_connection_set_watch_functions failed — play/pause bridge inactive");
        dbus_connection_close(g_conn);
        dbus_connection_unref(g_conn);
        g_conn = nullptr;
        clear_dbus_watches();
        return false;
    }

    // With a NULL DBusError this queues AddMatch without blocking. The write
    // watch will become enabled and the event loop below will transmit it; no
    // blocking dbus_connection_flush is needed.
    dbus_bus_add_match(g_conn, kMatchRule, nullptr);
    LOGD("subscription requested for %s.%s on %s", kAmIface, kMuteMember, addr);
    return true;
}

void teardown_connection()
{
    if (g_conn == nullptr)
        return;
    // Private connections must be closed before the final unref.
    dbus_connection_close(g_conn);
    dbus_connection_unref(g_conn);
    g_conn = nullptr;
    clear_dbus_watches();
}

// Block until either libdbus has socket work or session teardown signals the
// stop eventfd. There is deliberately no timeout: an idle play/pause watcher causes
// no periodic wakeups.
void run_watch_loop()
{
    // Registration may have queued bus-control messages before watch setup.
    drain_messages();

    while (!stop_requested()) {
        struct pollfd pfds[kMaxDbusWatches + 1];
        void *poll_watches[kMaxDbusWatches + 1] = {};
        nfds_t nfds = 1;

        pfds[0].fd = g_stop_fd;
        pfds[0].events = POLLIN;
        pfds[0].revents = 0;

        for (int i = 0; i < kMaxDbusWatches; ++i) {
            void *watch = g_dbus_watches.items[i];
            if (watch == nullptr || dbus_watch_get_enabled(watch) == 0)
                continue;

            int fd = dbus_watch_get_unix_fd(watch);
            if (fd < 0)
                continue;

            unsigned int flags = dbus_watch_get_flags(watch);
            short events = 0;
            if (flags & DBUS_WATCH_READABLE) events |= POLLIN;
            if (flags & DBUS_WATCH_WRITABLE) events |= POLLOUT;

            pfds[nfds].fd = fd;
            pfds[nfds].events = events;
            pfds[nfds].revents = 0;
            poll_watches[nfds] = watch;
            ++nfds;
        }

        if (nfds == 1) {
            LOGE("HMI bus has no enabled D-Bus watches — reconnecting");
            return;
        }

        int pr;
        do {
            pr = poll(pfds, nfds, -1);
        } while (pr < 0 && errno == EINTR);

        if (pr < 0) {
            LOGE("play/pause watcher: poll() failed: %s", strerror(errno));
            return;
        }

        if (pfds[0].revents & (POLLIN | POLLERR | POLLHUP | POLLNVAL))
            return;

        for (nfds_t i = 1; i < nfds; ++i) {
            short revents = pfds[i].revents;
            void *watch = poll_watches[i];
            if (revents == 0 || !dbus_watch_is_registered(watch) ||
                dbus_watch_get_enabled(watch) == 0)
                continue;

            unsigned int requested_flags = dbus_watch_get_flags(watch);
            unsigned int flags = 0;
            if ((revents & POLLIN) &&
                (requested_flags & DBUS_WATCH_READABLE))
                flags |= DBUS_WATCH_READABLE;
            if ((revents & POLLOUT) &&
                (requested_flags & DBUS_WATCH_WRITABLE))
                flags |= DBUS_WATCH_WRITABLE;
            if (revents & (POLLERR | POLLNVAL))
                flags |= DBUS_WATCH_ERROR;
            if (revents & POLLHUP)
                flags |= DBUS_WATCH_HANGUP;

            if (flags != 0 && dbus_watch_handle(watch, flags) == 0) {
                LOGE("dbus_watch_handle failed — reconnecting");
                return;
            }
        }

        // Drain before checking connected state: libdbus may retain messages
        // received immediately before the transport disconnected.
        drain_messages();
        if (dbus_connection_get_is_connected(g_conn) == 0) {
            LOGW("HMI bus disconnected — will reconnect");
            return;
        }
    }
}

void *watcher_main(void *)
{
    // Initial mute state is not queried: we act on signal edges, so a "muted at
    // connect" session simply stays as stock until the next mute cycle, then
    // self-syncs. Likewise, each (RE)connection below starts from an unknown
    // mute state — after a bus disconnect we may have missed an unmute, so we
    // clear the "we paused it" latch on every connect. That prefers "mute
    // always silences" over "always auto-resume": worst case we miss one resume
    // right after a (rare) reconnect, instead of a mute becoming a silent no-op.
    while (!stop_requested()) {
        g_we_paused = false;

        if (!setup_connection()) {
            teardown_connection();
            if (wait_stop(kReconnectDelayMs)) break;
            continue;
        }

        run_watch_loop();

        teardown_connection();
        if (stop_requested()) break;
        if (wait_stop(kReconnectDelayMs)) break;
    }

    LOGD("play/pause watcher thread exiting");
    return nullptr;
}

} // namespace

extern "C" PRELOAD_EXPORT
char *SerialID_BufGet(char *serialized, char *serial_id,
                      uint32_t *serial_id_size, uint32_t *connect_mode,
                      uint32_t *last_video, uint32_t *last_audio)
{
    resolve_real_serial_id_buf_get();
    if (!g_real_serial_id_buf_get) {
        LOGC("SerialID_BufGet real implementation unresolved");
        return nullptr;
    }

    char *next = g_real_serial_id_buf_get(serialized, serial_id,
                                          serial_id_size, connect_mode,
                                          last_video, last_audio);
    if (next && libpatch_config::block_headunit_media_play() && last_audio) {
        uint32_t saved_last_audio = *last_audio;
        pthread_mutex_lock(&g_resume_state_mu);
        bool cleared = observe_initial_record(g_initial_records_seen,
                                              *last_audio);
        unsigned records_seen = g_initial_records_seen;
        pthread_mutex_unlock(&g_resume_state_mu);
        if (cleared) {
            LOGD("cleared startup AA lastAudio=%u in record %u",
                 static_cast<unsigned>(saved_last_audio), records_seen);
        }
    }
    return next;
}

extern "C" PRELOAD_EXPORT
int aap_send_key_input(void *handle, const void *event)
{
    if (libpatch_config::block_headunit_media_play() &&
        !g_allow_module_media_play && should_filter_media_play(event)) {
        LOGD("filtered CMU KEYCODE_MEDIA_PLAY");
        return 0;
    }

    resolve_real_send_key_input();
    if (!g_real_send_key_input) {
        LOGC("aap_send_key_input real implementation unresolved");
        return 0x103;
    }
    return g_real_send_key_input(handle, event);
}

void playpause_post_aap_create_session(void)
{
    if (g_thread_up)
        return;

    g_we_paused = false;

    // The stop eventfd must exist before the watcher starts so its very first
    // stop check / backoff is interruptible. EFD_NONBLOCK keeps the
    // stop_requested() peek from ever blocking.
    g_stop_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (g_stop_fd < 0) {
        LOGC("play/pause watcher: eventfd() failed: %s", strerror(errno));
        return;
    }

    if (preload_thread_create(&g_thread, watcher_main, nullptr) != 0) {
        LOGC("failed to spawn play/pause watcher thread");
        close(g_stop_fd);
        g_stop_fd = -1;
        return;
    }
    g_thread_up = true;
    LOGD("play/pause watcher thread started");
}

void playpause_pre_aap_destroy_session(void)
{
    if (!g_thread_up)
        return;

    // One write makes the eventfd permanently readable, instantly waking the
    // watcher whether it's polling bus I/O or in the reconnect backoff.
    uint64_t one = 1;
    if (write(g_stop_fd, &one, sizeof(one)) != (ssize_t)sizeof(one))
        LOGE("play/pause watcher: write(stop eventfd) failed: %s", strerror(errno));

    pthread_join(g_thread, nullptr);
    g_thread_up = false;
    g_we_paused = false;

    close(g_stop_fd);
    g_stop_fd = -1;
    LOGD("play/pause watcher thread stopped");
}
