// Session-lifecycle entry points for the touch shim.

#ifndef LIBPATCH_BLMJCIAAPA_TOUCH_TOUCH_H
#define LIBPATCH_BLMJCIAAPA_TOUCH_TOUCH_H

// Defined in touch.cpp. Spawns / joins the evdev reader thread.
void touch_post_aap_create_session(void);
void touch_pre_aap_destroy_session(void);

#endif // LIBPATCH_BLMJCIAAPA_TOUCH_TOUCH_H
