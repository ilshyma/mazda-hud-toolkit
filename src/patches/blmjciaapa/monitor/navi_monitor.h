// Debug-only D-Bus eavesdropper for the OEM navigation services.
//
// Spawns the on-device /usr/bin/dbus-monitor as a child process,
// pointed at the JCI service bus ($JCI_SERVICE_BUS), with match rules
// that capture every message addressed to com.jci.vbs.navi and
// com.jci.vbs.navi.tmc. The child's stdout/stderr is drained by a
// reader thread that re-emits each line through the patch log (log.h),
// so the capture lands in the same device log as the rest of the shim.
//
// Eavesdropping needs no policy change on this firmware: the shipped
// /etc/dbus-1/service.d/jci_service.conf already grants
// <allow eavesdrop="true"/> on the service bus. libdbus on the device
// is 1.6.x, so dbus-monitor uses the classic add_match(eavesdrop=true)
// path (no org.freedesktop.DBus.Monitoring BecomeMonitor).
//
// RELEASE BUILDS SHIP NOTHING: the implementation is compiled only
// when DEBUG is defined (the Makefile passes -DDEBUG for the debug
// config, -DNDEBUG for release). In release these become no-op stubs,
// and the lifecycle call sites are #ifdef DEBUG'd out as well.

#ifndef LIBPATCH_BLMJCIAAPA_MONITOR_NAVI_MONITOR_H
#define LIBPATCH_BLMJCIAAPA_MONITOR_NAVI_MONITOR_H

// Start the dbus-monitor child + reader thread. Idempotent: a second
// call while already running is a no-op. Safe to call unconditionally;
// in release builds it does nothing.
void navi_monitor_post_aap_create_session(void);

// Stop the child (SIGTERM + reap) and join the reader thread.
// Idempotent: a call while not running is a no-op.
void navi_monitor_pre_aap_destroy_session(void);

#endif // LIBPATCH_BLMJCIAAPA_MONITOR_NAVI_MONITOR_H
