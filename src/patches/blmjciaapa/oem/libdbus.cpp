// Self-resolving thunks for the raw libdbus-1 functions used by the
// svcjcinavi HUD transport. See libdbus.h for the rationale (why this
// transport bypasses libjcidbus) and oem_thunk.h for the macros.

#define LOG_TAG "LIBDBUS"
#include "../log.h"

#include "libdbus.h"
#include "oem_thunk.h"

#include <dlfcn.h>

namespace {

// Resolve one libdbus-1 symbol by name. libdbus-1.so.3 is always
// resident in the jciAAPA process (libjcidbus depends on it), but we
// still dlopen it once (RTLD_NOW|RTLD_GLOBAL, refcount bump) so
// resolution doesn't rely on that incidental chain, and fall back to
// the global scope if the dlopen didn't take.
void *oem_sym(const char *name)
{
	static void *handle = dlopen("libdbus-1.so.3", RTLD_NOW | RTLD_GLOBAL);
	void *sym = dlsym(handle ? handle : RTLD_DEFAULT, name);
	if (sym == nullptr) {
		LOGC("oem: dlsym(%s) failed: %s", name, dlerror());
	}
	return sym;
}

} // namespace

OEM_THUNK(void *, dbus_connection_open_private,
          (const char *address, void *error), (address, error), nullptr)
OEM_THUNK(DBusBool, dbus_bus_register,
        (void *conn, void *error), (conn, error), 0)
OEM_THUNK_VOID(dbus_connection_set_exit_on_disconnect,
            (void *conn, DBusBool enabled), (conn, enabled))
OEM_THUNK(DBusBool, dbus_connection_get_is_connected,
          (void *conn), (conn), 0)
OEM_THUNK_VOID(dbus_connection_close, (void *conn), (conn))
OEM_THUNK_VOID(dbus_connection_unref, (void *conn), (conn))

OEM_THUNK(void *, dbus_message_new_signal,
          (const char *path, const char *iface, const char *member),
          (path, iface, member), nullptr)
OEM_THUNK_VOID(dbus_message_iter_init_append,
               (void *msg, DBusMessageIter *iter), (msg, iter))
OEM_THUNK(DBusBool, dbus_message_iter_append_basic,
          (DBusMessageIter *iter, int type, const void *value),
          (iter, type, value), 0)
OEM_THUNK(DBusBool, dbus_connection_send,
          (void *conn, void *msg, uint32_t *serial), (conn, msg, serial), 0)
OEM_THUNK_VOID(dbus_connection_flush, (void *conn), (conn))
OEM_THUNK_VOID(dbus_message_unref, (void *msg), (msg))

OEM_THUNK_VOID(dbus_bus_add_match,
               (void *conn, const char *rule, void *error), (conn, rule, error))
OEM_THUNK(DBusBool, dbus_connection_set_watch_functions,
          (void *conn, DBusAddWatchFunction add_function,
           DBusRemoveWatchFunction remove_function,
           DBusWatchToggledFunction toggled_function, void *data,
           DBusFreeFunction free_data_function),
          (conn, add_function, remove_function, toggled_function, data,
           free_data_function), 0)
OEM_THUNK(int, dbus_watch_get_unix_fd, (void *watch), (watch), -1)
OEM_THUNK(unsigned int, dbus_watch_get_flags,
          (void *watch), (watch), 0)
OEM_THUNK(DBusBool, dbus_watch_get_enabled, (void *watch), (watch), 0)
OEM_THUNK(DBusBool, dbus_watch_handle,
          (void *watch, unsigned int flags), (watch, flags), 0)
OEM_THUNK(void *, dbus_connection_pop_message, (void *conn), (conn), nullptr)
OEM_THUNK(DBusBool, dbus_message_is_signal,
          (void *msg, const char *iface, const char *member),
          (msg, iface, member), 0)
OEM_THUNK(DBusBool, dbus_message_iter_init,
          (void *msg, DBusMessageIter *iter), (msg, iter), 0)
OEM_THUNK(int, dbus_message_iter_get_arg_type,
          (DBusMessageIter *iter), (iter), 0)
OEM_THUNK_VOID(dbus_message_iter_get_basic,
               (DBusMessageIter *iter, void *value), (iter, value))
