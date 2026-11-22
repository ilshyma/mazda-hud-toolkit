// SPDX-License-Identifier: AGPL-3.0-or-later
//
// svcjcinavi merge patch — entry point.
//
// This LD_PRELOAD library is injected into the sm_svclauncher PID that
// hosts the OEM navigation service (/jci/navi/svcjcinavi.so). Its only
// job is to interpose the OEM HUD setters (merge.cpp) so that, while
// Android Auto is feeding guidance through the blmjciaapa svcnavi
// transport, the OEM nav engine's competing HUD frames are reconciled
// with AAP's maneuver instead of alternating with it (the card-in
// flicker), and the OEM speed limit is spliced onto AAP's frames.
//
// There is no work to do at constructor time — the interposed setters
// self-gate on first call (confirming svcjcinavi.so is actually mapped
// in this PID) and resolve the real implementations lazily. The
// constructor just installs the shared crash handler (after the same
// argv[0]=="sm_svclauncher" gate the other patches use) and logs that
// we were loaded, so a misdeployed library is obvious in the log.

#define LOG_TAG "CORE"
#include "log.h"
#include "common/preload_guard.h"

#include <unistd.h>

namespace {

__attribute__((constructor))
void on_load()
{
    // Gate on argv[0] so the CMU's once-a-second `sh -c killall ...`
    // watchdog children (which also inherit LD_PRELOAD) don't spam
    // logs or install handlers. Silent no-op otherwise.
    char cmdline[256];
    preload_read_cmdline(cmdline, sizeof(cmdline));
    if (!preload_is_launcher_process(cmdline)) {
        return;
    }

    LOGD("loading (svcjcinavi HUD merge hook) pid=%d ppid=%d cmdline=[%s]",
         (int)getpid(), (int)getppid(), cmdline);
    preload_install_fatal_handler();
    LOGD("fatal-signal handler installed (SEGV/BUS/ABRT/FPE/ILL) pid=%d",
         (int)getpid());
    LOGD("self-gate + HUD-setter resolution deferred to first call pid=%d",
         (int)getpid());
}

} // namespace
