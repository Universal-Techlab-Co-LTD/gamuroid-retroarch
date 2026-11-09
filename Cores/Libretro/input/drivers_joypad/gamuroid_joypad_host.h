// gamuroid_joypad_host.h — Gamuroid.
//
// Entry points of the "gamuroid" joypad driver used by the embedded host (ui/drivers/ui_cocoatouch.m).
// All three are called on the main thread, the thread that also polls the driver.

#ifndef GAMUROID_JOYPAD_HOST_H
#define GAMUROID_JOYPAD_HOST_H

#include <stdbool.h>

/* Marks the driver as not initialized so that the next RetroArch init runs the driver init again
 * (virtual pads announced, rumble set up). Safe to call when it is not initialized. */
void gamupad_host_reset(void);

/* Sets one button of one virtual pad.
 *   port      player index, 0 ... MAX_USERS - 1; other values are ignored
 *   button_id RetroArch joypad id, 0 ... 15, plus the menu-toggle hotkey id; larger values are ignored
 *   down      true = pressed, false = released */
void gamupad_host_set_button(unsigned port, unsigned button_id, bool down);

/* Sets one analog stick of one virtual pad.
 *   port   player index, 0 ... MAX_USERS - 1; other values are ignored
 *   stick  RETRO_DEVICE_INDEX_ANALOG_LEFT or RETRO_DEVICE_INDEX_ANALOG_RIGHT; other values are ignored
 *   x, y   floats in -1 ... 1, up and right positive; NaN counts as 0, larger magnitudes are clamped */
void gamupad_host_set_stick(unsigned port, unsigned stick, float x, float y);

#endif
