// SPDX-License-Identifier: AGPL-3.0-or-later
//
// svcjcinavi HUD merge hook.
//
// Interposes the two OEM HUD setters that svcjcinavi calls on its
// sender thread (thUpdateGuidanceChangeToHUD):
//
//   VBS_NAVI_SetHUDDisplayMsgReq      — the (uqyqyy) maneuver frame
//   VBS_NAVI_TMC_SetHUD_Display_Msg2  — the street-name strip
//
// Both are UND (PLT imports from libjcivbsnaviclient.so) in
// svcjcinavi.so, so an LD_PRELOAD definition at the front of the
// process's global scope binds svcjcinavi's calls to ours. We chain
// through to the real implementations after rewriting.
//
// === The problem this solves =================================
//
// With the nav SD card inserted, the OEM nav engine (NNG) emits
// GuidanceChangedForHUD frames even with no active route — its TSR
// (speed-limit) frames carry a real speed but a BLANK maneuver
// (dirIcon=0). Android Auto, via the blmjciaapa svcnavi transport,
// emits its own GuidanceChangedForHUD frames carrying a real maneuver
// and the reserved sentinel speed (kAapSpeedSentinel = 0xFFFF). Both
// streams converge on svcjcinavi's single sender thread and alternate
// at the HUD: AAP maneuver, then NNG's blank-maneuver speed frame,
// then AAP maneuver, ... — the maneuver arrow blinks (flicker).
//
// === What we do ==============================================
//
// We make every frame the HUD receives carry the SAME content
// (AAP maneuver + OEM speed), so re-asserting it at the union of both
// cadences is flicker-free (re-rendering identical content is
// invisible). We discriminate the two streams by the sentinel speed
// value and keep a little state (all touched only from the single
// sender thread, so no locking):
//
//   * AAP-origin frame (speed == sentinel): if it carries a real
//     maneuver, remember its maneuver block and (re)arm the AAP-active
//     window; if it is EMPTY (maneuver == 0, the blanking frame AAP
//     sends when its guidance stops) clear AAP ownership so OEM frames
//     resume passing through natively. Either way splice the
//     remembered OEM speed in and forward.
//   * OEM-origin frame (speed != sentinel): remember its speed, then —
//     while AAP is active — overwrite its (blank) maneuver block with
//     the remembered AAP maneuver and forward. NNG's frame now carries
//     AAP's turn + its own speed, identical to AAP's own frames. We do
//     NOT touch text_ID3: svcjcinavi computes the sync bit for every
//     frame and stamps the same value into both the maneuver frame and
//     its paired street strip, so the value we see is already correct.
//   * Street strip (Msg2): svcjcinavi emits it back-to-back right after
//     the maneuver frame (same critical section, same generation), so
//     the strip's origin is whatever the maneuver frame just before it
//     was. We mirror the maneuver handling: on an AAP-origin generation
//     we CAPTURE the street into our own buffer (read from the OEM's
//     un-blanked current_StreetName, so a market that blanks the
//     outbound strip — e.g. EU — still yields the real street; a null/
//     empty street is stored as the empty string) and re-point the strip
//     at our copy; on an OEM-origin generation while AAP owns the
//     display we REPLACE the (blank NNG) street with the captured AAP
//     street and pass it, so the street is re-asserted identically at
//     both
//     cadences — flicker-free, same as the maneuver. AAP-idle strips
//     pass untouched. We only ever rewrite the street STRING, never the
//     strip's syncBit: svcjcinavi stamps the same per-generation sync
//     into both the maneuver frame's text_ID3 and this strip's syncBit
//     in one critical section, and that pairing is what tells the HUD
//     the two updates go together. We leave both untouched, so the
//     spliced street rides on the current generation's sync and still
//     matches the (also-spliced) maneuver frame.
//
// If the card is out, NNG never runs, this process never exists, and
// the library is simply never loaded. If AAP is not active, the OEM
// frames pass through untouched (native behaviour).
//
// === CarPlay (direct-VBS projection) ==========================
//
// The CarPlay shim does not go through svcjcinavi — it writes the HUD
// itself — so it cannot be spliced in-process. Instead (common/hud_share.h):
//   * every OEM speed we see is published to a tmpfs file, which the
//     CarPlay shim paints into its own frames (same values the OEM nav
//     would send, unit included);
//   * while CarPlay guidance owns the HUD (its active marker is fresh) we
//     DROP the OEM maneuver frame and its street strip, so the blank-
//     maneuver OEM frames cannot alternate with CarPlay's. The speed is
//     still remembered/published before the drop.

#define LOG_TAG "MERGE"
#include "log.h"
#include "../common/config.h"
#include "../common/preload.h"
#include "../common/string_safe.h"
#include "../common/oem/vbs_navi_hud.h"
#include "../common/hud_share.h"
#include "../common/nav_diag.h"

#include <dlfcn.h>
#include <time.h>
#include <string.h>
#include <stdint.h>

// Forward declarations of our own exported PLT shadows, so ensure_gate()
// (below) can take their addresses for the resolve_real_symbol self-loop
// guard. Defined at file scope further down.
extern "C" int VBS_NAVI_SetHUDDisplayMsgReq(void *, VbsNaviHudDisplay *,
                                            void *, void *, void *);
extern "C" int VBS_NAVI_TMC_SetHUD_Display_Msg2(void *, VbsNaviHudMsg2 *,
                                                void *, void *, void *);

namespace {

// Self-gate: only act if we are actually inside the navigation
// service PID. dlopen(RTLD_NOLOAD) returns non-NULL iff svcjcinavi.so
// is already mapped in this process.
constexpr const char *kSvcjcinaviSo = "/jci/navi/svcjcinavi.so";

// Where the real HUD setters live (libjcivbsnaviclient.so is a
// DT_NEEDED of svcjcinavi.so).
constexpr const char *kVbsClientSoname  = "libjcivbsnaviclient.so";
constexpr const char *kVbsClientAbspath = "/jci/lib/libjcivbsnaviclient.so";

// --- OEM internal reached by anchor + fixed offset ----------------
//
// svcjcinavi blanks the OUTBOUND street strip in some markets: for HUD
// types 1/2 in certain region/language combinations (notably EU) it
// repoints the strip to a single space instead of the real street. The
// street it actually received still lives in the OEM's own
// current_StreetName buffer — only the outbound pointer is blanked. We
// read that buffer so the AAP street survives the blanking.
//
// current_StreetName is NOT a dynamic symbol (dlsym can't see it), but
// svcjcinavi.so ships with its full .symtab, so we compute its address
// from the one dynamically-exported anchor (GetServiceInterfaces) plus a
// fixed file offset, exactly like the blmjciaapa anchor-and-offset
// thunks. File offsets are FW 74.00.324A, harvested with nm; the
// svcjcinavi.so binary is byte-identical across this version's NA and EU
// builds (verified by sha256), so one set of offsets serves both
// markets. Re-harvest with `nm -a` after any OEM update.
constexpr const char *kAnchorSym            = "GetServiceInterfaces";
constexpr uintptr_t   kOffAnchor            = 0x00019008;  // GetServiceInterfaces (exported)
constexpr uintptr_t   kOffCurrentStreetName = 0x000aab98;  // current_StreetName (255 B)

// AAP guidance is event-driven (the svcnavi transport emits only on
// change), so we do NOT key activity off a feed cadence. Ownership is
// set explicitly: a real AAP frame arms it, an empty AAP frame (the
// blanking frame AAP sends when guidance stops) clears it. This
// timeout is only a safety net for the case where AAP dies without
// sending its blanking frame (e.g. the jciAAPA process crashes) — long
// enough never to expire mid-drive, short enough to eventually hand
// the HUD back to OEM nav. time() (1 s granularity, libc — no librt).
constexpr time_t kAapTimeoutSec = 5 * 60;

typedef int (*SetFn)(void *, VbsNaviHudDisplay *, void *, void *, void *);
typedef int (*Msg2Fn)(void *, VbsNaviHudMsg2 *, void *, void *, void *);

bool   g_gate_done = false;
bool   g_enabled   = false;

void  *g_vbs_handle = nullptr;
SetFn  g_real_set   = nullptr;
Msg2Fn g_real_msg2  = nullptr;

// The OEM's un-blanked street buffer (current_StreetName), resolved once
// via the anchor in ensure_gate(). nullptr if we are not in the
// svcjcinavi PID or the anchor failed to resolve, in which case the
// Msg2 hook falls back to the (possibly blanked) strip pointer.
const char *g_cur_street = nullptr;

// Which flows read g_cur_street: force_street_name (AAP frames) and
// force_street_name_native (the stock nav's own route frames).
#ifdef HUD_NAV_DIAG
NAV_DIAG_SINK(g_diag, "merge");
const char *g_diag_action = "";   // maneuver-frame decision, logged with its strip
uint32_t    g_diag_man    = 0;
#endif

bool g_unblank_aap    = false;
bool g_unblank_native = false;

// Merge state — all accessed only from svcjcinavi's single sender
// thread (thUpdateGuidanceChangeToHUD), so plain variables are safe.
bool     g_have_aap   = false;
uint32_t g_aap_man    = 0;
uint16_t g_aap_dist   = 0;
uint8_t  g_aap_dunit  = 0;
time_t   g_aap_last   = 0;

// What the street-strip hook should do with the strip svcjcinavi emits
// back-to-back right after each maneuver frame. Set by the maneuver
// hook (which knows the generation's origin), consumed by the Msg2
// hook. Re-set on every maneuver frame, so never stale.
//   CAPTURE — AAP-origin strip: copy its street into g_aap_street, pass.
//   REPLACE — OEM-origin strip while AAP active: overwrite its street
//             with the captured AAP street, pass.
//   PASSTHROUGH — AAP idle (or the AAP blanking frame): pass untouched.
//   DROP    — OEM-origin strip while CarPlay owns the HUD: swallow it,
//             like the maneuver frame it belongs to.
//   UNBLANK — OEM-origin strip of a native route frame (maneuver != 0)
//             with no projection active and force_street_name_native:
//             re-point it at the street svcjcinavi received.
enum StreetAction { STREET_PASSTHROUGH, STREET_CAPTURE, STREET_REPLACE,
                    STREET_DROP, STREET_UNBLANK };
StreetAction g_street_action = STREET_PASSTHROUGH;

// Captured AAP street name (from the AAP-origin Msg2). The real setter
// copies the string synchronously, so a plain buffer pointed at for the
// duration of the forwarded call is safe. A null AAP street (its "no
// street" request) is stored as the empty string, which the OEM setter
// marshals as a blank street line.
char g_aap_street[128] = { 0 };

// Copy of current_StreetName for a native route strip (STREET_UNBLANK).
char g_native_street[128] = { 0 };

// Last OEM speed seen. Initialised to 0 — the value OEM nav itself
// sends when there is no speed limit — so AAP frames carry a "no speed
// limit" until a real OEM speed has arrived. Safer than the sentinel:
// 0 is a genuine OEM value, whereas the sentinel is reserved for the
// AAP-origin discriminator and must never appear on a forwarded frame.
uint16_t g_oem_speed  = 0;
uint8_t  g_oem_sunit  = 0;

// Last speed written to hud_share::kOemSpeedFile, so we only rewrite the
// file on a change (OEM frames repeat the same speed ~1 Hz on a route).
bool     g_speed_published = false;
uint16_t g_pub_speed       = 0;
uint8_t  g_pub_sunit       = 0;

void publish_speed_if_changed()
{
    if (g_speed_published && g_pub_speed == g_oem_speed &&
        g_pub_sunit == g_oem_sunit) {
        return;
    }
    if (hud_share::publish_oem_speed(g_oem_speed, g_oem_sunit)) {
        g_speed_published = true;
        g_pub_speed = g_oem_speed;
        g_pub_sunit = g_oem_sunit;
        LOGV("published OEM speed=%u unit=%u for CarPlay",
             static_cast<unsigned>(g_oem_speed), static_cast<unsigned>(g_oem_sunit));
    } else {
        LOGW("could not write %s (errno=%d)", hud_share::kOemSpeedFile, errno);
    }
}

void ensure_gate()
{
    if (g_gate_done) {
        return;
    }
    g_gate_done = true;

    // Read libpatch.conf (sibling of this .so) once. force_street_name
    // gates the current_StreetName un-blank resolution below; everything
    // else in this function is unconditional.
    libpatch_config::load(reinterpret_cast<const void *>(&ensure_gate));

    void *h = dlopen(kSvcjcinaviSo, RTLD_NOW | RTLD_NOLOAD);
    g_enabled = (h != nullptr);
    if (g_enabled) {
        // Resolve the OEM's un-blanked street buffer (current_StreetName)
        // ONLY when force_street_name or force_street_name_native is set. Left null, the Msg2 hook
        // captures from the strip pointer (native OEM behaviour: markets
        // that blank the street keep blanking it). Load bias =
        // runtime(anchor) - file_offset(anchor); the library stays mapped
        // for the PID's lifetime, so the dlclose below only drops our
        // extra NOLOAD refcount — the computed address stays valid.
        g_unblank_aap    = libpatch_config::force_street_name();
        g_unblank_native = libpatch_config::force_street_name_native();
        if (g_unblank_aap || g_unblank_native) {
            void *anchor = dlsym(h, kAnchorSym);
            if (anchor != nullptr) {
                uintptr_t base =
                    reinterpret_cast<uintptr_t>(anchor) - kOffAnchor;
                g_cur_street = reinterpret_cast<const char *>(
                    base + kOffCurrentStreetName);
                LOGD("force_street_name: resolved current_StreetName=%p "
                     "(base=%p)",
                     reinterpret_cast<const void *>(g_cur_street),
                     reinterpret_cast<void *>(base));
            } else {
                LOGW("force_street_name: anchor %s unresolved — falling "
                     "back to the (possibly blanked) Msg2 strip",
                     kAnchorSym);
            }
        } else {
            LOGD("force_street_name(_native)=false — leaving OEM street "
                 "handling intact (strip)");
        }
        // We only need the boolean "is it mapped" plus the anchor; drop
        // the extra refcount RTLD_NOLOAD took so we don't leak it.
        dlclose(h);
        LOGD("self-gate: enabled (svcjcinavi.so mapped)");
        // Announce ourselves to the CarPlay shim right away ("no limit
        // yet"), so it switches to cooperative mode before the first
        // speed-carrying OEM frame arrives.
        publish_speed_if_changed();
    } else {
        LOGW("self-gate: svcjcinavi.so not mapped in this pid — "
             "merge disabled, transparent passthrough");
    }

    // Resolve both real HUD setters UNCONDITIONALLY — even in the wrong
    // process. g_enabled gates only the rewriting; resolution must not
    // be gated, because the disabled path still forwards to the real
    // implementation (transparent passthrough). If we skipped resolution
    // when disabled, a wrong-process call would have no real impl to
    // forward to and would be dropped instead of passed through.
    g_real_set = reinterpret_cast<SetFn>(resolve_real_symbol(
        "VBS_NAVI_SetHUDDisplayMsgReq", kVbsClientSoname, kVbsClientAbspath,
        reinterpret_cast<void *>(&VBS_NAVI_SetHUDDisplayMsgReq),
        &g_vbs_handle));
    if (g_real_set == nullptr) {
        LOGC("could not resolve real VBS_NAVI_SetHUDDisplayMsgReq — "
             "frames will be dropped this session");
    }

    g_real_msg2 = reinterpret_cast<Msg2Fn>(resolve_real_symbol(
        "VBS_NAVI_TMC_SetHUD_Display_Msg2", kVbsClientSoname, kVbsClientAbspath,
        reinterpret_cast<void *>(&VBS_NAVI_TMC_SetHUD_Display_Msg2),
        &g_vbs_handle));
    if (g_real_msg2 == nullptr) {
        LOGC("could not resolve real VBS_NAVI_TMC_SetHUD_Display_Msg2");
    }
}

bool aap_active()
{
    return g_have_aap && (time(nullptr) - g_aap_last) <= kAapTimeoutSec;
}

} // namespace

// Exported PLT shadows. Default visibility so the loader binds
// svcjcinavi.so's imports to these.

extern "C" PRELOAD_EXPORT
int VBS_NAVI_SetHUDDisplayMsgReq(void *conn, VbsNaviHudDisplay *disp,
                                 void *unused, void *cb, void *user)
{
    ensure_gate();

    // Merge disabled (wrong process), unresolved real impl, or NULL
    // frame: transparent passthrough — forward untouched to the real
    // setter (or return 0 only if it genuinely could not be resolved).
    // Tag the next strip PASSTHROUGH so it can't act on a prior
    // generation's action if we bail before classifying this one.
    if (!g_enabled || g_real_set == nullptr || disp == nullptr) {
        g_street_action = STREET_PASSTHROUGH;
        return g_real_set ? g_real_set(conn, disp, unused, cb, user) : 0;
    }

    if (disp->displaySpeedLimit == kAapSpeedSentinel) {
        if (disp->nextManeuverInfo == 0) {
            // Empty AAP frame: AAP guidance has stopped and wants its
            // maneuver cleared. Relinquish ownership so subsequent OEM
            // frames pass through natively again. Let this blank frame
            // (and its blank street strip) through so the HUD clears.
            g_have_aap         = false;
            g_street_action    = STREET_PASSTHROUGH;
            LOGV("AAP empty frame (man=0): releasing AAP ownership");
        } else {
            // Real AAP guidance: capture the maneuver block and (re)arm
            // the activity window.
            g_aap_man   = disp->nextManeuverInfo;
            g_aap_dist  = disp->distanceValue;
            g_aap_dunit = disp->distanceUnit;
            g_have_aap  = true;
            g_aap_last  = time(nullptr);

            // The strip that follows is AAP's street: capture it.
            g_street_action = STREET_CAPTURE;

            LOGV("AAP frame: man=%u dist=%u  splice speed=0x%x unit=%u",
                 static_cast<unsigned>(g_aap_man), static_cast<unsigned>(g_aap_dist),
                 static_cast<unsigned>(g_oem_speed), static_cast<unsigned>(g_oem_sunit));
        }

        // Splice the remembered OEM speed into the AAP frame either way.
        disp->displaySpeedLimit = g_oem_speed;
        disp->displaySpeedUnit  = g_oem_sunit;
    } else {
        // OEM-origin frame: remember its speed; while AAP is active,
        // overwrite its (blank) maneuver with AAP's so it stops
        // blanking and becomes an identical re-assertion. text_ID3 is
        // left as svcjcinavi computed it.
        g_oem_speed = disp->displaySpeedLimit;
        g_oem_sunit = disp->displaySpeedUnit;
        publish_speed_if_changed();

        if (hud_share::carplay_is_active(time(nullptr))) {
            // CarPlay paints this speed in its own frames; forwarding the
            // OEM's blank maneuver would only blink against them.
            g_street_action = STREET_DROP;
            NAV_DIAG(nav_diag::text(&g_diag, "oem-dropped", "man=%u speed=%u unit=%u (CarPlay owns HUD)",
                                    static_cast<unsigned>(disp->nextManeuverInfo),
                                    static_cast<unsigned>(g_oem_speed),
                                    static_cast<unsigned>(g_oem_sunit)));
            LOGV("OEM frame: speed=0x%x unit=%u  dropped (CarPlay owns HUD)",
                 static_cast<unsigned>(g_oem_speed), static_cast<unsigned>(g_oem_sunit));
            return 0;
        }

        if (aap_active()) {
            disp->nextManeuverInfo = g_aap_man;
            disp->distanceValue    = g_aap_dist;
            disp->distanceUnit     = g_aap_dunit;
            // Overwrite the OEM strip that follows with AAP's street.
            g_street_action = STREET_REPLACE;
            LOGV("OEM frame: speed=0x%x unit=%u  spliced AAP man=%u dist=%u",
                 static_cast<unsigned>(g_oem_speed), static_cast<unsigned>(g_oem_sunit),
                 static_cast<unsigned>(g_aap_man), static_cast<unsigned>(g_aap_dist));
        } else if (g_unblank_native && g_cur_street != nullptr &&
                   disp->nextManeuverInfo != 0) {
            // Stock-nav route frame: let its street through even where the
            // market blanks it. Speed-only frames (no maneuver) keep the
            // OEM's blank strip, so no stale street lingers off-route.
            g_street_action = STREET_UNBLANK;
            LOGV("OEM frame (AAP idle): man=%u speed=0x%x — native street un-blank",
                 static_cast<unsigned>(disp->nextManeuverInfo),
                 static_cast<unsigned>(g_oem_speed));
        } else {
            g_street_action = STREET_PASSTHROUGH;
            LOGV("OEM frame (AAP idle): speed=0x%x unit=%u — passthrough",
                 static_cast<unsigned>(g_oem_speed), static_cast<unsigned>(g_oem_sunit));
        }
    }

#ifdef HUD_NAV_DIAG
    g_diag_man    = disp->nextManeuverInfo;
    g_diag_action = g_street_action == STREET_CAPTURE ? "aa-frame"
                  : g_street_action == STREET_REPLACE ? "oem-spliced-aa"
                  : g_street_action == STREET_UNBLANK ? "oem-native-unblank"
                  : "pass";
#endif
    return g_real_set(conn, disp, unused, cb, user);
}

extern "C" PRELOAD_EXPORT
int VBS_NAVI_TMC_SetHUD_Display_Msg2(void *conn, VbsNaviHudMsg2 *msg2,
                                     void *unused, void *cb, void *user)
{
    ensure_gate();

    // Merge disabled (wrong process), unresolved real impl, or NULL
    // frame: transparent passthrough — forward untouched to the real
    // setter (or return 0 only if it genuinely could not be resolved).
    if (!g_enabled || g_real_msg2 == nullptr || msg2 == nullptr) {
        return g_real_msg2 ? g_real_msg2(conn, msg2, unused, cb, user) : 0;
    }

    // svcjcinavi emits the street strip back-to-back right after its
    // maneuver frame, so the maneuver hook has tagged this strip's
    // origin. Mirror the maneuver handling: capture AAP's street, or
    // overwrite the OEM strip with it. We rewrite only the street
    // STRING — never syncBit: it is the current generation's sync,
    // matching the maneuver frame's text_ID3, and that pairing is how
    // the HUD knows the maneuver and street belong together.
    if (g_street_action == STREET_CAPTURE) {
        // Record AAP's street. Prefer the OEM's un-blanked
        // current_StreetName (g_cur_street): in markets that blank the
        // outbound strip (e.g. EU, HUD type 1/2) the strip pointer here
        // is already a single space, but current_StreetName still holds
        // the real street svcjcinavi received. This hook runs on the
        // sender thread while it holds the guidance mutex that also
        // guards current_StreetName, so the read is consistent with the
        // frame being sent. Fall back to the strip pointer if the anchor
        // didn't resolve. A null/empty street is stored as "".
        const char *src = (g_unblank_aap && g_cur_street)
                              ? g_cur_street : msg2->guidancePointName;
        libpatch::copy_utf8_truncated(g_aap_street, sizeof(g_aap_street), src);
        // Re-point this AAP-origin strip at our captured copy so the AAP
        // frame itself shows the real street rather than the market
        // blank — identical to the OEM-cadence REPLACE below, so the two
        // cadences stay flicker-free.
        msg2->guidancePointName = g_aap_street;
        LOGV("Msg2 capture: AAP street \"%s\"%s", g_aap_street,
             (g_unblank_aap && g_cur_street) ? " (current_StreetName)" : " (strip)");
    } else if (g_street_action == STREET_REPLACE) {
        msg2->guidancePointName = g_aap_street;
        LOGV("Msg2 replace: OEM strip -> AAP street \"%s\"", g_aap_street);
    } else if (g_street_action == STREET_UNBLANK) {
        // Same consistency argument as CAPTURE: we run on the sender thread
        // under the guidance mutex that guards current_StreetName. An empty
        // street stays the OEM strip (the HUD draws garbage for "").
        libpatch::copy_utf8_truncated(g_native_street, sizeof(g_native_street),
                                      g_cur_street);
        if (g_native_street[0] != '\0') {
            msg2->guidancePointName = g_native_street;
        }
        LOGV("Msg2 un-blank: native street \"%s\"", g_native_street);
    } else if (g_street_action == STREET_DROP) {
        g_street_action = STREET_PASSTHROUGH;
        LOGV("Msg2 drop: OEM strip (CarPlay owns HUD)");
        return 0;
    }

    NAV_DIAG(nav_diag::text(&g_diag, g_diag_action, "man=%u speed=%u unit=%u street=\"%.120s\"",
                            static_cast<unsigned>(g_diag_man), static_cast<unsigned>(g_oem_speed),
                            static_cast<unsigned>(g_oem_sunit),
                            msg2->guidancePointName ? msg2->guidancePointName : "(null)"));
    return g_real_msg2(conn, msg2, unused, cb, user);
}
