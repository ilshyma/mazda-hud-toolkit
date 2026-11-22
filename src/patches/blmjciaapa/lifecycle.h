// Compile-time feature toggles for libpatch-blmjciaapa.
//
// Central place for build-time on/off switches that aren't tied to the
// debug/release split (that's handled by DEBUG / NDEBUG in log.h and
// the Makefile). Flip a flag here and rebuild.

#ifndef LIBPATCH_BLMJCIAAPA_LIFECYCLE_H
#define LIBPATCH_BLMJCIAAPA_LIFECYCLE_H

// Navigation D-Bus eavesdropper (monitor/navi_monitor.*). When
// enabled, debug builds spawn dbus-monitor for the session and forward
// its output to the patch log. Set to 0 to disable entirely; note it
// is additionally gated on DEBUG, so release builds ship nothing
// regardless of this value.
#define BLMJCIAAPA_ENABLE_NAVI_MONITOR 0

#endif // LIBPATCH_BLMJCIAAPA_LIFECYCLE_H
