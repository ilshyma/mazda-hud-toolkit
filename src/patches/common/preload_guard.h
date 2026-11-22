// Shared LD_PRELOAD process guards used by each patch's constructor.
//
//  * preload_read_cmdline()        — read /proc/self/cmdline (printable).
//  * preload_is_launcher_process() — true iff argv[0] basename is
//    "sm_svclauncher" (the only process that dlopen's an OEM service
//    .so we'd be patching). The CMU runs a once-a-second watchdog
//    shell (`sh -c killall ...`) whose throwaway children also inherit
//    LD_PRELOAD; gating on this keeps us from logging / installing
//    handlers in those.
//  * preload_install_fatal_handler() — install an async-signal-safe
//    SIGSEGV/BUS/ABRT/FPE/ILL handler that dumps siginfo + register
//    state + /proc/self/maps, then re-raises so the kernel still
//    writes a core dump.
//
// All log literals are woven with LIBPATCH_NAME (defined by the
// including patch's log.h, included before this header) so each
// library tags its own crash output. Functions are `static inline`
// so each patch's main.cpp TU gets its own copy — one per .so.
//
// Async-signal-safety: the handler uses only write / snprintf-into-a-
// stack-buffer / signal / raise / getpid / syscall / open / read /
// close / backtrace*, all of which are safe per POSIX. It deliberately
// avoids the LOG* macros (fprintf+fflush) and dladdr.

#ifndef LIBPATCH_COMMON_PRELOAD_GUARD_H
#define LIBPATCH_COMMON_PRELOAD_GUARD_H

#ifndef LIBPATCH_NAME
#  error "include the patch's log.h (which defines LIBPATCH_NAME) before preload_guard.h"
#endif

#include <execinfo.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/ucontext.h>
#include <unistd.h>

// gettid() isn't in glibc 2.20 (the device's ancient libc). Fall
// back to syscall(SYS_gettid) — async-signal-safe via the raw
// syscall path.
static inline pid_t preload_gettid_compat(void)
{
#ifdef SYS_gettid
    return (pid_t)syscall(SYS_gettid);
#else
    return -1;
#endif
}

static inline void preload_fatal_signal_handler(int sig, siginfo_t *info,
                                                void *ucontext)
{
    static const char hdr[] =
        "\n[libpatch-" LIBPATCH_NAME "][C] *** fatal signal caught ***\n";
    (void)!write(STDERR_FILENO, hdr, sizeof(hdr) - 1);

    char buf[256];
    int  m;

    m = snprintf(buf, sizeof(buf),
                 "[libpatch-" LIBPATCH_NAME "][C] signal=%d pid=%d tid=%d "
                 "si_code=%d si_addr=%p\n",
                 sig, (int)getpid(), (int)preload_gettid_compat(),
                 info ? info->si_code : -1,
                 info ? info->si_addr : nullptr);
    if (m > 0) (void)!write(STDERR_FILENO, buf, (size_t)m);

    // Pull the saved register state out of the ucontext. On
    // Linux/ARM (32-bit EABI) it lives in uc_mcontext.arm_* fields.
    if (ucontext) {
        ucontext_t *uc = static_cast<ucontext_t *>(ucontext);
        const mcontext_t &mc = uc->uc_mcontext;
        m = snprintf(buf, sizeof(buf),
                     "[libpatch-" LIBPATCH_NAME "][C] regs: pc=%08lx lr=%08lx "
                     "sp=%08lx fp=%08lx ip=%08lx cpsr=%08lx fault=%08lx\n",
                     (unsigned long)mc.arm_pc,
                     (unsigned long)mc.arm_lr,
                     (unsigned long)mc.arm_sp,
                     (unsigned long)mc.arm_fp,
                     (unsigned long)mc.arm_ip,
                     (unsigned long)mc.arm_cpsr,
                     (unsigned long)mc.fault_address);
        if (m > 0) (void)!write(STDERR_FILENO, buf, (size_t)m);

        m = snprintf(buf, sizeof(buf),
                     "[libpatch-" LIBPATCH_NAME "][C] regs: r0=%08lx r1=%08lx "
                     "r2=%08lx r3=%08lx r4=%08lx r5=%08lx r6=%08lx r7=%08lx\n",
                     (unsigned long)mc.arm_r0,
                     (unsigned long)mc.arm_r1,
                     (unsigned long)mc.arm_r2,
                     (unsigned long)mc.arm_r3,
                     (unsigned long)mc.arm_r4,
                     (unsigned long)mc.arm_r5,
                     (unsigned long)mc.arm_r6,
                     (unsigned long)mc.arm_r7);
        if (m > 0) (void)!write(STDERR_FILENO, buf, (size_t)m);
    }

    // backtrace() will likely only show this handler + the kernel
    // sigreturn trampoline (no unwind info past the signal frame on
    // ARM), but include it anyway in case any frames are recoverable.
    static const char btm[] =
        "[libpatch-" LIBPATCH_NAME "][C] backtrace (may be truncated at sigreturn):\n";
    (void)!write(STDERR_FILENO, btm, sizeof(btm) - 1);
    void *frames[64];
    int   n = backtrace(frames, 64);
    backtrace_symbols_fd(frames, n, STDERR_FILENO);

    // Dump /proc/self/maps so the pc/lr/fault addresses can be
    // resolved to a (library, file_offset) pair. Bounded copy through
    // a stack buffer to stay async-signal-safe.
    static const char maps_hdr[] =
        "[libpatch-" LIBPATCH_NAME "][C] /proc/self/maps:\n";
    (void)!write(STDERR_FILENO, maps_hdr, sizeof(maps_hdr) - 1);
    int mfd = open("/proc/self/maps", O_RDONLY | O_CLOEXEC);
    if (mfd >= 0) {
        char mbuf[4096];
        ssize_t rn;
        while ((rn = read(mfd, mbuf, sizeof(mbuf))) > 0) {
            ssize_t off = 0;
            while (off < rn) {
                ssize_t wn = write(STDERR_FILENO, mbuf + off, (size_t)(rn - off));
                if (wn <= 0) break;
                off += wn;
            }
        }
        close(mfd);
    }

    // Restore default disposition and re-raise so the kernel still
    // writes a core dump that can be cross-gdb'd later.
    signal(sig, SIG_DFL);
    raise(sig);
}

static inline void preload_install_fatal_handler(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = preload_fatal_signal_handler;
    sigemptyset(&sa.sa_mask);
    // SA_SIGINFO: deliver siginfo_t + ucontext_t to the 3-arg handler.
    // SA_NODEFER: allow the re-raise inside the handler to deliver
    // immediately rather than be held pending.
    sa.sa_flags = SA_SIGINFO | SA_NODEFER;
    sigaction(SIGSEGV, &sa, nullptr);
    sigaction(SIGBUS,  &sa, nullptr);
    sigaction(SIGABRT, &sa, nullptr);
    sigaction(SIGFPE,  &sa, nullptr);
    sigaction(SIGILL,  &sa, nullptr);
}

// Read /proc/self/cmdline, replacing NUL separators with spaces so
// it's printable. Returns the number of bytes written (excluding the
// trailing NUL). Async-signal-safe: only uses open/read/close.
static inline int preload_read_cmdline(char *out, size_t outsz)
{
    if (!out || outsz == 0) return 0;
    out[0] = '\0';
    int fd = open("/proc/self/cmdline", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    ssize_t n = read(fd, out, outsz - 1);
    close(fd);
    if (n <= 0) { out[0] = '\0'; return 0; }
    for (ssize_t i = 0; i < n; ++i) {
        if (out[i] == '\0') out[i] = ' ';
    }
    out[n] = '\0';
    // Trim trailing space from the final NUL->space conversion.
    if (n > 0 && out[n - 1] == ' ') out[n - 1] = '\0';
    return (int)n;
}

// Return true if `cmdline` (space-joined /proc/self/cmdline) looks
// like a process that could plausibly dlopen an OEM service .so —
// i.e. argv[0]'s basename is "sm_svclauncher". Both the AAP service
// (jciAAPA) and the navigation service (jcinavi) are launched as
//   /jci/sm/sm_svclauncher -l <svc> /path/to/<oem>.so ...
// so the same gate applies to every preload patch.
static inline bool preload_is_launcher_process(const char *cmdline)
{
    if (!cmdline || !*cmdline) return false;
    // argv[0] = chars up to the first space (NULs already replaced
    // with spaces in preload_read_cmdline).
    const char *end = strchr(cmdline, ' ');
    size_t      len = end ? (size_t)(end - cmdline) : strlen(cmdline);
    // Compare basename of argv[0] to "sm_svclauncher".
    const char *base = cmdline;
    for (size_t i = 0; i < len; ++i) {
        if (cmdline[i] == '/') base = cmdline + i + 1;
    }
    size_t blen = len - (size_t)(base - cmdline);
    static const char kTarget[] = "sm_svclauncher";
    const size_t      kTlen     = sizeof(kTarget) - 1;
    return blen == kTlen && memcmp(base, kTarget, kTlen) == 0;
}

// True iff argv[0] is the aap_service executable. The aap_service shim patches
// fixed virtual addresses inside aap_service; since LD_PRELOAD is inherited by
// every process aap_service forks/execs (e.g. gst-plugin-scanner), those
// addresses are unmapped in the child and patching there would fault. Gate on
// argv[0] so the shim stays inert in inherited children. Compares the BASENAME
// of argv[0] to "aap_service" (exact), like preload_is_launcher_process — not a
// substring match, so a sibling such as /tmp/aap_service_helper can't trip it.
static inline bool preload_in_aap_service()
{
    char cl[256];
    if (preload_read_cmdline(cl, sizeof cl) <= 0) return false;
    char *sp = strchr(cl, ' ');
    if (sp) *sp = '\0';                  // keep argv[0] only
    const char *base = strrchr(cl, '/');
    base = base ? base + 1 : cl;         // basename of argv[0]
    return strcmp(base, "aap_service") == 0;
}

#endif  // LIBPATCH_COMMON_PRELOAD_GUARD_H
