/*  RetroArch - A frontend for libretro.
 *  Copyright (C) 2010-2014 - Hans-Kristian Arntzen
 *  Copyright (C) 2011-2021 - Daniel De Matteis
 *
 *  RetroArch is free software: you can redistribute it and/or modify it under the terms
 *  of the GNU General Public License as published by the Free Software Found-
 *  ation, either version 3 of the License, or (at your option) any later version.
 *
 *  RetroArch is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
 *  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 *  PURPOSE.  See the GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License along with RetroArch.
 *  If not, see <http://www.gnu.org/licenses/>.
 */

#include <stdint.h>

#include <libretro.h>
#include <string/stdstring.h>

#include "../configuration.h"
#include "../driver.h"
#include "../list_special.h"
#include "../runloop.h"
#include "../verbosity.h"

#include "camera_driver.h"

#if defined(HAVE_FFMPEG) && defined(HAVE_AVFORMAT) && defined(HAVE_AVCODEC) && \
   defined(HAVE_AVDEVICE) && defined(HAVE_AVUTIL) && defined(HAVE_SWSCALE)
/* FFMPEG consists of several libraries, and the camera driver needs most of them */
#define HAVE_FFMPEG_CAMERA
#endif

static void *nullcamera_init(const char *device, uint64_t caps,
      unsigned width, unsigned height) { return (void*)-1; }
static void nullcamera_free(void *data) { }
static void nullcamera_stop(void *data) { }
static bool nullcamera_start(void *data) { return true; }
static bool nullcamera_poll(void *a,
      retro_camera_frame_raw_framebuffer_t b,
      retro_camera_frame_opengl_texture_t c) { return true; }

static camera_driver_t camera_null = {
   nullcamera_init,
   nullcamera_free,
   nullcamera_start,
   nullcamera_stop,
   nullcamera_poll,
   "null",
};

const camera_driver_t *camera_drivers[] = {
#ifdef HAVE_V4L2
   &camera_v4l2,
#endif
#ifdef HAVE_PIPEWIRE_STABLE
   &camera_pipewire,
#endif
#ifdef EMSCRIPTEN
   &camera_rwebcam,
#endif
#ifdef ANDROID
   &camera_android,
#endif
#ifdef HAVE_AVF
   &camera_avfoundation,
#endif
#ifdef HAVE_FFMPEG_CAMERA
   &camera_ffmpeg,
#endif
   &camera_null,
   NULL,
};

static camera_driver_state_t camera_driver_st     = {0};

camera_driver_state_t *camera_state_get_ptr(void)
{
   return &camera_driver_st;
}

/**
 * config_get_camera_driver_options:
 *
 * Get an enumerated list of all camera driver names,
 * separated by '|'.
 *
 * Returns: string listing of all camera driver names,
 * separated by '|'.
 **/
const char *config_get_camera_driver_options(void)
{
   return char_list_new_special(STRING_LIST_CAMERA_DRIVERS, NULL);
}

/* Diagnostic counter for per-frame camera poll logs. Reset in the
 * RETRO_ENVIRONMENT_GET_CAMERA_INTERFACE env handler each time core activates
 * camera. Incremented on camera poll loop site in runloop.c. */
int camera_poll_log_count = 0;

bool driver_camera_start(void)
{
   camera_driver_state_t *camera_st = &camera_driver_st;
   settings_t            *settings  = config_get_ptr();

   RARCH_LOG("[Camera:start] camera_st=%p data=%p driver=%p driver->start=%p driver_name=%s camera_allow=%d\n",
         (void*)camera_st,
         camera_st ? camera_st->data : NULL,
         camera_st ? (void*)camera_st->driver : NULL,
         (camera_st && camera_st->driver) ? (void*)camera_st->driver->start : NULL,
         (camera_st && camera_st->driver && camera_st->driver->ident) ? camera_st->driver->ident : "(null)",
         settings ? (int)settings->bools.camera_allow : -1);
   RARCH_LOG("[Camera:start] settings->arrays.camera_driver=%s\n",
         settings ? settings->arrays.camera_driver : "(null)");

   if (!camera_st || !camera_st->data)
   {
      RARCH_ERR("[Camera:start] EARLY RETURN: camera_st->data is NULL (driver init failed or skipped)\n");
      return true;
   }
   if (!camera_st->driver || !camera_st->driver->start)
   {
      RARCH_ERR("[Camera:start] EARLY RETURN: driver or driver->start is NULL\n");
      return true;
   }

   if (!settings || !settings->bools.camera_allow)
   {
      RARCH_ERR("[Camera:start] EARLY RETURN: camera_allow=false\n");
      runloop_msg_queue_push(
            "Camera is explicitly disabled.\n",
            STRLEN_CONST("Camera is explicitly disabled.\n"),
            1, 180, false,
            NULL, MESSAGE_QUEUE_ICON_DEFAULT, MESSAGE_QUEUE_CATEGORY_INFO);
      return true;
   }

   {
      bool ok = camera_st->driver->start(camera_st->data);
      RARCH_LOG("[Camera:start] driver->start returned %d\n", (int)ok);
      return ok;
   }
}

void driver_camera_stop(void)
{
   camera_driver_state_t *camera_st = &camera_driver_st;
   if (     camera_st->driver
         && camera_st->driver->stop
         && camera_st->data)
      camera_st->driver->stop(camera_st->data);
}

bool camera_driver_find_driver(const char *prefix,
      bool verbosity_enabled)
{
   settings_t *settings         = config_get_ptr();
   camera_driver_state_t
      *camera_st                = &camera_driver_st;
   int i                        = (int)driver_find_index(
         "camera_driver",
         settings->arrays.camera_driver);

   if (i >= 0)
      camera_st->driver = (const camera_driver_t*)camera_drivers[i];
   else
   {
      if (verbosity_enabled)
      {
         unsigned d;
         RARCH_ERR("Couldn't find any %s named \"%s\"\n", prefix,
               settings->arrays.camera_driver);
         RARCH_LOG_OUTPUT("Available %ss are:\n", prefix);
         for (d = 0; camera_drivers[d]; d++)
         {
            if (camera_drivers[d])
            {
               RARCH_LOG_OUTPUT("\t%s\n", camera_drivers[d]->ident);
            }
         }

         RARCH_WARN("Going to default to first %s...\n", prefix);
      }

      if (!(camera_st->driver = (const camera_driver_t*)camera_drivers[0]))
         return false;
   }
   return true;
}
