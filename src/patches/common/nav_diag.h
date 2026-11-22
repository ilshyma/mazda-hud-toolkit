// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Raw navigation capture for the diag build (-DHUD_NAV_DIAG, tools/package.sh
// diag). Each shim appends what it receives from the phone (and the merge
// shim its per-frame decisions) to /data_persist/hud-probe/live/<name>.log,
// one line per event:
//
//   <unix ts>.<ms> <tag> <len> <hex bytes> [| text]
//
// so a drive can be replayed at home through the same decoders (nav.cpp for
// CarPlay iAP2, hud_nav16 for Android Auto). Nothing is written unless the
// live/ directory exists — install/hud_probe.sh creates it on "start" and
// collects + truncates the files on "stop" — and each file stops growing at
// kMaxBytes. Writes are O_APPEND, so the probe can truncate under us.
//
// Location data: these logs contain street names and maneuvers. They stay on
// the unit until fetched; the ship build compiles all of this out.

#ifndef LIBPATCH_COMMON_NAV_DIAG_H
#define LIBPATCH_COMMON_NAV_DIAG_H

#ifdef HUD_NAV_DIAG

#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

namespace nav_diag {

constexpr const char *kDir      = "/data_persist/hud-probe/live";
constexpr off_t       kMaxBytes = 24 * 1024 * 1024;
constexpr time_t      kRetrySec = 5;   // re-check for live/ while it is absent

struct Sink {
    const char     *name;
    int             fd;
    time_t          last_try;
    pthread_mutex_t mu;
};

#define NAV_DIAG_SINK(var, name) \
    static nav_diag::Sink var = { name, -1, 0, PTHREAD_MUTEX_INITIALIZER }

// Called with s->mu held. Returns an fd or -1.
inline int sink_fd(Sink *s)
{
    if (s->fd >= 0) {
        struct stat st;
        // The probe moved/removed live/ (stop) or the file hit the cap.
        if (fstat(s->fd, &st) != 0 || st.st_nlink == 0) {
            close(s->fd);
            s->fd = -1;
        } else if (st.st_size >= kMaxBytes) {
            return -1;
        } else {
            return s->fd;
        }
    }
    time_t now = time(nullptr);
    if (now - s->last_try < kRetrySec && now >= s->last_try) {
        return -1;
    }
    s->last_try = now;
    char path[128];
    snprintf(path, sizeof(path), "%s/%s.log", kDir, s->name);
    s->fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0644);
    return s->fd;
}

inline void write_line(Sink *s, const char *line, size_t n)
{
    pthread_mutex_lock(&s->mu);
    int fd = sink_fd(s);
    if (fd >= 0) {
        ssize_t w = write(fd, line, n);
        (void)w;   // best effort: a capture must never disturb the HUD path
    }
    pthread_mutex_unlock(&s->mu);
}

inline size_t stamp(char *out, size_t cap)
{
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    int n = snprintf(out, cap, "%ld.%03ld ", static_cast<long>(tv.tv_sec),
                     static_cast<long>(tv.tv_usec / 1000));
    return n > 0 ? static_cast<size_t>(n) : 0;
}

// Raw bytes (hex) plus an optional printable note.
inline void bytes(Sink *s, const char *tag, const void *data, size_t len,
                  const char *note = nullptr)
{
    static const char hexd[] = "0123456789abcdef";
    const size_t kMaxData = 4096;
    if (len > kMaxData) len = kMaxData;
    char line[64 + 2 * 4096 + 300];
    size_t n = stamp(line, sizeof(line));
    n += static_cast<size_t>(snprintf(line + n, sizeof(line) - n, "%s %u ",
                                      tag, static_cast<unsigned>(len)));
    const unsigned char *p = static_cast<const unsigned char *>(data);
    for (size_t i = 0; i < len; ++i) {
        line[n++] = hexd[p[i] >> 4];
        line[n++] = hexd[p[i] & 15];
    }
    if (note) {
        n += static_cast<size_t>(snprintf(line + n, sizeof(line) - n - 1, " | %.250s", note));
    }
    line[n++] = '\n';
    write_line(s, line, n);
}

// Free-form event line.
__attribute__((format(printf, 3, 4)))
inline void text(Sink *s, const char *tag, const char *fmt, ...)
{
    char line[512];
    size_t n = stamp(line, sizeof(line));
    n += static_cast<size_t>(snprintf(line + n, sizeof(line) - n, "%s - ", tag));
    va_list ap;
    va_start(ap, fmt);
    const size_t room = sizeof(line) - n - 1;          // keep one byte for '\n'
    int m = vsnprintf(line + n, room, fmt, ap);
    va_end(ap);
    if (m > 0) n += static_cast<size_t>(m) < room ? static_cast<size_t>(m) : room - 1;
    line[n++] = '\n';
    write_line(s, line, n);
}

} // namespace nav_diag

#define NAV_DIAG(stmt) do { stmt; } while (0)

#else   // !HUD_NAV_DIAG

#define NAV_DIAG(stmt) do { } while (0)

#endif  // HUD_NAV_DIAG

#endif  // LIBPATCH_COMMON_NAV_DIAG_H
