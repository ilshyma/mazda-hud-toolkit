// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Shared helper: spawn a pthread with a bounded stack.
//
// Every worker thread in these shims (the touch reader, the HUD sender, the
// nav16 receiver, the wireless-pairing activator) is a thin event loop that
// touches at most a few KB of its own stack. Left to the default, glibc reserves
// RLIMIT_STACK (commonly 8 MB) per thread as private-anon virtual memory AND
// keeps freed stacks in a per-process cache across the per-session create/join
// churn — tens of MB of address space on a 32-bit, memory-tight CMU for stacks
// that use almost none of it. A fixed, generous-but-bounded stack fixes both.
//
// 256 KiB, not smaller, on purpose: these threads call INTO OEM code with an
// unknown stack appetite (RaceAap::SendTouchInput, libjcidbus / libdbus
// marshalling), so we keep a wide margin. If the attr can't be set up (init
// fails, or the size is somehow below PTHREAD_STACK_MIN) we fall back to a
// default-stack thread rather than fail to spawn — a thread is always attempted.
//
// Header-only inline (the patches/ tree compiles only patches/<name>/*.cpp),
// same convention as the other common/ headers.

#ifndef LIBPATCH_COMMON_THREAD_UTIL_H
#define LIBPATCH_COMMON_THREAD_UTIL_H

#include <pthread.h>
#include <limits.h>    // PTHREAD_STACK_MIN (where defined)
#include <stddef.h>

// Bounded worker-thread stack. Wide enough for our loops PLUS the OEM callees
// they enter; small enough that N per-session threads don't reserve tens of MB.
#ifndef LIBPATCH_THREAD_STACK_SIZE
#  define LIBPATCH_THREAD_STACK_SIZE (256 * 1024)
#endif

// Like pthread_create(t, <bounded-stack attr>, fn, arg). Returns the
// pthread_create rc (0 on success). Falls back to a default-stack thread if the
// attr can't be prepared, so a thread is always attempted.
static inline int preload_thread_create(pthread_t *t,
                                        void *(*fn)(void *), void *arg)
{
    pthread_attr_t attr;
    if (pthread_attr_init(&attr) != 0) {
        return pthread_create(t, nullptr, fn, arg);   // fall back: default stack
    }

    size_t stack = (size_t)LIBPATCH_THREAD_STACK_SIZE;
#ifdef PTHREAD_STACK_MIN
    if (stack < (size_t)PTHREAD_STACK_MIN) {
        stack = (size_t)PTHREAD_STACK_MIN;
    }
#endif
    // Best-effort: on EINVAL the attr keeps its default stacksize, so the thread
    // still spawns (just with the default stack) instead of not at all.
    pthread_attr_setstacksize(&attr, stack);

    int rc = pthread_create(t, &attr, fn, arg);
    pthread_attr_destroy(&attr);
    return rc;
}

#endif  // LIBPATCH_COMMON_THREAD_UTIL_H
