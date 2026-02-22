/*
 * Minimal libvlc stub for Arch R
 * ES-fcamod links against libvlc.so.5 but handles VLC init failure gracefully.
 * This stub satisfies the dynamic linker with no-op implementations.
 * All functions return NULL/0/failure so ES falls back to non-VLC paths.
 */

#include <stddef.h>

/* Opaque types (ES only uses pointers) */
typedef void libvlc_instance_t;
typedef void libvlc_media_t;
typedef void libvlc_media_player_t;
typedef void libvlc_media_track_t;

/* ES-fcamod required symbols (17 total) */

libvlc_instance_t *libvlc_new(int argc, const char *const *argv) { return NULL; }
libvlc_media_t *libvlc_media_new_path(libvlc_instance_t *inst, const char *path) { return NULL; }
void libvlc_media_add_option(libvlc_media_t *m, const char *opt) { }
int libvlc_media_parse_with_options(libvlc_media_t *m, unsigned flags, int timeout) { return -1; }
int libvlc_media_get_parsed_status(libvlc_media_t *m) { return 0; }
unsigned libvlc_media_tracks_get(libvlc_media_t *m, libvlc_media_track_t ***tracks) { return 0; }
void libvlc_media_tracks_release(libvlc_media_track_t **tracks, unsigned count) { }
void libvlc_media_release(libvlc_media_t *m) { }

libvlc_media_player_t *libvlc_media_player_new_from_media(libvlc_media_t *m) { return NULL; }
void libvlc_media_player_set_media(libvlc_media_player_t *p, libvlc_media_t *m) { }
int libvlc_media_player_play(libvlc_media_player_t *p) { return -1; }
void libvlc_media_player_stop(libvlc_media_player_t *p) { }
int libvlc_media_player_get_state(libvlc_media_player_t *p) { return 0; }
void libvlc_media_player_release(libvlc_media_player_t *p) { }

void libvlc_audio_set_mute(libvlc_media_player_t *p, int mute) { }
void libvlc_video_set_callbacks(libvlc_media_player_t *p, void *lock, void *unlock, void *display, void *opaque) { }
void libvlc_video_set_format(libvlc_media_player_t *p, const char *chroma, unsigned w, unsigned h, unsigned pitch) { }
