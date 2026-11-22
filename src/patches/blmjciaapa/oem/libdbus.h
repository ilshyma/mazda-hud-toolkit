// Minimal libdbus-1 bindings for the svcjcinavi HUD transport.
//
// This transport emits a com.NNG.Api.Server.Guidance.GuidanceChangedForHUD
// signal the way the NNG engine does — with raw libdbus-1 — rather than
// through libjcidbus. libjcidbus's JCIDBUS_signal_send is a SERVE-only
// path: it calls signal_registered() and refuses (returns -1, logs
// "Signal %s is not added in any Interface!") to emit any signal whose
// interface+member wasn't registered as a served object on the
// connection. We are a client impersonating NNG, not serving an
// interface, so that path can never work for us. NNG itself links
// libdbus-1 directly (no libjcidbus DT_NEEDED) and emits the bare
// signal; we do the same.
//
// As with the other oem/ bindings there is NO init step and NO link
// dependency: each prototype is backed by a self-resolving dlsym thunk
// in libdbus.cpp (see oem_thunk.h). libdbus-1.so.3 is always resident
// in the jciAAPA process (libjcidbus pulls it in), so dlopen finds it.
//
// Types and constants are hand-declared from the libdbus public ABI
// (dbus-message.h / dbus-protocol.h). The DBusMessageIter layout is
// part of libdbus's stable public ABI and is safe to reproduce.

#ifndef LIBPATCH_BLMJCIAAPA_LIBDBUS_H
#define LIBPATCH_BLMJCIAAPA_LIBDBUS_H

#include <stdint.h>

// D-Bus basic type codes (dbus-protocol.h). Only the ones we marshal.
#define DBUS_TYPE_BYTE   ((int)'y')   // 121
#define DBUS_TYPE_INT32  ((int)'i')   // 105
#define DBUS_TYPE_STRING ((int)'s')   // 115

// DBusWatch readiness flags (dbus-connection.h).
#define DBUS_WATCH_READABLE (1u << 0)
#define DBUS_WATCH_WRITABLE (1u << 1)
#define DBUS_WATCH_ERROR    (1u << 2)
#define DBUS_WATCH_HANGUP   (1u << 3)

// DBusMessageIter — stable public ABI (dbus-message.h). Opaque to us;
// we only ever pass its address. Sized via dummy fields exactly as
// the upstream header declares so the on-stack object is large enough.
struct DBusMessageIter {
    void     *dummy1;
    void     *dummy2;
    uint32_t  dummy3;
    int       dummy4;
    int       dummy5;
    int       dummy6;
    int       dummy7;
    int       dummy8;
    int       dummy9;
    int       dummy10;
    int       dummy11;
    int       pad1;
    int       pad2;
    void     *pad3;
};

// All functions resolve as dynamic exports of libdbus-1.so.3 (verified
// T in `nm -D`). Pointers are opaque (DBusConnection* / DBusMessage*).
// dbus_bool_t is an unsigned fixed-width 32-bit value (TRUE=1, FALSE=0).
// A NULL DBusError* is accepted by libdbus, so we pass none.

typedef uint32_t DBusBool;
typedef DBusBool (*DBusAddWatchFunction)(void *watch, void *data);
typedef void (*DBusRemoveWatchFunction)(void *watch, void *data);
typedef void (*DBusWatchToggledFunction)(void *watch, void *data);
typedef void (*DBusFreeFunction)(void *data);

// Connection lifecycle. open_private gives us a dedicated connection
// (not shared with libjcidbus's); register performs the bus Hello so
// the daemon will route our signals; set_exit_on_disconnect(FALSE)
// keeps a torn service-bus socket (e.g. source switch) from raising a
// fatal signal — the same safety libjcidbus gave us.
void *dbus_connection_open_private(const char *address, void *error);
DBusBool dbus_bus_register(void *conn, void *error);
void  dbus_connection_set_exit_on_disconnect(void *conn, DBusBool enabled);
DBusBool dbus_connection_get_is_connected(void *conn);
void  dbus_connection_close(void *conn);
void  dbus_connection_unref(void *conn);

// Signal build + send.
void *dbus_message_new_signal(const char *path, const char *iface,
                              const char *member);
void  dbus_message_iter_init_append(void *msg, DBusMessageIter *iter);
DBusBool dbus_message_iter_append_basic(DBusMessageIter *iter, int type,
                                        const void *value);
DBusBool dbus_connection_send(void *conn, void *msg, uint32_t *serial);
void  dbus_connection_flush(void *conn);
void  dbus_message_unref(void *msg);

// Signal receive (small custom poll loop): the play/pause bridge subscribes with
// add_match, registers watch callbacks, and polls libdbus's enabled watches
// together with its stop eventfd. All are stable libdbus-1.so.3 exports.
void dbus_bus_add_match(void *conn, const char *rule, void *error);
DBusBool dbus_connection_set_watch_functions(
    void *conn, DBusAddWatchFunction add_function,
    DBusRemoveWatchFunction remove_function,
    DBusWatchToggledFunction toggled_function, void *data,
    DBusFreeFunction free_data_function);
int  dbus_watch_get_unix_fd(void *watch);
unsigned int dbus_watch_get_flags(void *watch);
DBusBool dbus_watch_get_enabled(void *watch);
DBusBool dbus_watch_handle(void *watch, unsigned int flags);
void *dbus_connection_pop_message(void *conn);
DBusBool dbus_message_is_signal(void *msg, const char *iface,
                                const char *member);
DBusBool dbus_message_iter_init(void *msg, DBusMessageIter *iter);
int  dbus_message_iter_get_arg_type(DBusMessageIter *iter);
void dbus_message_iter_get_basic(DBusMessageIter *iter, void *value);

#endif  // LIBPATCH_BLMJCIAAPA_LIBDBUS_H
