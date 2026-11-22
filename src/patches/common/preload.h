// Shared helpers for LD_PRELOAD interposition patches.
//
//  * PRELOAD_EXPORT — default visibility for the symbols the OEM PLT
//    must bind to (the build uses -fvisibility=hidden, so exported
//    shims need this explicitly).
//  * resolve_real_symbol() — find the genuine implementation of a
//    symbol we are interposing, so our shim can chain through to it.
//
// Header-only (the resolver is inline) so any patch can use it with no
// extra .cpp to link.
//
// Why resolution is not just dlsym(RTLD_NEXT): an OEM service .so
// (blmjciaapa.so, svcjcinavi.so) is dlopen'd by sm_svclauncher with
// RTLD_NOW but WITHOUT RTLD_GLOBAL, so its DT_NEEDED libraries (where
// the real symbol lives) land in a *local* scope that RTLD_NEXT —
// which only walks the global scope past our image — cannot see.
// dlopen(soname, RTLD_NOLOAD) consults the loader's list of mapped
// objects regardless of scope, finds the already-resident copy, and
// dlsym on that handle returns the real address. We try RTLD_NEXT
// first (cheapest, and correct in any process where the library does
// happen to be globally visible) and fall back to NOLOAD.

#ifndef LIBPATCH_COMMON_PRELOAD_H
#define LIBPATCH_COMMON_PRELOAD_H

#include <dlfcn.h>

#include "common/log.h"

#define PRELOAD_EXPORT __attribute__((visibility("default")))

// Resolve the real implementation of `name`.
//   name      - symbol to resolve (the one we interpose).
//   soname    - DT_SONAME of the library that defines it (e.g.
//               "libjcivbsnaviclient.so"); tried first via NOLOAD.
//   abspath   - absolute path fallback if the soname dlopen misses
//               (may be nullptr).
//   own_shim  - address of OUR exported shim of the same name; if a
//               lookup returns this we reject it (calling it would
//               recurse straight back into us — LD_PRELOAD libs sit
//               at the front of every search scope, including the one
//               a handle-based dlsym walks).
//   handle_cache - caller-owned storage for the NOLOAD dlopen handle
//               so repeated resolutions of symbols from the same
//               library don't leak refcounts. Pass the address of a
//               static `void *foo = nullptr;`.
//
// Returns the real address, or nullptr if it could not be found (the
// caller should then degrade to a transparent passthrough).
//
// Logging uses the LOG* macros (subsystem = the including TU's
// LOG_TAG). The self-loop case is logged at CRITICAL because calling
// our own shim recurses forever and stack-overflows into a SIGSEGV —
// it's the trap that has to be caught, not silently swallowed.
inline void *resolve_real_symbol(const char *name, const char *soname,
                                 const char *abspath, void *own_shim,
                                 void **handle_cache)
{
    // 1) Global-scope walk past our image. Cheapest, and correct in
    // any process where the defining library is globally visible.
    void *p = dlsym(RTLD_NEXT, name);
    LOGD("resolve_real_symbol(%s): dlsym(RTLD_NEXT) -> %p", name, p);
    if (p && p != own_shim) {
        return p;
    }
    if (p == own_shim && own_shim) {
        LOGW("resolve_real_symbol(%s): dlsym(RTLD_NEXT) returned OUR "
             "shim %p — LD_PRELOAD interposition trap, falling through",
             name, p);
    }

    // 2) NOLOAD-dlopen the defining library (resolves regardless of
    // scope) and dlsym it. The handle is cached in the caller's slot
    // so repeat resolutions don't leak refcounts.
    if (handle_cache && *handle_cache == nullptr) {
        if (soname) {
            *handle_cache = dlopen(soname, RTLD_NOW | RTLD_NOLOAD);
        }
        if (*handle_cache == nullptr && abspath) {
            *handle_cache = dlopen(abspath, RTLD_NOW | RTLD_NOLOAD);
        }
        if (*handle_cache == nullptr) {
            LOGE("resolve_real_symbol(%s): dlopen(%s / %s, RTLD_NOLOAD) "
                 "failed: %s", name, soname ? soname : "(null)",
                 abspath ? abspath : "(null)", dlerror());
            return nullptr;
        }
        LOGD("resolve_real_symbol(%s): defining lib handle=%p (NOLOAD)",
             name, *handle_cache);
    }
    if (handle_cache && *handle_cache) {
        p = dlsym(*handle_cache, name);
        LOGD("resolve_real_symbol(%s): dlsym(handle=%p) -> %p",
             name, *handle_cache, p);
        if (p && p != own_shim) {
            return p;
        }
        // Self-loop: glibc's per-handle dlsym still walks preloaded
        // objects (they're inserted at the front of every link-map
        // scope), so it can hand us back OUR own shim. Calling it
        // would recurse forever -> stack overflow -> SIGSEGV.
        if (p == own_shim && own_shim) {
            LOGC("resolve_real_symbol(%s): dlsym(handle) returned OUR "
                 "shim %p — LD_PRELOAD interposition trap; refusing to "
                 "recurse. The real impl is unreachable through the "
                 "loader's per-handle search path.", name, p);
        } else {
            LOGE("resolve_real_symbol(%s): dlsym on defining lib handle "
                 "failed: %s", name, dlerror());
        }
    }

    return nullptr;
}

#endif  // LIBPATCH_COMMON_PRELOAD_H
