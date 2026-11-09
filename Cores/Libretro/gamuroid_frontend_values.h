/* gamuroid_frontend_values.h — Gamuroid.
 *
 * Small values the embedding app (ui/drivers/ui_cocoatouch.m, written from the main thread)
 * hands to the RetroArch frontend, and the places in the frontend that read them
 * (input/drivers_joypad/gamuroid_joypad.m, runloop.c, frontend/drivers/platform_darwin.m).
 * Storage lives in configuration.c. All calls are made on the main thread. Strings returned
 * are owned by the store and valid until the next setter call; NULL means "not set".
 */

#ifndef GAMUROID_FRONTEND_VALUES_H
#define GAMUROID_FRONTEND_VALUES_H

#include <stdbool.h>

#include <retro_common_api.h>

RETRO_BEGIN_DECLS

/* Whether the app wants controller rumble. */
void gamuroid_set_rumble_enabled(bool enabled);
bool gamuroid_rumble_is_enabled(void);

/* True while the host is tearing the session down; frontend callbacks bail out early. */
void gamuroid_set_host_stopping(bool stopping);
bool gamuroid_host_is_stopping(void);

/* Folder for save RAM chosen by the app for the running game (NULL: frontend default). */
void gamuroid_set_custom_save_dir(const char *dir);
const char *gamuroid_get_custom_save_dir(void);

/* Extension for save RAM files chosen by the app (NULL or empty: ".srm"). */
void gamuroid_set_custom_save_ext(const char *ext);
const char *gamuroid_get_custom_save_ext(void);

RETRO_END_DECLS

#endif
