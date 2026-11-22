// svcjcinavi logging shim — sets the library name and pulls in the
// shared logging helper (patches/common/log.h). Per-TU includes are
// `#include "log.h"`; set LOG_TAG before including to label the line.

#ifndef LIBPATCH_SVCJCINAVI_LOG_H
#define LIBPATCH_SVCJCINAVI_LOG_H

#define LIBPATCH_NAME "svcjcinavi"
#include "common/log.h"

#endif // LIBPATCH_SVCJCINAVI_LOG_H
