// Implementation of the debug-only com.jci.vbs.navi(.tmc) eavesdropper.
// See navi_monitor.h for the rationale and the release/debug gating.

#define LOG_TAG "NAVIMON"
#include "../log.h"
#include "navi_monitor.h"

#ifdef DEBUG

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include "common/thread_util.h"

namespace {

// On-device dbus-monitor (confirmed present in the 74.00.324A
// firmware at /usr/bin/dbus-monitor).
constexpr const char *kMonitorBin = "/usr/bin/dbus-monitor";

// Fallback service-bus address if $JCI_SERVICE_BUS is somehow unset in
// our environment. The service dbus-daemon listens on this UNIX socket
// (see the shipped /etc/dbus-1/service.conf <listen> entry).
constexpr const char *kFallbackAddr = "unix:path=/tmp/dbus_service_socket";

// Watch expressions (match rules). dbus-monitor on this libdbus adds
// eavesdrop=true to each rule itself, so we only specify the filter:
// every message addressed TO each navigation service name.
constexpr const char *kMatchNavi    = "destination=com.jci.vbs.navi";
constexpr const char *kMatchNaviTmc = "destination=com.jci.vbs.navi.tmc";

// Lines containing this substring are dropped before logging, along
// with the single line that immediately follows each match: the
// NaviCompassVal member fires continuously and floods the log, and
// dbus-monitor prints its argument body on the next line.
constexpr const char *kLineSuppress = "member=NaviCompassVal";

pthread_mutex_t g_mu      = PTHREAD_MUTEX_INITIALIZER;
bool            g_running = false;
pid_t           g_pid     = -1;
int             g_read_fd = -1;   // parent's read end of the pipe
pthread_t       g_reader  = 0;

// Reader thread: drains the child's merged stdout/stderr and re-emits
// each complete line through the patch log. The pipe fd is passed in
// via the thread arg so the thread never races on a global.
void *reader_main(void *arg)
{
    int         fd = static_cast<int>(reinterpret_cast<intptr_t>(arg));
    char        buf[1024];
    std::string line;
    bool        suppress_next = false;   // drop the line after a match

    for (;;) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n > 0) {
            for (ssize_t i = 0; i < n; ++i) {
                char c = buf[i];
                if (c == '\n') {
                    if (line.find(kLineSuppress) != std::string::npos) {
                        suppress_next = true;   // drop this + next line
                    } else if (suppress_next) {
                        suppress_next = false;  // drop this one, reset
                    } else {
                        LOGV("%s", line.c_str());
                    }
                    line.clear();
                } else if (c != '\r') {
                    line.push_back(c);
                }
            }
            continue;
        }
        if (n == 0) {
            break;              // EOF: child closed its stdout (exited)
        }
        if (errno == EINTR) {
            continue;           // interrupted, retry
        }
        break;                  // hard read error
    }

    if (!line.empty() &&
        line.find(kLineSuppress) == std::string::npos && !suppress_next) {
        LOGV("%s", line.c_str());   // flush a trailing unterminated line
    }
    return nullptr;
}

} // namespace

void navi_monitor_post_aap_create_session(void)
{
    pthread_mutex_lock(&g_mu);
    if (g_running) {
        pthread_mutex_unlock(&g_mu);
        return;
    }

    const char *addr = getenv("JCI_SERVICE_BUS");
    if (addr == nullptr || *addr == '\0') {
        addr = kFallbackAddr;
        LOGW("JCI_SERVICE_BUS unset; falling back to %s", addr);
    }

    int pipefd[2];
    if (pipe(pipefd) != 0) {
        LOGE("pipe() failed: %s", strerror(errno));
        pthread_mutex_unlock(&g_mu);
        return;
    }
    // Keep the read end out of the child.
    fcntl(pipefd[0], F_SETFD, FD_CLOEXEC);

    pid_t pid = fork();
    if (pid < 0) {
        LOGE("fork() failed: %s", strerror(errno));
        close(pipefd[0]);
        close(pipefd[1]);
        pthread_mutex_unlock(&g_mu);
        return;
    }

    if (pid == 0) {
        // Child: between fork() and execl() only async-signal-safe
        // calls (no malloc, no LOG*) so a fork in this multithreaded
        // process can't deadlock on an inherited libc lock.
        dup2(pipefd[1], STDOUT_FILENO);
        dup2(pipefd[1], STDERR_FILENO);
        close(pipefd[0]);
        close(pipefd[1]);
        execl(kMonitorBin, "dbus-monitor",
              "--address", addr,
              kMatchNavi, kMatchNaviTmc,
              static_cast<char *>(nullptr));
        _exit(127);             // execl only returns on failure
    }

    // Parent.
    close(pipefd[1]);           // only the child writes
    g_pid     = pid;
    g_read_fd = pipefd[0];

    if (preload_thread_create(&g_reader, reader_main,
                              reinterpret_cast<void *>(
                                  static_cast<intptr_t>(pipefd[0]))) != 0) {
        LOGE("pthread_create(reader) failed: %s", strerror(errno));
        // Can't drain the child — tear it back down.
        kill(g_pid, SIGTERM);
        waitpid(g_pid, nullptr, 0);
        close(g_read_fd);
        g_read_fd = -1;
        g_pid     = -1;
        pthread_mutex_unlock(&g_mu);
        return;
    }

    g_running = true;
    LOGD("dbus-monitor started (pid=%d, addr=%s)", g_pid, addr);
    pthread_mutex_unlock(&g_mu);
}

void navi_monitor_pre_aap_destroy_session(void)
{
    pthread_mutex_lock(&g_mu);
    if (!g_running) {
        pthread_mutex_unlock(&g_mu);
        return;
    }

    pid_t     pid     = g_pid;
    int       read_fd = g_read_fd;
    pthread_t reader  = g_reader;
    g_running = false;
    g_pid     = -1;
    g_read_fd = -1;
    pthread_mutex_unlock(&g_mu);

    // Stop the child first; closing its stdout makes the reader hit
    // EOF and return on its own.
    if (pid > 0) {
        kill(pid, SIGTERM);
        waitpid(pid, nullptr, 0);   // reap; ignore result (may ECHILD)
    }
    pthread_join(reader, nullptr);
    if (read_fd >= 0) {
        close(read_fd);
    }
    LOGD("dbus-monitor stopped (pid=%d)", pid);
}

#else  // !DEBUG — release builds ship no eavesdropper.

void navi_monitor_post_aap_create_session(void) {}
void navi_monitor_pre_aap_destroy_session(void) {}

#endif // DEBUG
