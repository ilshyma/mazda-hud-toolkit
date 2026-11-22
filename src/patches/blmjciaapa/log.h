// blmjciaapa logging shim — sets the library name and pulls in the
// shared logging helper (patches/common/log.h). Per-TU includes stay
// `#include "../log.h"` / `#include "log.h"`; the subsystem tag is
// still set per-TU via `#define LOG_TAG` before the include.

#ifndef LIBPATCH_BLMJCIAAPA_LOG_H
#define LIBPATCH_BLMJCIAAPA_LOG_H

#define LIBPATCH_NAME "blmjciaapa"
#include "common/log.h"

#endif // LIBPATCH_BLMJCIAAPA_LOG_H
