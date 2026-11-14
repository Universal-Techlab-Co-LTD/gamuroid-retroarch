/*  Gamuroid - pointer lift gate for the cocoa touch input of the embedded host.
 *  Copyright (C) 2026 - UNIVERSAL TECHLAB COMPANY LIMITED
 *
 *  This file is part of the Gamuroid build of RetroArch and is distributed under the same
 *  licence: GNU General Public License, version 3 or (at your option) any later version.
 *  It comes WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 *  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
 */

#ifndef __GAMUROID_POINTER_GATE_H__
#define __GAMUROID_POINTER_GATE_H__

#include <stdint.h>
#include <boolean.h>
#include <retro_inline.h>

/* The host pointer (hostPointerDownAtX:y: / hostPointerUp) writes the touch state that the core
 * reads during its input poll. A lift followed by a press at another point before the next poll
 * would be invisible to the core: it would see one drag from the old point to the new one.
 * The gate holds such a press back so that exactly one poll sees the pointer lifted; the next
 * poll applies the held press.
 *
 * Pure state machine, no I/O. Every call must come from the thread that runs the input poll
 * (the main thread on iOS). A zero-filled struct is the fresh state. */
typedef struct gamuroid_pointer_gate
{
   uint32_t poll_count;    /* polls seen; only compared for equality, so wrapping is harmless */
   uint32_t lift_poll;     /* poll_count at the last lift */
   int16_t  held_x;        /* held press, in the same units as cocoa_touch_data_t.screen_x */
   int16_t  held_y;
   bool     lift_recorded; /* lift_poll is valid */
   bool     press_held;    /* a press waits for the next poll */
} gamuroid_pointer_gate_t;

/* Pointer pressed (or moved while pressed) at (x, y).
 * Returns true when the caller writes the press now (touch count 1 at (x, y)).
 * Returns false when the press is held: the caller keeps the touch count at 0. */
static INLINE bool gamuroid_pointer_gate_press(gamuroid_pointer_gate_t *gate,
      int16_t x, int16_t y)
{
   bool lift_not_polled = gate->lift_recorded && gate->lift_poll == gate->poll_count;

   if (!gate->press_held && !lift_not_polled)
      return true;

   /* Either a press is already held (a move updates it) or no poll has seen the last lift. */
   gate->press_held = true;
   gate->held_x     = x;
   gate->held_y     = y;
   return false;
}

/* Pointer lifted. Drops a held press; the caller writes touch count 0 as before. */
static INLINE void gamuroid_pointer_gate_lift(gamuroid_pointer_gate_t *gate)
{
   gate->press_held    = false;
   gate->lift_poll     = gate->poll_count;
   gate->lift_recorded = true;
}

/* Another writer replaced the whole touch state: drop a held press, keep the poll count. */
static INLINE void gamuroid_pointer_gate_cancel(gamuroid_pointer_gate_t *gate)
{
   gate->press_held = false;
}

/* Called at the start of every input poll, before the touch state is read.
 * Returns true with *x, *y set when the held press must be written now (touch count 1);
 * returns false when nothing changes. A press held since a lift that no poll has seen is
 * kept for one more poll, so this poll still sees the pointer lifted. */
static INLINE bool gamuroid_pointer_gate_poll(gamuroid_pointer_gate_t *gate,
      int16_t *x, int16_t *y)
{
   bool apply = gate->press_held && gate->lift_poll != gate->poll_count;

   gate->poll_count++;

   if (!apply)
      return false;

   gate->press_held = false;
   *x               = gate->held_x;
   *y               = gate->held_y;
   return true;
}

#endif
