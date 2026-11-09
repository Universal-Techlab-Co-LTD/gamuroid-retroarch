// gamuroid_joypad.m — Gamuroid.
//
// RetroArch joypad driver "gamuroid": a virtual pad whose state the app pushes through
// the gamupad_host_* entry points (declared in gamuroid_joypad_host.h, called by the RetroArch_iOS host), plus
// phone rumble through Core Haptics.
//
// This file is not compiled on its own: griffin/griffin_objc.m includes it after ui_cocoatouch.m and
// cocoa_input.m. Every file-local name therefore carries the "gamupad" prefix to stay unique in that unit.
//
// Threading: RetroArch polls the driver and the host pushes events on the main thread. Core Haptics
// completion handlers hop back to the main queue before touching any state of this file.

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <time.h>

#include <libretro.h>
#include <retro_miscellaneous.h>

#include "../input_driver.h"
#include "../../tasks/tasks_internal.h"
#include "../../configuration.h"
#include "gamuroid_joypad_host.h"

#ifdef HAVE_COREMOTION
#import <Foundation/Foundation.h>
#import <CoreHaptics/CoreHaptics.h>
#endif

#define GAMUPAD_DEVICE_NAME  "Gamuroid Controller"
#define GAMUPAD_IDENT        "gamuroid"
/* Pads announced to RetroArch: min(MAX_USERS, MAX_GAMUROID_CONTROLLERS). */
#define MAX_GAMUROID_CONTROLLERS 4

enum
{
   /* 0 left X, 1 left Y, 2 right X, 3 right Y, 4/5 analog triggers (always 0). */
   GAMUPAD_AXIS_COUNT     = 6,
   /* Highest id accepted by gamupad_host_set_button (menu-toggle hotkey bind). */
   GAMUPAD_LAST_BUTTON_ID = RARCH_FIRST_CUSTOM_BIND
};

static inline unsigned gamuroid_supported_user_count(void)
{
    return MIN(MAX_USERS, MAX_GAMUROID_CONTROLLERS);
}

typedef struct
{
   uint32_t buttons;
   int16_t  axes[GAMUPAD_AXIS_COUNT];
} gamupad_port_state_t;

/* Pushed by the app; survives RetroArch re-inits inside the process. */
static gamupad_port_state_t gamupad_ports[MAX_USERS];
static bool gamupad_is_initialized = false;

#pragma mark - Rumble (Core Haptics)

#ifdef HAVE_COREMOTION

/* Identical requests of one effect type closer together than this are reported as played without being
 * played again. ~2.08 s is the window measured on the shipped arm64 builds (spec §9 U3: observed behavior
 * kept). */
static const uint64_t gamupad_rumble_repeat_window_ns = 2083333333ULL;

API_AVAILABLE(ios(13.0))
@interface GamuPadRumble : NSObject
- (void)teardown;
- (BOOL)playStrong:(BOOL)strong strength:(uint16_t)strength;
@end

API_AVAILABLE(ios(13.0))
@implementation GamuPadRumble
{
   CHHapticEngine *_engine;
   BOOL _supported;
   BOOL _running;
   BOOL _startInFlight;
   BOOL _tornDown;
   id<CHHapticPatternPlayer> _defaultStrongPlayer;
   id<CHHapticPatternPlayer> _defaultWeakPlayer;
   id<CHHapticPatternPlayer> _activeStrongPlayer;
   id<CHHapticPatternPlayer> _activeWeakPlayer;
}

- (instancetype)init
{
   self = [super init];
   if (!self)
      return nil;

   if (!CHHapticEngine.capabilitiesForHardware.supportsHaptics)
      return self; /* unsupported hardware: _supported stays NO */

   NSError *error = nil;
   _engine = [[CHHapticEngine alloc] initAndReturnError:&error];
   if (!_engine)
   {
      NSLog(@"[GamuPad] haptic engine unavailable: %@", error);
      return self;
   }
   _engine.autoShutdownEnabled = YES;

   __weak GamuPadRumble *weakSelf = self;
   __weak CHHapticEngine *weakEngine = _engine;
   _engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
      dispatch_async(dispatch_get_main_queue(), ^{
         [weakSelf engineDidStop:weakEngine reason:reason];
      });
   };

   [self startEngineMarkingUnsupportedOnFailure:YES];
   return self;
}

- (void)startEngineMarkingUnsupportedOnFailure:(BOOL)markUnsupported
{
   if (!_engine || _startInFlight)
      return;
   _startInFlight = YES;

   __weak GamuPadRumble *weakSelf = self;
   __weak CHHapticEngine *weakEngine = _engine;
   [_engine startWithCompletionHandler:^(NSError *error) {
      dispatch_async(dispatch_get_main_queue(), ^{
         [weakSelf engine:weakEngine didStartWithError:error markUnsupportedOnFailure:markUnsupported];
      });
   }];
}

- (void)engine:(CHHapticEngine *)engine didStartWithError:(NSError *)error markUnsupportedOnFailure:(BOOL)markUnsupported
{
   if (_tornDown || engine == nil || engine != _engine)
      return;
   _startInFlight = NO;
   if (error)
   {
      NSLog(@"[GamuPad] haptic engine start failed: %@", error);
      _running = NO;
      if (markUnsupported)
         _supported = NO;
      return;
   }
   _supported = YES;
   _running   = YES;
   [self buildDefaultPlayers];
}

- (void)engineDidStop:(CHHapticEngine *)engine reason:(CHHapticEngineStoppedReason)reason
{
   if (_tornDown || engine == nil || engine != _engine)
      return;
   (void)reason;
   _running             = NO;
   _defaultStrongPlayer = nil;
   _defaultWeakPlayer   = nil;
}

- (id<CHHapticPatternPlayer>)playerWithPulses:(NSUInteger)pulses intensity:(float)intensity sharpness:(float)sharpness
{
   NSMutableArray<CHHapticEvent *> *events = [NSMutableArray arrayWithCapacity:pulses];
   for (NSUInteger i = 0; i < pulses; i++)
   {
      NSArray<CHHapticEventParameter *> *parameters = @[
         [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:intensity],
         [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:sharpness],
      ];
      [events addObject:[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient
                                                      parameters:parameters
                                                    relativeTime:0.05 * (NSTimeInterval)i]];
   }

   NSError *error = nil;
   CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:events parameters:@[] error:&error];
   if (!pattern)
      return nil;
   return [_engine createPlayerWithPattern:pattern error:&error];
}

- (void)buildDefaultPlayers
{
   @try
   {
      _defaultStrongPlayer = [self playerWithPulses:1 intensity:1.0f sharpness:0.5f];
      _defaultWeakPlayer   = [self playerWithPulses:1 intensity:0.5f sharpness:0.3f];
   }
   @catch (NSException *exception)
   {
      NSLog(@"[GamuPad] default haptic players not built: %@", exception);
      _defaultStrongPlayer = nil;
      _defaultWeakPlayer   = nil;
   }
}

- (BOOL)playStrong:(BOOL)strong strength:(uint16_t)strength
{
   if (_tornDown || !_supported || !_engine)
      return NO;
   if (!_running)
   {
      /* Auto-shutdown (or a reset) stopped the engine: restart it for the next request. */
      [self startEngineMarkingUnsupportedOnFailure:NO];
      return NO;
   }

   @try
   {
      float level = (float)strength / 65535.0f;
      id<CHHapticPatternPlayer> player = strong
         ? [self playerWithPulses:4 intensity:level        sharpness:0.7f]  /* ~200 ms */
         : [self playerWithPulses:3 intensity:0.6f * level sharpness:0.3f]; /* ~150 ms */
      if (!player)
         player = strong ? _defaultStrongPlayer : _defaultWeakPlayer;
      if (!player)
         return NO;

      NSError *error = nil;
      if (![player startAtTime:CHHapticTimeImmediate error:&error])
      {
         NSLog(@"[GamuPad] haptic playback failed: %@", error);
         _running = NO;
         [self startEngineMarkingUnsupportedOnFailure:NO];
         return NO;
      }
      if (strong)
         _activeStrongPlayer = player;
      else
         _activeWeakPlayer = player;
      return YES;
   }
   @catch (NSException *exception)
   {
      NSLog(@"[GamuPad] haptic playback raised: %@", exception);
      return NO;
   }
}

- (void)stopPlayerQuietly:(id<CHHapticPatternPlayer>)player
{
   if (!player)
      return;
   @try
   {
      NSError *error = nil;
      if (![player stopAtTime:CHHapticTimeImmediate error:&error])
         NSLog(@"[GamuPad] haptic player stop failed: %@", error);
   }
   @catch (NSException *exception)
   {
      NSLog(@"[GamuPad] haptic player stop raised: %@", exception);
   }
}

- (void)teardown
{
   _tornDown = YES;
   [self stopPlayerQuietly:_defaultStrongPlayer];
   [self stopPlayerQuietly:_defaultWeakPlayer];
   [self stopPlayerQuietly:_activeStrongPlayer];
   [self stopPlayerQuietly:_activeWeakPlayer];

   CHHapticEngine *engine = _engine;
   if (engine)
   {
      engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) { (void)reason; };
      @try
      {
         /* The block keeps the engine alive until the asynchronous stop has finished. */
         [engine stopWithCompletionHandler:^(NSError *error) {
            if (error)
               NSLog(@"[GamuPad] haptic engine stop failed: %@ (%@)", error, engine);
         }];
      }
      @catch (NSException *exception)
      {
         NSLog(@"[GamuPad] haptic engine stop raised: %@", exception);
      }
   }

   _engine              = nil;
   _supported           = NO;
   _running             = NO;
   _startInFlight       = NO;
   _defaultStrongPlayer = nil;
   _defaultWeakPlayer   = nil;
   _activeStrongPlayer  = nil;
   _activeWeakPlayer    = nil;
}

@end

static GamuPadRumble *gamupad_rumble API_AVAILABLE(ios(13.0)) = nil;

static void gamupad_rumble_setup(void)
{
   if (@available(iOS 13.0, *))
      gamupad_rumble = [GamuPadRumble new];
}

static void gamupad_rumble_release(void)
{
   if (@available(iOS 13.0, *))
   {
      [gamupad_rumble teardown];
      gamupad_rumble = nil;
   }
}

static bool gamupad_rumble_play(bool strong, uint16_t strength)
{
   if (@available(iOS 13.0, *))
      return gamupad_rumble != nil && [gamupad_rumble playStrong:strong strength:strength];
   return false;
}

/* Last request per effect type (strong, weak) for duplicate suppression. */
static bool     gamupad_rumble_seen[2];
static uint16_t gamupad_rumble_last_strength[2];
static uint64_t gamupad_rumble_last_ns[2];

#endif /* HAVE_COREMOTION */

static bool gamupad_set_rumble(unsigned pad, enum retro_rumble_effect effect, uint16_t strength)
{
   (void)pad; /* one phone, one motor */

   if (!gamuroid_rumble_is_enabled() || gamuroid_host_is_stopping())
      return false;
   if (effect != RETRO_RUMBLE_STRONG && effect != RETRO_RUMBLE_WEAK)
      return false;

#ifdef HAVE_COREMOTION
   {
      unsigned slot = (effect == RETRO_RUMBLE_STRONG) ? 0 : 1;
      uint64_t now  = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
      if (     gamupad_rumble_seen[slot]
            && gamupad_rumble_last_strength[slot] == strength
            && now - gamupad_rumble_last_ns[slot] < gamupad_rumble_repeat_window_ns)
         return true;
      gamupad_rumble_seen[slot]          = true;
      gamupad_rumble_last_strength[slot] = strength;
      gamupad_rumble_last_ns[slot]       = now;
   }
   return gamupad_rumble_play(effect == RETRO_RUMBLE_STRONG, strength);
#else
   (void)strength;
   return false;
#endif
}

#pragma mark - Lifecycle

void gamupad_host_reset(void)
{
   if (!gamupad_is_initialized)
      return;
   gamupad_is_initialized = false;
#ifdef HAVE_COREMOTION
   gamupad_rumble_release();
#endif
}

static void *gamupad_init(void *data)
{
   (void)data;
   if (!gamupad_is_initialized)
   {
#ifdef HAVE_COREMOTION
      gamupad_rumble_setup();
#endif
      gamupad_is_initialized = true;

      for (unsigned port = 0; port < gamuroid_supported_user_count(); port++)
      {
         char display_name[32];
         snprintf(display_name, sizeof(display_name), "Gamuroid Player %u", port);
         input_autoconfigure_connect(GAMUPAD_DEVICE_NAME, display_name, GAMUPAD_IDENT, port, 0, 0);
      }
   }
   /* Any non-NULL value means success; RetroArch never dereferences it. */
   return (void *)-1;
}

static void gamupad_destroy(void)
{
   gamupad_host_reset();
}

static bool gamuroid_gamecontroller_joypad_query_pad(unsigned pad)
{
    return pad < gamuroid_supported_user_count();
}

static const char *gamupad_name(unsigned pad)
{
   return (pad < gamuroid_supported_user_count()) ? GAMUPAD_DEVICE_NAME : NULL;
}

static void gamupad_poll(void)
{
   /* State is pushed by the app; nothing to poll. */
}

#pragma mark - Events from the host

void gamupad_host_set_button(unsigned port, unsigned button_id, bool down)
{
   if (port >= MAX_USERS || button_id > GAMUPAD_LAST_BUTTON_ID)
      return;
   if (down)
      gamupad_ports[port].buttons |= (UINT32_C(1) << button_id);
   else
      gamupad_ports[port].buttons &= ~(UINT32_C(1) << button_id);
}

static int16_t gamupad_axis_from_unit(float value)
{
   if (isnan(value))
      value = 0.0f;
   else if (value > 1.0f)
      value = 1.0f;
   else if (value < -1.0f)
      value = -1.0f;
   return (int16_t)(value * 32767.0f);
}

void gamupad_host_set_stick(unsigned port, unsigned stick_id, float x_value, float y_value)
{
   unsigned first_axis;
   if (port >= MAX_USERS)
      return;
   if (stick_id == RETRO_DEVICE_INDEX_ANALOG_LEFT)
      first_axis = 0;
   else if (stick_id == RETRO_DEVICE_INDEX_ANALOG_RIGHT)
      first_axis = 2;
   else
      return;
   /* Up and right arrive positive; the autoconfig axis signs give libretro its "negative Y = up". */
   gamupad_ports[port].axes[first_axis]     = gamupad_axis_from_unit(x_value);
   gamupad_ports[port].axes[first_axis + 1] = gamupad_axis_from_unit(y_value);
}

#pragma mark - Queries from RetroArch

static bool gamupad_port_is_valid(unsigned port)
{
   return port < DEFAULT_MAX_PADS && port < MAX_USERS;
}

static int32_t gamupad_button(unsigned port, uint16_t joykey)
{
   if (!gamupad_port_is_valid(port) || GET_HAT_DIR(joykey))
      return 0;
   if (joykey < 32)
      return (int32_t)((gamupad_ports[port].buttons >> joykey) & 1);
   return 0;
}

static void gamupad_get_buttons(unsigned port, input_bits_t *state)
{
   if (gamupad_port_is_valid(port))
   {
      BITS_COPY16_PTR(state, gamupad_ports[port].buttons);
   }
   else
   {
      BIT256_CLEAR_ALL_PTR(state);
   }
}

static int16_t gamupad_axis(unsigned port, uint32_t joyaxis)
{
   uint32_t negative_axis = AXIS_NEG_GET(joyaxis);
   uint32_t positive_axis = AXIS_POS_GET(joyaxis);

   if (!gamupad_port_is_valid(port))
      return 0;
   if (negative_axis < GAMUPAD_AXIS_COUNT)
   {
      int16_t value = gamupad_ports[port].axes[negative_axis];
      return (value < 0) ? value : 0;
   }
   if (positive_axis < GAMUPAD_AXIS_COUNT)
   {
      int16_t value = gamupad_ports[port].axes[positive_axis];
      return (value > 0) ? value : 0;
   }
   return 0;
}

static int16_t gamupad_state(rarch_joypad_info_t *joypad_info,
      const struct retro_keybind *binds, unsigned port)
{
   int16_t pressed_mask = 0;
   unsigned pad         = joypad_info->joy_idx;
   (void)port;

   if (!gamupad_port_is_valid(pad))
      return 0;

   for (unsigned id = 0; id < RARCH_FIRST_CUSTOM_BIND; id++)
   {
      uint16_t joykey  = (binds[id].joykey != NO_BTN)
         ? binds[id].joykey : joypad_info->auto_binds[id].joykey;
      uint32_t joyaxis = (binds[id].joyaxis != AXIS_NONE)
         ? binds[id].joyaxis : joypad_info->auto_binds[id].joyaxis;

      /* The bit tested is the bind id: the bundled autoconfig maps button n to bind n. */
      if (joykey != NO_BTN && ((gamupad_ports[pad].buttons >> id) & 1))
         pressed_mask |= (int16_t)(1 << id);
      else if (joyaxis != AXIS_NONE
            && ((float)abs(gamupad_axis(pad, joyaxis)) / 32768.0f) > joypad_info->axis_threshold)
         pressed_mask |= (int16_t)(1 << id);
   }
   return pressed_mask;
}

#pragma mark - Driver registration

input_device_driver_t gamuroid_joypad = {
   gamupad_init,
   gamuroid_gamecontroller_joypad_query_pad,
   gamupad_destroy,
   gamupad_button,
   gamupad_state,
   gamupad_get_buttons,
   gamupad_axis,
   gamupad_poll,
   gamupad_set_rumble,
   NULL, /* set_rumble_gain */
   NULL, /* set_sensor_state: motion is handled by the cocoa input driver */
   NULL, /* get_sensor_input */
   gamupad_name,
   GAMUPAD_IDENT,
};
