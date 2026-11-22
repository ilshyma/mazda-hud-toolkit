// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Session-lifecycle entry points for the mute -> phone play/pause bridge.

#ifndef LIBPATCH_BLMJCIAAPA_PLAYPAUSE_PLAYPAUSE_H
#define LIBPATCH_BLMJCIAAPA_PLAYPAUSE_PLAYPAUSE_H

// Defined in playpause.cpp. Spawns / joins the com.jci.vbs.am mute watcher
// thread that pauses the phone's Android Auto media on the user mute
// button and resumes it on unmute. Bracketed by aap_create_session /
// aap_destroy_session exactly like the touch reader and HUD sender.
void playpause_post_aap_create_session(void);
void playpause_pre_aap_destroy_session(void);

#endif // LIBPATCH_BLMJCIAAPA_PLAYPAUSE_PLAYPAUSE_H
