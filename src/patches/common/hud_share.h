// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Cross-process HUD hand-off between the svcjcinavi merge shim and the
// CarPlay shim (blmjcicarplay).
//
// Android Auto reaches the HUD *through* svcjcinavi (svcnavi transport), so
// the merge shim can splice the OEM speed limit into its frames in-process.
// CarPlay writes the HUD directly (com.jci.vbs.navi), so the two shims live in
// different PIDs and need a side channel. Two tiny tmpfs files carry it:
//
//   kOemSpeedFile      "<limit> <unit>\n"  written by the merge shim whenever
//                      the OEM nav (NNG via svcjcinavi) sends a new HUD speed.
//                      The values are copied verbatim from the OEM frame
//                      (displaySpeedLimit / displaySpeedUnit), so CarPlay
//                      paints exactly what the stock navigation would. The
//                      file's existence also tells the CarPlay shim that the
//                      merge shim is running (cooperative mode).
//
//   kCarplayActiveFile "<unix ts>\n"       refreshed (~1 Hz) by the CarPlay
//                      shim while CarPlay route guidance owns the HUD; removed
//                      when it hands the HUD back. While it is fresh the merge
//                      shim drops the OEM frames (which only carry a blank
//                      maneuver + speed during projection) so they cannot
//                      flicker against CarPlay's maneuver. A crashed CarPlay
//                      process stops refreshing it and the OEM resumes after
//                      kCarplayActiveTtlSec.
//
// Both files live on /tmp (tmpfs, cleared at boot): no flash wear and no
// stale state across a reboot whose RTC restarts at 1970. Writes go to a
// private temp name and are rename()d into place, so a reader never sees a
// torn value and a pre-planted symlink at the final path is replaced rather
// than followed.
//
// Header-only and logging-free on purpose: the CarPlay shim and the
// svcjcinavi shim use different logging macros.

#ifndef LIBPATCH_COMMON_HUD_SHARE_H
#define LIBPATCH_COMMON_HUD_SHARE_H

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

namespace hud_share {

constexpr const char *kOemSpeedFile      = "/tmp/hud_oem_speed";
constexpr const char *kCarplayActiveFile = "/tmp/hud_carplay_active";

// CarPlay refreshes the active marker at ~1 Hz; three missed refreshes mean
// the CarPlay shim is gone and the OEM frames must flow again.
constexpr time_t kCarplayActiveTtlSec = 3;

inline bool write_file_atomic(const char *path, const char *text)
{
    char tmp[96];
    int n = snprintf(tmp, sizeof(tmp), "%s.%d", path, static_cast<int>(getpid()));
    if (n <= 0 || static_cast<size_t>(n) >= sizeof(tmp)) {
        return false;
    }
    unlink(tmp);   // leftover from a crashed writer with a recycled pid
    int fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (fd < 0) {
        return false;
    }
    size_t len = strlen(text);
    bool ok = write(fd, text, len) == static_cast<ssize_t>(len);
    ok = (close(fd) == 0) && ok;
    if (!ok || rename(tmp, path) != 0) {
        unlink(tmp);
        return false;
    }
    return true;
}

// Reads at most cap-1 bytes. Returns false if the file is absent or empty.
inline bool read_small_file(const char *path, char *buf, size_t cap)
{
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) {
        return false;
    }
    ssize_t n = read(fd, buf, cap - 1);
    close(fd);
    if (n <= 0) {
        return false;
    }
    buf[n] = '\0';
    return true;
}

// Strict unsigned decimal: optional leading blanks, digits only (no sign),
// rejected as soon as it exceeds max. Advances p past the number.
inline bool parse_uint(const char *&p, unsigned long max, unsigned long *out)
{
    while (*p == ' ' || *p == '\t') ++p;
    if (*p < '0' || *p > '9') {
        return false;
    }
    unsigned long v = 0;
    while (*p >= '0' && *p <= '9') {
        v = v * 10 + static_cast<unsigned long>(*p - '0');
        if (v > max) {
            return false;
        }
        ++p;
    }
    *out = v;
    return true;
}

inline bool only_blanks(const char *p)
{
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') ++p;
    return *p == '\0';
}

// --- OEM speed (writer: svcjcinavi merge shim) ---------------------------

inline bool publish_oem_speed(uint16_t limit, uint8_t unit)
{
    char text[32];
    snprintf(text, sizeof(text), "%u %u\n",
             static_cast<unsigned>(limit), static_cast<unsigned>(unit));
    return write_file_atomic(kOemSpeedFile, text);
}

// --- OEM speed (reader: CarPlay shim) -------------------------------------
//
// false = no merge shim running (file absent / unparsable).
inline bool read_oem_speed(uint16_t *limit, uint8_t *unit)
{
    char buf[32];
    if (!read_small_file(kOemSpeedFile, buf, sizeof(buf))) {
        return false;
    }
    const char *p = buf;
    unsigned long l = 0, u = 0;
    if (!parse_uint(p, 0xFFFFu, &l) || (*p != ' ' && *p != '\t') ||
        !parse_uint(p, 0xFFu, &u) || !only_blanks(p)) {
        return false;
    }
    *limit = static_cast<uint16_t>(l);
    *unit  = static_cast<uint8_t>(u);
    return true;
}

// --- CarPlay ownership marker ----------------------------------------------

inline void carplay_mark_active(time_t now)
{
    char text[32];
    snprintf(text, sizeof(text), "%ld\n", static_cast<long>(now));
    write_file_atomic(kCarplayActiveFile, text);
}

inline void carplay_mark_inactive()
{
    unlink(kCarplayActiveFile);
}

inline bool carplay_is_active(time_t now)
{
    char buf[32];
    if (!read_small_file(kCarplayActiveFile, buf, sizeof(buf))) {
        return false;
    }
    const char *p = buf;
    unsigned long uts = 0;
    if (!parse_uint(p, 0x7FFFFFFFul, &uts) || !only_blanks(p)) {   // 32-bit time_t on the CMU
        return false;
    }
    long ts = static_cast<long>(uts);
    // A future ts can only come from a clock step (GPS time fix after a
    // 1970 boot); treat it as stale rather than latching OEM frames off.
    return ts <= static_cast<long>(now) + 2 &&
           static_cast<long>(now) - ts <= static_cast<long>(kCarplayActiveTtlSec);
}

} // namespace hud_share

#endif // LIBPATCH_COMMON_HUD_SHARE_H
