/* RetroArch - A frontend for libretro.
 *  Copyright (C) 2011-2016 - Daniel De Matteis
 *
 * RetroArch is free software: you can redistribute it and/or modify it under the terms
 * of the GNU General Public License as published by the Free Software Found-
 * ation, either version 3 of the License, or (at your option) any later version.
 *
 * RetroArch is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
 * without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 * PURPOSE. See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along with RetroArch.
 * If not, see <http://www.gnu.org/licenses/>.
 */

/* Gamuroid: upstream libretro/RetroArch ui_cocoatouch.m (master 57acb067b8cc, GPLv3)
 * plus the embedded host used by the Libretro framework. With
 * GAMUROID_EMBEDDED_HOST RetroArch_iOS is an object owned by GamuroidRetroHost, never the
 * application delegate: no main(), the frame driver is the main run-loop observer below,
 * and the host API (declared in cocoa/gamuroid_embedded_host.h) drives one session at a
 * time on the main thread. */

#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include <boolean.h>

#include <file/file_path.h>
#include <queues/task_queue.h>
#include <string/stdstring.h>
#include <retro_timers.h>

#include "cocoa/cocoa_common.h"
#include "cocoa/apple_platform.h"
#include "cocoa/gamuroid_embedded_host.h"
#include "../ui_companion_driver.h"
#include "../../audio/audio_driver.h"
#ifdef HAVE_MICROPHONE
#include "../../audio/microphone_driver.h"
#endif
#include "../../configuration.h"
#include "../../frontend/frontend.h"
#include "../../input/drivers/cocoa_input.h"
#include "../../input/drivers_joypad/gamuroid_joypad_host.h"
#include "../../input/drivers_keyboard/keyboard_event_apple.h"
#include "../../retroarch.h"
#include "../../autosave.h"
#include "../../content.h"
#include "../../tasks/task_content.h"
#include "../../paths.h"
#include "../../core.h"
#include "../../verbosity.h"

#ifdef HAVE_MENU
#include "../../menu/menu_setting.h"
#endif

#import <AVFoundation/AVFoundation.h>
#import <CoreFoundation/CoreFoundation.h>
#ifdef HAVE_COCOA_METAL
#import <Metal/Metal.h>
#endif

#ifdef GAMUROID_EMBEDDED_HOST
#import "cocoa/GamuroidRetroHost.h"
#endif
#include "../../runloop.h"
#include "../../driver.h"
#include "../../gfx/video_driver.h"
#include "../../core_option_manager.h"

#import <MetricKit/MetricKit.h>
#import <MetricKit/MXMetricManager.h>

#ifdef HAVE_MFI
#import <GameController/GCMouse.h>
#endif

#ifdef HAVE_SDL2
#define SDL_MAIN_HANDLED
#include "SDL.h"
#endif

#if defined(HAVE_COCOA_METAL) || defined(HAVE_COCOATOUCH)
id<ApplePlatform> apple_platform;
#else
static id apple_platform;
#endif
static CFRunLoopObserverRef iterate_observer;
static BOOL LibretroSaveStateInFlight = false;
static void mark_libretro_stopped(void);
static void reset_libretro_session_frontend_state(void);

/* Embedded-host session state (main thread only). */
static BOOL LibretroInitial                = false; /* a session is initialized */
static BOOL RespectSilentMode              = false; /* applied at content load */
static float g_custom_fastforward_ratio    = 0.0f;  /* app speed, 0 = none */
static NSString *_Nullable needToLoadStatePath    = nil;   /* keep-state reload requested while paused */
static NSString *_Nullable gamuroid_host_save_ext = nil;   /* SRAM extension for the next content load */
static double gamuroid_host_reload_delay   = 0.0;   /* seconds before the state load of a reload */
static unsigned gamuroid_host_session_id   = 0;     /* bumped at every start */

float gamuroid_custom_fastforward_ratio(void)
{
   return g_custom_fastforward_ratio;
}

static BOOL gamuroid_core_path_allows_async_save_state(NSString *corePath)
{
    NSString *lower = corePath ? corePath.lowercaseString : @"";
    if (lower.length == 0) {
        return NO;
    }

    NSArray<NSString *> *blocked = @[
        @"azahar",
        @"flycast",
        @"dolphin",
        @"ppsspp",
        @"melonds",
        @"desmume",
        @"mednafen.psx",
        @"mednafen.saturn",
        @"mupen64",
        @"yabause"
    ];
    for (NSString *needle in blocked) {
        if ([lower containsString:needle]) {
            return NO;
        }
    }

    NSArray<NSString *> *allowed = @[
        @"mgba",
        @"gambatte",
        @"nestopia",
        @"gearsystem",
        @"clownmdemu",
        @"bsnes",
        @"bsnes-jg",
        @"vbam",
        @"pokemini",
        @"mednafen.vb"
    ];
    for (NSString *needle in allowed) {
        if ([lower containsString:needle]) {
            return YES;
        }
    }
    return NO;
}

/* A new, not yet existing .state file path in the temporary directory; unique per call. */
static NSString *gamuroid_new_temp_state_path(void)
{
    NSString *name = [[NSUUID UUID].UUIDString stringByAppendingPathExtension:@"state"];
    return [NSTemporaryDirectory() stringByAppendingPathComponent:name];
}

static BOOL gamuroid_save_state_runtime_is_ready(void)
{
    if (!LibretroInitial || gamuroid_host_is_stopping()) {
        return NO;
    }

    runloop_state_t *runloop_st = runloop_state_get_ptr();
    return runloop_st && (runloop_st->flags & RUNLOOP_FLAG_CORE_RUNNING);
}

static struct string_list *ui_companion_cocoatouch_get_app_icons(void)
{
   static struct string_list *list = NULL;
   static dispatch_once_t onceToken;

   dispatch_once(&onceToken, ^{
         union string_list_elem_attr attr;
         attr.i = 0;
         NSDictionary *iconfiles = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleIcons"];
         NSString *primary;
         const char *cstr;
#if TARGET_OS_TV
         primary = iconfiles[@"CFBundlePrimaryIcon"];
#else
         primary = iconfiles[@"CFBundlePrimaryIcon"][@"CFBundleIconName"];
#endif
         list = string_list_new();
         cstr = [primary cStringUsingEncoding:kCFStringEncodingUTF8];
         if (cstr)
            string_list_append(list, cstr, attr);

         NSArray<NSString *> *alts;
#if TARGET_OS_TV
         alts = iconfiles[@"CFBundleAlternateIcons"];
#else
         alts = [iconfiles[@"CFBundleAlternateIcons"] allKeys];
#endif
         NSArray<NSString *> *sorted = [alts sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
         for (NSString *str in sorted)
         {
            cstr = [str cStringUsingEncoding:kCFStringEncodingUTF8];
            if (cstr)
               string_list_append(list, cstr, attr);
         }
      });

   return list;
}

static void ui_companion_cocoatouch_set_app_icon(const char *iconName)
{
   NSString *str;
   if (!string_is_equal(iconName, "Default"))
      str = [NSString stringWithCString:iconName encoding:NSUTF8StringEncoding];
   [[UIApplication sharedApplication] setAlternateIconName:str completionHandler:nil];
}

static uintptr_t ui_companion_cocoatouch_get_app_icon_texture(const char *icon)
{
   static NSMutableDictionary<NSString *, NSNumber *> *textures = nil;
   static dispatch_once_t once;
   dispatch_once(&once, ^{
      textures = [NSMutableDictionary dictionaryWithCapacity:6];
   });

   NSString *iconName = [NSString stringWithUTF8String:icon];
   if (!textures[iconName])
   {
      UIImage *img = [UIImage imageNamed:iconName];
      if (!img)
      {
         RARCH_LOG("could not load %s\n", icon);
         return 0;
      }
      NSData *png = UIImagePNGRepresentation(img);
      if (!png)
      {
         RARCH_LOG("could not get png for %s\n", icon);
         return 0;
      }

      uintptr_t item;
      gfx_display_reset_textures_list_buffer(&item, TEXTURE_FILTER_MIPMAP_LINEAR,
                                             (void*)[png bytes], (unsigned int)[png length], IMAGE_TYPE_PNG,
                                             NULL, NULL);
      textures[iconName] = [NSNumber numberWithUnsignedLong:item];
   }

   return [textures[iconName] unsignedLongValue];
}

/* The embedded host has no menu to react to companion commands, but the run-loop
 * observer below and the companion table still need a handler to call. */
static void ui_companion_cocoatouch_event_command(void *data, enum event_command cmd)
{
   (void)data;
   (void)cmd;
}

static void rarch_draw_observer(CFRunLoopObserverRef observer,
    CFRunLoopActivity activity, void *info)
{
   uint32_t runloop_flags;
   int          ret;

   if (!LibretroInitial || gamuroid_host_is_stopping())
      return;

   ret = runloop_iterate();

   if (ret == -1)
   {
      ui_companion_cocoatouch_event_command(
            NULL, CMD_EVENT_MENU_SAVE_CURRENT_CONFIG);
#ifdef GAMUROID_EMBEDDED_HOST
      /* RetroArch wants to quit (also seen briefly while a Vulkan swapchain is
       * re-created). The app owns the process and the session: leave teardown to
       * the host's -stop. */
      return;
#else
      main_exit(NULL);
      exit(0);
      return;
#endif
   }

   task_queue_check();

   runloop_flags = runloop_get_flags();
   if (!(runloop_flags & RUNLOOP_FLAG_IDLE))
      CFRunLoopWakeUp(CFRunLoopGetMain());
}

void rarch_start_draw_observer(void)
{
   if (iterate_observer && CFRunLoopObserverIsValid(iterate_observer))
       return;

   if (iterate_observer != NULL)
      CFRelease(iterate_observer);
   iterate_observer = CFRunLoopObserverCreate(0, kCFRunLoopBeforeWaiting,
                                              true, 0, rarch_draw_observer, 0);
   CFRunLoopAddObserver(CFRunLoopGetMain(), iterate_observer, kCFRunLoopCommonModes);
}

void rarch_stop_draw_observer(void)
{
    if (!iterate_observer || !CFRunLoopObserverIsValid(iterate_observer))
        return;
    CFRunLoopObserverInvalidate(iterate_observer);
    CFRelease(iterate_observer);
    iterate_observer = NULL;
}

void get_ios_version(int *major, int *minor)
{
   static int savedMajor, savedMinor;
   static dispatch_once_t onceToken;

   dispatch_once(&onceToken, ^ {
         NSArray *decomposed_os_version = [[UIDevice currentDevice].systemVersion componentsSeparatedByString:@"."];
         if (decomposed_os_version.count > 0)
            savedMajor = (int)[decomposed_os_version[0] integerValue];
         if (decomposed_os_version.count > 1)
            savedMinor = (int)[decomposed_os_version[1] integerValue];
      });
   if (major) *major = savedMajor;
   if (minor) *minor = savedMinor;
}

bool ios_running_on_ipad(void)
{
   return (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad);
}

/* Input helpers: This is kept here because it needs ObjC */
static void handle_touch_event(NSArray* touches)
{
#if !TARGET_OS_TV
   unsigned i;
   cocoa_input_data_t *apple = (cocoa_input_data_t*)
      input_state_get_ptr()->current_data;
   float scale               = cocoa_screen_get_native_scale();

   if (!apple)
      return;

   apple->touch_count = 0;

   for (i = 0; i < touches.count && (apple->touch_count < MAX_TOUCHES); i++)
   {
      UITouch      *touch = [touches objectAtIndex:i];
      CGPoint       coord = [touch locationInView:[touch view]];
      if (touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled)
      {
         apple->touches[apple->touch_count   ].screen_x = coord.x * scale;
         apple->touches[apple->touch_count ++].screen_y = coord.y * scale;
      }
   }
#endif
}

#ifndef HAVE_APPLE_STORE
/* iOS7 Keyboard support */
@interface UIEvent(iOS7Keyboard)
@property(readonly, nonatomic) long long _keyCode;
@property(readonly, nonatomic) _Bool _isKeyDown;
@property(retain, nonatomic) NSString *_privateInput;
@property(nonatomic) long long _modifierFlags;
- (struct __IOHIDEvent { }*)_hidEvent;
@end

@interface UIApplication(iOS7Keyboard)
- (void)handleKeyUIEvent:(UIEvent*)event;
- (id)_keyCommandForEvent:(UIEvent*)event;
@end
#endif

@interface RApplication : UIApplication
@end

@implementation RApplication

#ifndef HAVE_APPLE_STORE
/* Keyboard handler for iOS 7. */

/* This is copied here as it isn't
 * defined in any standard iOS header */
enum
{
   NSAlphaShiftKeyMask                  = 1 << 16,
   NSShiftKeyMask                       = 1 << 17,
   NSControlKeyMask                     = 1 << 18,
   NSAlternateKeyMask                   = 1 << 19,
   NSCommandKeyMask                     = 1 << 20,
   NSNumericPadKeyMask                  = 1 << 21,
   NSHelpKeyMask                        = 1 << 22,
   NSFunctionKeyMask                    = 1 << 23,
   NSDeviceIndependentModifierFlagsMask = 0xffff0000U
};

/* This is specifically for iOS 9, according to the private headers */
-(void)handleKeyUIEvent:(UIEvent *)event
{
    /* This gets called twice with the same timestamp
     * for each keypress, that's fine for polling
     * but is bad for business with events. */
    static double last_time_stamp;

    if (last_time_stamp == event.timestamp)
       return [super handleKeyUIEvent:event];

    last_time_stamp        = event.timestamp;

    /* If the _hidEvent is NULL, [event _keyCode] will crash.
     * (This happens with the on screen keyboard). */
    if (event._hidEvent)
    {
        NSString       *ch = (NSString*)event._privateInput;
        uint32_t character = 0;
        uint32_t mod       = 0;
        NSUInteger mods    = event._modifierFlags;

        if (mods & NSAlphaShiftKeyMask)
           mod |= RETROKMOD_CAPSLOCK;
        if (mods & NSShiftKeyMask)
           mod |= RETROKMOD_SHIFT;
        if (mods & NSControlKeyMask)
           mod |= RETROKMOD_CTRL;
        if (mods & NSAlternateKeyMask)
           mod |= RETROKMOD_ALT;
        if (mods & NSCommandKeyMask)
           mod |= RETROKMOD_META;
        if (mods & NSNumericPadKeyMask)
           mod |= RETROKMOD_NUMLOCK;

        if (ch && ch.length != 0)
        {
            unsigned i;
            character = [ch characterAtIndex:0];

            apple_input_keyboard_event(event._isKeyDown,
                  (uint32_t)event._keyCode, 0, mod,
                  RETRO_DEVICE_KEYBOARD);

            for (i = 1; i < ch.length; i++)
                apple_input_keyboard_event(event._isKeyDown,
                      0, [ch characterAtIndex:i], mod,
                      RETRO_DEVICE_KEYBOARD);
        }

        apple_input_keyboard_event(event._isKeyDown,
              (uint32_t)event._keyCode, character, mod,
              RETRO_DEVICE_KEYBOARD);
    }

    [super handleKeyUIEvent:event];
}

/* This is for iOS versions < 9.0 */
- (id)_keyCommandForEvent:(UIEvent*)event
{
   /* This gets called twice with the same timestamp
    * for each keypress, that's fine for polling
    * but is bad for business with events. */
   static double last_time_stamp;

   if (last_time_stamp == event.timestamp)
      return [super _keyCommandForEvent:event];
   last_time_stamp = event.timestamp;

   /* If the _hidEvent is null, [event _keyCode] will crash.
    * (This happens with the on screen keyboard). */
   if (event._hidEvent)
   {
      NSString       *ch = (NSString*)event._privateInput;
      uint32_t character = 0;
      uint32_t mod       = 0;
      NSUInteger mods    = event._modifierFlags;

      if (mods & NSAlphaShiftKeyMask)
         mod |= RETROKMOD_CAPSLOCK;
      if (mods & NSShiftKeyMask)
         mod |= RETROKMOD_SHIFT;
      if (mods & NSControlKeyMask)
         mod |= RETROKMOD_CTRL;
      if (mods & NSAlternateKeyMask)
         mod |= RETROKMOD_ALT;
      if (mods & NSCommandKeyMask)
         mod |= RETROKMOD_META;
      if (mods & NSNumericPadKeyMask)
         mod |= RETROKMOD_NUMLOCK;

      if (ch && ch.length != 0)
      {
         unsigned i;
         character = [ch characterAtIndex:0];

         apple_input_keyboard_event(event._isKeyDown,
               (uint32_t)event._keyCode, 0, mod,
               RETRO_DEVICE_KEYBOARD);

         for (i = 1; i < ch.length; i++)
            apple_input_keyboard_event(event._isKeyDown,
                  0, [ch characterAtIndex:i], mod,
                  RETRO_DEVICE_KEYBOARD);
      }

      apple_input_keyboard_event(event._isKeyDown,
            (uint32_t)event._keyCode, character, mod,
            RETRO_DEVICE_KEYBOARD);
   }

   return [super _keyCommandForEvent:event];
}
#else
- (void)handleUIPress:(UIPress *)press withEvent:(UIPressesEvent *)event down:(BOOL)down
{
   NSString       *ch;
   uint32_t character = 0;
   uint32_t mod       = 0;
   NSUInteger mods    = 0;
   if (@available(iOS 13.4, tvOS 13.4, *))
   {
      ch = (NSString*)press.key.characters;
      mods = event.modifierFlags;
   }

   if (mods & UIKeyModifierAlphaShift)
      mod |= RETROKMOD_CAPSLOCK;
   if (mods & UIKeyModifierShift)
      mod |= RETROKMOD_SHIFT;
   if (mods & UIKeyModifierControl)
      mod |= RETROKMOD_CTRL;
   if (mods & UIKeyModifierAlternate)
      mod |= RETROKMOD_ALT;
   if (mods & UIKeyModifierCommand)
      mod |= RETROKMOD_META;
   if (mods & UIKeyModifierNumericPad)
      mod |= RETROKMOD_NUMLOCK;

   if (ch && ch.length != 0)
   {
      unsigned i;
      character = [ch characterAtIndex:0];

      apple_input_keyboard_event(down,
                                 (uint32_t)press.key.keyCode, 0, mod,
                                 RETRO_DEVICE_KEYBOARD);

      for (i = 1; i < ch.length; i++)
         apple_input_keyboard_event(down,
                                    0, [ch characterAtIndex:i], mod,
                                    RETRO_DEVICE_KEYBOARD);
   }

   if (@available(iOS 13.4, tvOS 13.4, *))
      apple_input_keyboard_event(down,
                                 (uint32_t)press.key.keyCode, character, mod,
                                 RETRO_DEVICE_KEYBOARD);
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
   for (UIPress *press in presses)
      [self handleUIPress:press withEvent:event down:YES];
   [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
   for (UIPress *press in presses)
      [self handleUIPress:press withEvent:event down:NO];
   [super pressesEnded:presses withEvent:event];
}
#endif

#define GSEVENT_TYPE_KEYDOWN 10
#define GSEVENT_TYPE_KEYUP 11

- (void)sendEvent:(UIEvent *)event
{
   [super sendEvent:event];
   if (@available(iOS 13.4, tvOS 13.4, *))
   {
      if (event.type == UIEventTypeHover)
         return;
   }
   if (event.allTouches.count)
      handle_touch_event(event.allTouches.allObjects);

#if __IPHONE_OS_VERSION_MAX_ALLOWED < 70000
   {
      int major, minor;
      get_ios_version(&major, &minor);

      if ((major < 7) && [event respondsToSelector:@selector(_gsEvent)])
      {
         /* Keyboard event hack for iOS versions prior to iOS 7.
          *
          * Derived from:
                  * http://nacho4d-nacho4d.blogspot.com/2012/01/
                  * catching-keyboard-events-in-ios.html
                  */
         const uint8_t *eventMem = objc_unretainedPointer([event performSelector:@selector(_gsEvent)]);
         int           eventType = eventMem ? *(int*)&eventMem[8] : 0;

         switch (eventType)
         {
            case GSEVENT_TYPE_KEYDOWN:
              case GSEVENT_TYPE_KEYUP:
               apple_input_keyboard_event(eventType == GSEVENT_TYPE_KEYDOWN,
                     *(uint16_t*)&eventMem[0x3C], 0, 0, RETRO_DEVICE_KEYBOARD);
               break;
         }
      }
   }
#endif
}

@end

#ifdef HAVE_COCOA_METAL
@implementation MetalLayerView

+ (Class)layerClass {
    return [CAMetalLayer class];
}

- (instancetype)init {
    self = [super init];
    if (self)
        [self setupMetalLayer];
    return self;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self)
        [self setupMetalLayer];
    return self;
}

- (CAMetalLayer *)metalLayer {
    return (CAMetalLayer *)self.layer;
}

- (void)setupMetalLayer {
    self.metalLayer.device = MTLCreateSystemDefaultDevice();
    self.metalLayer.contentsScale = cocoa_screen_get_native_scale();
    self.metalLayer.opaque = YES;
}

/* Duo gap 7: the layer follows the display the view is on now (outer/inner
 * display, Split View); same value as before on a single-screen device. */
- (void)refreshContentsScale {
    float scale = cocoa_screen_get_native_scale();
    if (scale > 0.0f && self.metalLayer.contentsScale != scale)
        self.metalLayer.contentsScale = scale;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self refreshContentsScale];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self refreshContentsScale];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self refreshContentsScale];
}
#pragma clang diagnostic pop

@end
#endif

#if TARGET_OS_IOS
@interface RetroArch_iOS () <MXMetricManagerSubscriber, UIPointerInteractionDelegate>
@end
#endif

@implementation RetroArch_iOS

#pragma mark - ApplePlatform
-(id)renderView { return _renderView; }
-(bool)hasFocus
{
    return [[UIApplication sharedApplication] applicationState] == UIApplicationStateActive;
}

- (void)setViewType:(apple_view_type_t)vt
{
   if (vt == _vt)
      return;

   _vt = vt;
   if (_renderView != nil)
   {
      [_renderView removeFromSuperview];
      _renderView = nil;
   }

   switch (vt)
   {
#ifdef HAVE_COCOA_METAL
       case APPLE_VIEW_TYPE_VULKAN:
         _renderView = [MetalLayerView new];
#if TARGET_OS_IOS
         _renderView.multipleTouchEnabled = YES;
#endif
         break;
       case APPLE_VIEW_TYPE_METAL:
         {
            MetalView *v = [MetalView new];
            v.paused                = YES;
            v.enableSetNeedsDisplay = NO;
#if TARGET_OS_IOS
            v.multipleTouchEnabled  = YES;
#endif
            _renderView = v;
         }
         break;
#endif
       case APPLE_VIEW_TYPE_OPENGL_ES:
         _renderView = (BRIDGE GLKView*)glkitview_init();
         break;

       case APPLE_VIEW_TYPE_NONE:
       default:
         return;
   }

   _renderView.translatesAutoresizingMaskIntoConstraints = NO;
   UIView *rootView = [CocoaView get].view;
   [rootView addSubview:_renderView];
#if TARGET_OS_IOS
   if (@available(iOS 13.4, *))
   {
      [_renderView addInteraction:[[UIPointerInteraction alloc] initWithDelegate:self]];
      _renderView.userInteractionEnabled = YES;
   }
#endif
   [[_renderView.topAnchor constraintEqualToAnchor:rootView.topAnchor] setActive:YES];
   [[_renderView.bottomAnchor constraintEqualToAnchor:rootView.bottomAnchor] setActive:YES];
   [[_renderView.leadingAnchor constraintEqualToAnchor:rootView.leadingAnchor] setActive:YES];
   [[_renderView.trailingAnchor constraintEqualToAnchor:rootView.trailingAnchor] setActive:YES];
   [_renderView layoutIfNeeded];
}

- (apple_view_type_t)viewType { return _vt; }

- (void)setVideoMode:(gfx_ctx_mode_t)mode
{
#ifdef HAVE_COCOA_METAL
   MetalView *metalView = (MetalView*) _renderView;
   float scale          = cocoa_screen_get_scale();
   [metalView setDrawableSize:CGSizeMake(
         cocoa_pixel_extent(_renderView.bounds.size.width, scale),
         cocoa_pixel_extent(_renderView.bounds.size.height, scale)
         )];
#endif
}

- (void)setCursorVisible:(bool)v { /* no-op for iOS */ }
- (bool)setDisableDisplaySleep:(bool)disable
{
#if TARGET_OS_TV
   [[UIApplication sharedApplication] setIdleTimerDisabled:disable];
   return YES;
#else
   return NO;
#endif
}
#ifdef GAMUROID_EMBEDDED_HOST
/* The host instance belongs to the GamuroidRetroHost bridge (nil on the simulator). */
+ (RetroArch_iOS*)get { return (RetroArch_iOS*)[GamuroidRetroHost sharedInstance].retroArch_iOS; }
#else
+ (RetroArch_iOS*)get { return (RetroArch_iOS*)[[UIApplication sharedApplication] delegate]; }
#endif

-(NSString*)documentsDirectory
{
   if (_documentsDirectory == nil)
   {
#if TARGET_OS_IOS
      NSArray *paths      = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
#elif TARGET_OS_TV
      NSArray *paths      = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
#endif
      _documentsDirectory = paths.firstObject;
   }
   return _documentsDirectory;
}

- (void)handleAudioSessionInterruption:(NSNotification *)notification
{
   NSNumber *type = notification.userInfo[AVAudioSessionInterruptionTypeKey];
   if (![type isKindOfClass:[NSNumber class]])
      return;

   if ([type unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan)
   {
      RARCH_LOG("AudioSession Interruption Began\n");
      audio_driver_stop();
   }
   else if ([type unsignedIntegerValue] == AVAudioSessionInterruptionTypeEnded)
   {
      RARCH_LOG("AudioSession Interruption Ended\n");
      audio_driver_start(false);
#ifdef HAVE_MICROPHONE
      /* iOS dừng mọi I/O unit khi interruption nhưng ở trên chỉ start lại output; mic là RemoteIO riêng,
       * không ai start lại ⇒ câm tới hết phiên. Chỉ re-arm khi core ĐANG bật mic, vì
       * microphone_driver_start() ép ENABLED vô điều kiện. Start một unit đang chạy là no-op. */
      {
         microphone_driver_state_t *mic_st = microphone_state_get_ptr();
         unsigned mic_flags                = mic_st ? mic_st->microphone.flags : 0;

         if (     (mic_flags & MICROPHONE_FLAG_ACTIVE)
               && (mic_flags & MICROPHONE_FLAG_ENABLED)
               && !(mic_flags & MICROPHONE_FLAG_PENDING))
         {
            RARCH_LOG("[CoreAudioMic] re-arm after interruption\n");
            command_event(CMD_EVENT_MICROPHONE_START, NULL);
         }
      }
#endif
   }
}

- (void)applicationDidFinishLaunching:(UIApplication *)application
{
   char arguments[]   = "retroarch";
   char       *argv[] = {arguments,   NULL};
   int argc           = 1;
   apple_platform     = self;

   if ([NSUserDefaults.standardUserDefaults boolForKey:@"restore_default_config"])
   {
      [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"restore_default_config"];
      [NSUserDefaults.standardUserDefaults setObject:@"" forKey:@FILE_PATH_MAIN_CONFIG];

      // Get the Caches directory path
      NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
      NSString *cachesDirectory = [paths firstObject];

      // Define the original and new file paths
      NSString *originalPath = [cachesDirectory stringByAppendingPathComponent:@"RetroArch/config/retroarch.cfg"];
      NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
      [dateFormatter setDateFormat:@"HHmm-yyMMdd"];
      NSString *timestamp = [dateFormatter stringFromDate:[NSDate date]];
      NSString *newPath = [cachesDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"RetroArch/config/RetroArch-%@.cfg", timestamp]];

      // File manager instance
      NSFileManager *fileManager = [NSFileManager defaultManager];

      // Check if the file exists and rename it
      if ([fileManager fileExistsAtPath:originalPath])
      {
          NSError *error = nil;
          if ([fileManager moveItemAtPath:originalPath toPath:newPath error:&error])
              NSLog(@"File renamed to %@", newPath);
          else
              NSLog(@"Error renaming file: %@", error.localizedDescription);
      }
      else
          NSLog(@"File does not exist at path %@", originalPath);
   }

   [self setDelegate:self];

   /* Setup window */
   self.window        = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
   [self.window makeKeyAndVisible];

   [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleAudioSessionInterruption:) name:AVAudioSessionInterruptionNotification object:[AVAudioSession sharedInstance]];

   [self showGameView];

   rarch_main(argc, argv, NULL);

   rarch_start_draw_observer();

#if TARGET_OS_TV
   update_topshelf();
#endif

#if TARGET_OS_IOS
   if (@available(iOS 13.0, *))
      [MXMetricManager.sharedManager addSubscriber:self];
#endif

#ifdef HAVE_MFI
   extern void *apple_gamecontroller_joypad_init(void *data);
   apple_gamecontroller_joypad_init(NULL);
   if (@available(macOS 11, iOS 14, tvOS 14, *))
   {
      [[NSNotificationCenter defaultCenter] addObserverForName:GCMouseDidConnectNotification
                                                        object:nil
                                                         queue:[NSOperationQueue mainQueue]
                                                    usingBlock:^(NSNotification *note)
       {
         GCMouse *mouse = note.object;
         mouse.mouseInput.mouseMovedHandler = ^(GCMouseInput * _Nonnull mouse, float delta_x, float delta_y)
         {
            cocoa_input_data_t *apple = (cocoa_input_data_t*) input_state_get_ptr()->current_data;
            if (!apple)
               return;
            apple->window_pos_x      += (int16_t)delta_x;
            apple->window_pos_y      -= (int16_t)delta_y;
         };
         mouse.mouseInput.leftButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed)
         {
            cocoa_input_data_t *apple = (cocoa_input_data_t*) input_state_get_ptr()->current_data;
            if (!apple)
               return;
            if (pressed)
                apple->mouse_buttons |= (1 << 0);
            else
                apple->mouse_buttons &= ~(1 << 0);
         };
         mouse.mouseInput.rightButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed)
         {
            cocoa_input_data_t *apple = (cocoa_input_data_t*) input_state_get_ptr()->current_data;
            if (!apple)
               return;
            if (pressed)
                apple->mouse_buttons |= (1 << 1);
            else
                apple->mouse_buttons &= ~(1 << 1);
         };
      }];
   }
#endif
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
#if TARGET_OS_TV
   update_topshelf();
#endif
   rarch_stop_draw_observer();
   command_event(CMD_EVENT_SAVE_FILES, NULL);
}

- (void)applicationWillTerminate:(UIApplication *)application
{
   rarch_stop_draw_observer();
   retroarch_main_quit();
}

- (void)applicationWillResignActive:(UIApplication *)application
{
   self.bgDate = [NSDate date];
   rarch_stop_draw_observer();
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
   rarch_start_draw_observer();
   NSError *error;
   settings_t *settings            = config_get_ptr();
   bool ui_companion_start_on_boot = settings->bools.ui_companion_start_on_boot;

   if (settings->bools.audio_respect_silent_mode)
       [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient error:&error];
   else
       [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&error];

   if (!ui_companion_start_on_boot)
      [self showGameView];

#ifdef HAVE_CLOUDSYNC
   if (self.bgDate)
   {
      if (   [[NSDate date] timeIntervalSinceDate:self.bgDate] > 60.0f
          && (   !(runloop_get_flags() & RUNLOOP_FLAG_CORE_RUNNING)
              || retroarch_ctl(RARCH_CTL_IS_DUMMY_CORE, NULL)))
         task_push_cloud_sync();
      self.bgDate = nil;
   }
#endif
}

-(BOOL)openRetroArchURL:(NSURL *)url
{
   if ([url.host isEqualToString:@"topshelf"])
   {
      NSURLComponents *comp = [[NSURLComponents alloc] initWithURL:url resolvingAgainstBaseURL:NO];
      NSString *ns_path, *ns_core_path;
      char path[PATH_MAX_LENGTH];
      char core_path[PATH_MAX_LENGTH];
      content_ctx_info_t content_info = { 0 };
      for (NSURLQueryItem *q in comp.queryItems)
      {
         if ([q.name isEqualToString:@"path"])
            ns_path = q.value;
         else if ([q.name isEqualToString:@"core_path"])
            ns_core_path = q.value;
      }
      if (!ns_path || !ns_core_path)
         return NO;
      fill_pathname_expand_special(path, [ns_path UTF8String], sizeof(path));
      fill_pathname_expand_special(core_path, [ns_core_path UTF8String], sizeof(core_path));
      RARCH_LOG("TopShelf told us to open %s with %s\n", path, core_path);
      return task_push_load_content_with_new_core_from_companion_ui(core_path, path,
                                                                    NULL, NULL, NULL,
                                                                    &content_info, NULL, NULL);
   }
   return NO;
}

-(BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
    if ([[url scheme] isEqualToString:@"retroarch"])
        return [self openRetroArchURL:url];

   NSFileManager *manager = [NSFileManager defaultManager];
   NSString     *filename = (NSString*)url.path.lastPathComponent;
   NSError         *error = nil;
   settings_t *settings   = config_get_ptr();
   char fullpath[PATH_MAX_LENGTH] = {0};
   fill_pathname_join_special(fullpath, settings->paths.directory_core_assets, [filename UTF8String], sizeof(fullpath));
   NSString  *destination = [NSString stringWithUTF8String:fullpath];
   /* Copy file to documents directory if it's not already
    * inside Documents directory */
   if ([url startAccessingSecurityScopedResource])
   {
      if (![[url path] containsString: self.documentsDirectory])
         if (![manager fileExistsAtPath:destination])
            [manager copyItemAtPath:[url path] toPath:destination error:&error];
      [url stopAccessingSecurityScopedResource];
   }
   task_push_dbscan(
      settings->paths.directory_playlist,
      settings->paths.path_content_database,
      fullpath,
      false,
      false,
      NULL);
   return true;
}

- (void)navigationController:(UINavigationController *)navigationController willShowViewController:(UIViewController *)viewController animated:(BOOL)animated
{
#if TARGET_OS_IOS
   [self setToolbarHidden:![[viewController toolbarItems] count] animated:YES];
#endif
}

- (void)showGameView
{
   [self popToRootViewControllerAnimated:NO];

#if TARGET_OS_IOS
   [self setToolbarHidden:true animated:NO];
   [[UIApplication sharedApplication] setStatusBarHidden:true withAnimation:UIStatusBarAnimationNone];
   [[UIApplication sharedApplication] setIdleTimerDisabled:true];
#endif

   [self.window setRootViewController:[CocoaView get]];

   dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
         if (!LibretroInitial || gamuroid_host_is_stopping()) { return; }
         command_event(CMD_EVENT_AUDIO_START, NULL);
         });
}

- (void)supportOtherAudioSessions { }

#if TARGET_OS_IOS
- (void)didReceiveMetricPayloads:(NSArray<MXMetricPayload *> *)payloads API_AVAILABLE(ios(13.0))
{
    for (MXMetricPayload *payload in payloads)
    {
        NSString *json = [[NSString alloc] initWithData:[payload JSONRepresentation] encoding:kCFStringEncodingUTF8];
        RARCH_LOG("Got Metric Payload:\n%s\n", [json cStringUsingEncoding:kCFStringEncodingUTF8]);
    }
}

- (void)didReceiveDiagnosticPayloads:(NSArray<MXDiagnosticPayload *> *)payloads API_AVAILABLE(ios(14.0))
{
    for (MXDiagnosticPayload *payload in payloads)
    {
        NSString *json = [[NSString alloc] initWithData:[payload JSONRepresentation] encoding:kCFStringEncodingUTF8];
        RARCH_LOG("Got Diagnostic Payload:\n%s\n", [json cStringUsingEncoding:kCFStringEncodingUTF8]);
    }
}

- (UIPointerStyle *)pointerInteraction:(UIPointerInteraction *)interaction styleForRegion:(UIPointerRegion *)region API_AVAILABLE(ios(13.4))
{
   cocoa_input_data_t *apple = (cocoa_input_data_t*) input_state_get_ptr()->current_data;
   if (!apple)
      return nil;
   if (apple->mouse_grabbed)
      return [UIPointerStyle hiddenPointerStyle];
   return nil;
}

- (UIPointerRegion *)pointerInteraction:(UIPointerInteraction *)interaction
                       regionForRequest:(UIPointerRegionRequest *)request
                          defaultRegion:(UIPointerRegion *)defaultRegion API_AVAILABLE(ios(13.4))
{
   cocoa_input_data_t *apple = (cocoa_input_data_t*) input_state_get_ptr()->current_data;
   if (!apple || apple->mouse_grabbed)
      return nil;
   CGPoint location = [apple_platform.renderView convertPoint:[request location] fromView:nil];
   float scale = cocoa_screen_get_scale();
   apple->touches[0].screen_x = (int16_t)(location.x * scale);
   apple->touches[0].screen_y = (int16_t)(location.y * scale);
   apple->window_pos_x = (int16_t)(location.x * scale);
   apple->window_pos_y = (int16_t)(location.y * scale);
   return [UIPointerRegion regionWithRect:[apple_platform.renderView bounds] identifier:@"game view"];
}
#endif

#ifdef DEBUG
/* [AUDIO_LIFECYCLE] DEBUG-only probe (2026-06-10, T2 audio-churn investigation).
 * Libretro frontend session begin/end markers. The libretro output AudioUnit is
 * counted separately in coreaudio.c / coreaudio3.m; this pairs each begin with its
 * teardown (setActive:NO) so session-vs-unit balance is visible per game. */
static int g_audio_lifecycle_libretro_session_live = 0;
#endif

static void mark_libretro_stopped(void) {
    LibretroInitial = false;
    LibretroSaveStateInFlight = false;
    gamuroid_set_host_stopping(false);
    rarch_stop_draw_observer();
}

- (BOOL)hostSessionIsOpen {
    return LibretroInitial;
}

- (BOOL)hostSessionIsEnding {
    return gamuroid_host_is_stopping();
}

- (BOOL)hostCoreAcceptsContent {
    if (!LibretroInitial || gamuroid_host_is_stopping()) {
        return NO;
    }
    if (!iterate_observer || !CFRunLoopObserverIsValid(iterate_observer)) {
        return NO;
    }
    return YES;
}

- (BOOL)hostCoreIsRunning {
    if (!LibretroInitial || gamuroid_host_is_stopping()) {
        return NO;
    }
    runloop_state_t *runloop_st = runloop_state_get_ptr();
    if (!runloop_st) {
        return NO;
    }
    return (runloop_st->flags & RUNLOOP_FLAG_CORE_RUNNING) != 0;
}

- (uint64_t)hostPresentedFrameCount {
    video_driver_state_t *video_st = video_state_get_ptr();
    if (!video_st) {
        return 0;
    }
    return video_st->frame_count;
}

- (BOOL)hostSaveStateControlledWithCompletion:(void (^)(NSString *path))completion {
    if (!completion) {
        return NO;
    }

    BOOL coreAllowed = gamuroid_core_path_allows_async_save_state(self.hostCorePath);
    BOOL taskThreaded = task_queue_is_threaded();
    BOOL backgroundAllowed = content_save_state_in_background_enabled();
    if (!coreAllowed || !taskThreaded || !backgroundAllowed) {
#ifdef DEBUG
        NSLog(@"[PERF][SAVE_STATE] asyncControlled fallback reason=guard coreAllowed=%s taskThreaded=%s backgroundAllowed=%s corePath=%@",
              coreAllowed ? "YES" : "NO",
              taskThreaded ? "YES" : "NO",
              backgroundAllowed ? "YES" : "NO",
              self.hostCorePath ?: @"<nil>");
#endif
        return [self hostSaveStateWithCompletion:completion];
    }

    if (!gamuroid_save_state_runtime_is_ready()) {
        NSLog(@"[saveStateAsyncControlled] Skip: libretro is not running, core is not running, or app is shutting down");
        return NO;
    }

    if (LibretroSaveStateInFlight) {
        NSLog(@"[saveStateAsyncControlled] Skip: previous save task still in progress");
        return NO;
    }

    LibretroSaveStateInFlight = true;

    NSString *statePath = gamuroid_new_temp_state_path();
    NSString *corePathSnapshot = [self.hostCorePath copy];
#ifdef DEBUG
    CFAbsoluteTime saveStartTime = CFAbsoluteTimeGetCurrent();
#endif
    __block BOOL completed = NO;

#ifdef DEBUG
    NSLog(@"[PERF][SAVE_STATE] asyncControlled begin path=%@ corePath=%@ main=%s",
          statePath,
          corePathSnapshot ?: @"<nil>",
          [NSThread isMainThread] ? "YES" : "NO");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!completed) {
            NSLog(@"[PERF][SAVE_STATE] asyncControlled stillWaiting elapsedMs=%.1f corePath=%@",
                  (CFAbsoluteTimeGetCurrent() - saveStartTime) * 1000.0,
                  corePathSnapshot ?: @"<nil>");
        }
    });
#endif

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!gamuroid_save_state_runtime_is_ready()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completed = YES;
                LibretroSaveStateInFlight = false;
#ifdef DEBUG
                NSLog(@"[PERF][SAVE_STATE] asyncControlled aborted reason=runtime-not-ready corePath=%@",
                      corePathSnapshot ?: @"<nil>");
#endif
                completion(nil);
            });
            return;
        }

#ifdef DEBUG
        CFAbsoluteTime submitStartTime = CFAbsoluteTimeGetCurrent();
#endif
        BOOL saveSubmitted = content_save_state(statePath.UTF8String, true);
#ifdef DEBUG
        CFAbsoluteTime submitElapsedMs = (CFAbsoluteTimeGetCurrent() - submitStartTime) * 1000.0;
        NSLog(@"[PERF][SAVE_STATE] asyncControlled content_save_state submitted=%s elapsedMs=%.1f workerMain=%s corePath=%@",
              saveSubmitted ? "YES" : "NO",
              submitElapsedMs,
              [NSThread isMainThread] ? "YES" : "NO",
              corePathSnapshot ?: @"<nil>");
#endif

        if (!saveSubmitted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completed = YES;
                LibretroSaveStateInFlight = false;
                NSLog(@"[SAVE_STATE] FAILED: asyncControlled content_save_state returned false for path=%@", statePath);
                completion(nil);
            });
            return;
        }

#ifdef DEBUG
        CFAbsoluteTime waitStartTime = CFAbsoluteTimeGetCurrent();
#endif
        content_wait_for_save_state_task();
#ifdef DEBUG
        CFAbsoluteTime waitElapsedMs = (CFAbsoluteTimeGetCurrent() - waitStartTime) * 1000.0;
#endif

        dispatch_async(dispatch_get_main_queue(), ^{
            completed = YES;
            LibretroSaveStateInFlight = false;
            BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:statePath];
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:statePath error:nil];
            unsigned long long fileSize = [attrs[NSFileSize] unsignedLongLongValue];
            NSLog(@"[SAVE_STATE] asyncControlled SUCCESS path=%@ exists=%s size=%llu", statePath, fileExists ? "YES" : "NO", fileSize);
#ifdef DEBUG
            NSLog(@"[PERF][SAVE_STATE] asyncControlled waitTask elapsedMs=%.1f totalMs=%.1f fileExists=%s fileSize=%llu",
                  waitElapsedMs,
                  (CFAbsoluteTimeGetCurrent() - saveStartTime) * 1000.0,
                  fileExists ? "YES" : "NO",
                  fileSize);
#endif
            completion((fileExists && fileSize > 0) ? statePath : nil);
        });
    });

    return YES;
}


/* Called by -stop after main_exit() (2026-10-28). Restores the fresh-process value of frontend
 * state that main_exit() leaves set:
 * - g_custom_fastforward_ratio: runloop_get_fastforward_ratio() prefers it over every other ratio
 *   and -resume re-applies it;
 * - RUNLOOP_FLAG_FASTMOTION and AUDIO_FLAG_MUTED from -fastForward:. Neither is in the
 *   RARCH_CTL_STATE_FREE mask nor cleared by driver_uninit(). INP_FLAG_NONBLOCKING is already
 *   cleared by main_exit() (retroarch_deinit_drivers), so it is not touched here;
 * - needToLoadStatePath from -reloadByKeepState: while paused: -resume would load that state into
 *   the next session's game.
 * needToLoadStateDelay is left as is: it is configuration that GamuroidPlayScreen sets once per
 * controller (loadConfig) and its in-controller launch retries reuse. */
static void reset_libretro_session_frontend_state(void)
{
    runloop_state_t *runloop_st    = runloop_state_get_ptr();
    audio_driver_state_t *audio_st = audio_state_get_ptr();
    BOOL wasFastmotion             = (runloop_st->flags & RUNLOOP_FLAG_FASTMOTION) != 0;
    BOOL wasMuted                  = (audio_st->flags & AUDIO_FLAG_MUTED) != 0;
    if (g_custom_fastforward_ratio != 0.0f || wasFastmotion || wasMuted || needToLoadStatePath != nil) {
        NSLog(@"[DC_TRACE] stop — reset session frontend state ffRatio=%.2f fastmotion=%d muted=%d pendingLoadState=%d",
              g_custom_fastforward_ratio, wasFastmotion ? 1 : 0, wasMuted ? 1 : 0,
              needToLoadStatePath != nil ? 1 : 0);
    }
    g_custom_fastforward_ratio = 0.0f;
    runloop_st->flags         &= ~RUNLOOP_FLAG_FASTMOTION;
    audio_st->flags           &= ~AUDIO_FLAG_MUTED;
    needToLoadStatePath        = nil;
}

#pragma mark - Gamuroid embedded host

/* Nullability is spelled out in apple_platform.h; the file-local helpers below are
 * unannotated like the rest of this upstream file. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"

/* Session API used by the GamuroidRetroHost bridge. Every method runs on
 * the main thread; completions are delivered on the main queue. */

/* A session is initialized and no stop is in progress. */
static BOOL gamuroid_host_is_live(void)
{
   return LibretroInitial && !gamuroid_host_is_stopping();
}

static BOOL gamuroid_host_frame_driver_installed(void)
{
   return iterate_observer != NULL && CFRunLoopObserverIsValid(iterate_observer);
}

/* Runs block on main after delay seconds if the same session is still live. */
static void gamuroid_host_after(double delay, void (^block)(void))
{
   unsigned session = gamuroid_host_session_id;
   dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
         dispatch_get_main_queue(), ^{
      if (!gamuroid_host_is_live() || session != gamuroid_host_session_id)
         return;
      block();
   });
}

/* Category used while a game plays: Ambient respects the silent switch. */
static void gamuroid_host_set_playback_category(BOOL respectSilentSwitch)
{
   NSError *error = nil;
   AVAudioSessionCategoryOptions options = AVAudioSessionCategoryOptionMixWithOthers
      | AVAudioSessionCategoryOptionAllowBluetoothA2DP
      | AVAudioSessionCategoryOptionAllowAirPlay;
   [[AVAudioSession sharedInstance]
      setCategory:respectSilentSwitch ? AVAudioSessionCategoryAmbient : AVAudioSessionCategoryPlayback
      withOptions:options
            error:&error];
   if (error)
      NSLog(@"[LibretroHost] audio session category failed: %@", error.localizedDescription);
}

/* ---- key = "value" files (core options, retroarch.cfg) ---- */

static NSString *gamuroid_cfg_line_key(NSString *line)
{
   NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
   if (trimmed.length == 0 || [trimmed hasPrefix:@"#"])
      return nil;
   NSRange equals = [trimmed rangeOfString:@"="];
   if (equals.location == NSNotFound)
      return nil;
   NSString *key = [[trimmed substringToIndex:equals.location]
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
   return key.length > 0 ? key : nil;
}

/* The quoted value of a line, or nil when the line has no "..." value. */
static NSString *gamuroid_cfg_line_value(NSString *line)
{
   NSRange equals = [line rangeOfString:@"="];
   if (equals.location == NSNotFound)
      return nil;
   NSString *rest = [[line substringFromIndex:equals.location + 1]
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
   if (rest.length < 2 || ![rest hasPrefix:@"\""])
      return nil;
   NSRange closing = [rest rangeOfString:@"\"" options:0 range:NSMakeRange(1, rest.length - 1)];
   if (closing.location == NSNotFound)
      return nil;
   return [rest substringWithRange:NSMakeRange(1, closing.location - 1)];
}

static NSString *gamuroid_cfg_format_line(NSString *key, NSString *value)
{
   return [NSString stringWithFormat:@"%@ = \"%@\"", key, value];
}

/* Lines of the file without the final empty element, or nil when unreadable. */
static NSMutableArray<NSString *> *gamuroid_cfg_read_lines(NSString *path)
{
   NSError *error = nil;
   NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
   if (!text)
      return nil;
   NSMutableArray<NSString *> *lines = [[text componentsSeparatedByString:@"\n"] mutableCopy];
   if (lines.count > 0 && lines.lastObject.length == 0)
      [lines removeLastObject];
   return lines;
}

static BOOL gamuroid_cfg_write_lines(NSArray<NSString *> *lines, NSString *path)
{
   NSError *error = nil;
   NSString *directory = path.stringByDeletingLastPathComponent;
   if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
         withIntermediateDirectories:YES attributes:nil error:&error])
   {
      NSLog(@"[LibretroHost] cannot create %@: %@", directory, error.localizedDescription);
      return NO;
   }
   NSString *text = [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
   if (![text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error])
   {
      NSLog(@"[LibretroHost] cannot write %@: %@", path, error.localizedDescription);
      return NO;
   }
   return YES;
}

static NSString *gamuroid_cfg_value_in_lines(NSArray<NSString *> *lines, NSString *key)
{
   for (NSString *line in lines)
   {
      if (![gamuroid_cfg_line_key(line) isEqualToString:key])
         continue;
      NSString *value = gamuroid_cfg_line_value(line);
      if (value)
         return value;
   }
   return nil;
}

/* Sets each key's first quoted line to its value. Keys without such a line are
 * appended when appendMissing is YES, else reported through missingKey.
 * Returns YES when the lines changed. */
static BOOL gamuroid_cfg_apply(NSMutableArray<NSString *> *lines,
      NSDictionary<NSString *, NSString *> *values, BOOL appendMissing, BOOL *missingKey)
{
   BOOL changed = NO;
   NSMutableSet<NSString *> *found = [NSMutableSet set];

   for (NSUInteger i = 0; i < lines.count; i++)
   {
      NSString *key = gamuroid_cfg_line_key(lines[i]);
      NSString *value = key ? values[key] : nil;
      if (!value || [found containsObject:key] || !gamuroid_cfg_line_value(lines[i]))
         continue;
      [found addObject:key];
      if (![gamuroid_cfg_line_value(lines[i]) isEqualToString:value])
      {
         lines[i] = gamuroid_cfg_format_line(key, value);
         changed  = YES;
      }
   }

   for (NSString *key in [values.allKeys sortedArrayUsingSelector:@selector(compare:)])
   {
      if ([found containsObject:key])
         continue;
      if (appendMissing)
      {
         [lines addObject:gamuroid_cfg_format_line(key, values[key])];
         changed = YES;
      }
      else if (missingKey)
         *missingKey = YES;
   }
   return changed;
}

static NSString *gamuroid_host_frontend_config_path(void)
{
   NSString *library = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory,
         NSUserDomainMask, YES) firstObject];
   return [library stringByAppendingPathComponent:@"Libretro/config/retroarch.cfg"];
}

/* Newest *.ini (by creation date) in directory, without extension; nil if none. */
static NSString *gamuroid_newest_ini_name(NSString *directory)
{
   NSURL *best     = nil;
   NSDate *bestDate = nil;
   NSArray<NSURL *> *items = [[NSFileManager defaultManager]
      contentsOfDirectoryAtURL:[NSURL fileURLWithPath:directory]
      includingPropertiesForKeys:@[NSURLCreationDateKey]
      options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
   for (NSURL *url in items)
   {
      NSDate *created = nil;
      if ([url.pathExtension caseInsensitiveCompare:@"ini"] != NSOrderedSame)
         continue;
      [url getResourceValue:&created forKey:NSURLCreationDateKey error:nil];
      if (!best || (created && (!bestDate || [created compare:bestDate] == NSOrderedDescending)))
      {
         best     = url;
         bestDate = created;
      }
   }
   return best.lastPathComponent.stringByDeletingPathExtension;
}

/* Bottom-up, blue-first 24-bit rows from read_viewport -> upright opaque image. */
static UIImage *gamuroid_image_from_viewport_pixels(const uint8_t *bgr, size_t width, size_t height)
{
   size_t stride       = width * 4;
   NSMutableData *rgba = [NSMutableData dataWithLength:stride * height];
   uint8_t *out        = (uint8_t *)rgba.mutableBytes;
   CGColorSpaceRef space;
   CGDataProviderRef provider;
   CGImageRef cgImage;
   UIImage *image;

   if (!out)
      return nil;
   for (size_t row = 0; row < height; row++)
   {
      const uint8_t *src = bgr + (height - 1 - row) * width * 3;
      uint8_t *dst       = out + row * stride;
      for (size_t col = 0; col < width; col++, src += 3, dst += 4)
      {
         dst[0] = src[2];
         dst[1] = src[1];
         dst[2] = src[0];
         dst[3] = 0xFF;
      }
   }

   space    = CGColorSpaceCreateDeviceRGB();
   provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)rgba);
   cgImage  = CGImageCreate(width, height, 8, 32, stride, space,
         kCGBitmapByteOrderDefault | kCGImageAlphaNoneSkipLast,
         provider, NULL, false, kCGRenderingIntentDefault);
   CGDataProviderRelease(provider);
   CGColorSpaceRelease(space);
   if (!cgImage)
      return nil;
   image = [UIImage imageWithCGImage:cgImage scale:1.0 orientation:UIImageOrientationUp];
   CGImageRelease(cgImage);
   return image;
}

#pragma mark Session lifecycle

- (void)hostBeginSessionWithSaveDir:(NSString *)saveFolderOverride
{
   char program[]        = "retroarch";
   char *argv[]          = { program, NULL };
   runloop_state_t *runloop_st;
   uint32_t staleFlags;
   NSError *error        = nil;

   if (LibretroInitial)
   {
      NSLog(@"[DC_TRACE] start ignored: a libretro session is already running");
      return;
   }
   if (gamuroid_host_is_stopping())
   {
      /* No session but a stop flag: an earlier stop was interrupted. */
      NSLog(@"[DC_TRACE] start — clearing a stale stopping flag");
      gamuroid_set_host_stopping(false);
   }

   /* Loading a core must not interrupt other apps' audio. */
   if (![[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient error:&error])
      NSLog(@"[LibretroHost] Ambient category failed: %@", error.localizedDescription);

   LibretroInitial           = true;
   LibretroSaveStateInFlight = false;
   gamuroid_set_host_stopping(false);
   gamuroid_host_session_id++;
#ifdef DEBUG
   g_audio_lifecycle_libretro_session_live++;
   printf("[AUDIO_LIFECYCLE] core=libretro kind=session event=begin live=%d\n",
         g_audio_lifecycle_libretro_session_live);
   fflush(stdout);
#endif

   apple_platform = self;
   [CocoaView get].view.frame = [UIScreen mainScreen].bounds;

   [[NSNotificationCenter defaultCenter] addObserver:self
                                            selector:@selector(handleAudioSessionInterruption:)
                                                name:AVAudioSessionInterruptionNotification
                                              object:[AVAudioSession sharedInstance]];

   /* Audio starts about one second in, only if this session is still running. */
   gamuroid_host_after(1.0, ^{
      command_event(CMD_EVENT_AUDIO_START, NULL);
   });

   /* The next RetroArch init must run the joypad driver init again. */
   gamupad_host_reset();

   gamuroid_set_custom_save_dir(saveFolderOverride.length > 0 ? saveFolderOverride.UTF8String : NULL);

   /* Without the menu these flags survive main_exit(); a stale one ends every
    * later session at once. */
   runloop_st = runloop_state_get_ptr();
   staleFlags = runloop_st->flags
      & (RUNLOOP_FLAG_SHUTDOWN_INITIATED | RUNLOOP_FLAG_CORE_SHUTDOWN_INITIATED);
   if (staleFlags)
   {
      NSLog(@"[DC_TRACE] cleared stale%s%s",
            (staleFlags & RUNLOOP_FLAG_SHUTDOWN_INITIATED)      ? " SHUTDOWN_INITIATED"      : "",
            (staleFlags & RUNLOOP_FLAG_CORE_SHUTDOWN_INITIATED) ? " CORE_SHUTDOWN_INITIATED" : "");
      runloop_st->flags &= ~staleFlags;
   }

   /* setViewType: ignores an unchanged type, so drop the old render view: the
    * context driver then creates a new one for this session inside rarch_main. */
   if (self.viewType != APPLE_VIEW_TYPE_NONE)
      self.viewType = APPLE_VIEW_TYPE_NONE;

   if (rarch_main(1, argv, NULL) != 0)
   {
      /* RetroArch's error path already deinitialized what it had started. */
      NSLog(@"[LibretroHost] rarch_main failed; session not started");
      [[NSNotificationCenter defaultCenter] removeObserver:self
                                                      name:AVAudioSessionInterruptionNotification
                                                    object:[AVAudioSession sharedInstance]];
      mark_libretro_stopped();
      return;
   }

   rarch_start_draw_observer();
}

- (void)hostPauseSession
{
   if (!LibretroInitial)
      return;
   command_event(CMD_EVENT_PAUSE, NULL);
   rarch_stop_draw_observer();
}

- (void)hostResumeSession
{
   runloop_state_t *runloop_st;
   float ratio;
   int pausedBefore;
   int pausedAfter;

   if (!LibretroInitial)
      return;

   ratio      = g_custom_fastforward_ratio;
   runloop_st = runloop_state_get_ptr();
   rarch_start_draw_observer();

   pausedBefore = (runloop_st->flags & RUNLOOP_FLAG_PAUSED) ? 1 : 0;
   command_event(CMD_EVENT_RESUME, NULL);
   pausedAfter  = (runloop_st->flags & RUNLOOP_FLAG_PAUSED) ? 1 : 0;
   NSLog(@"[DC_TRACE] resume — paused before=%d after=%d", pausedBefore, pausedAfter);

   if (needToLoadStatePath)
   {
      NSString *statePath = needToLoadStatePath;
      needToLoadStatePath = nil;
      [self gamuroid_reloadContent];
      [self gamuroid_reapplyFastForward:ratio];
      [self gamuroid_loadStateAfterReloadDelay:statePath];
   }
   else
      [self gamuroid_reapplyFastForward:ratio];
}

- (void)hostEndSession
{
   NSError *error = nil;

   if (!LibretroInitial)
      return;

   LibretroInitial = false;
   gamuroid_set_host_stopping(true);

   /* No sound may linger while a slow core tears down. */
   audio_driver_stop();
   /* The SRAM autosave thread reads core memory: join it before the core goes. */
   autosave_deinit();

   /* Never CMD_EVENT_CLOSE_CONTENT: without the menu it becomes QUIT. */
   command_event(CMD_EVENT_RUMBLE_STOP, NULL);
#ifdef HAVE_MICROPHONE
   command_event(CMD_EVENT_MICROPHONE_STOP, NULL);
#endif
   command_event(CMD_EVENT_UNLOAD_CORE, NULL);

   rarch_stop_draw_observer();
   main_exit(NULL);

   reset_libretro_session_frontend_state();
   gamuroid_set_host_stopping(false);

   self.hostContentPath = nil;
   self.hostCorePath = nil;
   [[NSNotificationCenter defaultCenter] removeObserver:self
                                                   name:AVAudioSessionInterruptionNotification
                                                 object:[AVAudioSession sharedInstance]];
   if (![[AVAudioSession sharedInstance] setActive:NO
                                       withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                             error:&error])
      NSLog(@"[LibretroHost] audio session deactivation failed: %@", error.localizedDescription);
#ifdef DEBUG
   g_audio_lifecycle_libretro_session_live--;
   printf("[AUDIO_LIFECYCLE] core=libretro kind=session event=end live=%d\n",
         g_audio_lifecycle_libretro_session_live);
   fflush(stdout);
#endif
}

#pragma mark Content

/* Settings applied right before every content load (the cfg is not re-read later). */
- (void)gamuroid_prepareContentLoad
{
   settings_t *settings        = config_get_ptr();
   runloop_state_t *runloop_st = runloop_state_get_ptr();

   configuration_set_bool(settings, settings->bools.video_font_enable, false);
   configuration_set_bool(settings, settings->bools.audio_respect_silent_mode, RespectSilentMode ? true : false);
   gamuroid_set_custom_save_ext(gamuroid_host_save_ext.length > 0 ? gamuroid_host_save_ext.UTF8String : NULL);
   gamuroid_host_set_playback_category(RespectSilentMode);
   runloop_st->name.label[0] = '\0';
}

static BOOL gamuroid_host_dummy_core_loaded(void)
{
   return runloop_state_get_ptr()->current_core_type == CORE_TYPE_DUMMY;
}

- (BOOL)hostOpenContent:(NSString *)contentLocation
               withCore:(NSString *)corePath
             completion:(void (^)(NSDictionary *))completion
{
   content_ctx_info_t info = {0};
   runloop_state_t *runloop_st;
   bool loaded;

   if (!LibretroInitial)
   {
      if (completion)
         completion(nil);
      return NO;
   }

   [self gamuroid_prepareContentLoad];

   loaded = task_push_load_new_core(corePath.UTF8String, NULL, &info, CORE_TYPE_PLAIN, NULL, NULL);
   if (loaded)
      loaded = task_push_load_content_with_core(contentLocation.UTF8String, &info, CORE_TYPE_PLAIN, NULL, NULL);
   /* RetroArch can fall back to the dummy core silently: a bad ROM must fail. */
   if (!loaded || gamuroid_host_dummy_core_loaded())
   {
      NSLog(@"[LibretroHost] content load failed core=%@ content=%@",
            corePath.lastPathComponent, contentLocation.lastPathComponent);
      if (completion)
         completion(nil);
      return NO;
   }

   self.hostContentPath = contentLocation;
   self.hostCorePath = corePath;

   runloop_st = runloop_state_get_ptr();
   if (completion && string_is_equal(runloop_st->system.info.library_name, "PPSSPP"))
   {
      /* Legacy libretro PPSSPP: report the game code from the newest cheat file. */
      const char *saveDir  = dir_get_ptr(RARCH_DIR_SAVEFILE);
      NSString *cheats     = [[NSString stringWithUTF8String:saveDir ? saveDir : ""]
         stringByAppendingPathComponent:@"PSP/Cheats"];
      core_options_flush();
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
         NSString *gameCode = gamuroid_newest_ini_name(cheats);
         dispatch_async(dispatch_get_main_queue(), ^{
            completion(gameCode ? @{ @"pspDiscSerial": gameCode } : nil);
         });
      });
      return YES;
   }

   if (completion)
      completion(nil);
   return YES;
}

- (BOOL)hostOpenSubsystem:(NSString *)subsystemIdent
                    files:(NSArray<NSString *> *)romPaths
                 withCore:(NSString *)corePath
               completion:(void (^)(NSDictionary *))completion
{
   content_ctx_info_t info = {0};
   bool loaded;

   if (!LibretroInitial)
   {
      if (completion)
         completion(nil);
      return NO;
   }

   [self gamuroid_prepareContentLoad];

   /* The core fills the subsystem table while it loads, so load it first. */
   if (!task_push_load_new_core(corePath.UTF8String, NULL, &info, CORE_TYPE_PLAIN, NULL, NULL))
   {
      NSLog(@"[SLOT2] core load failed core=%@", corePath.lastPathComponent);
      self.hostContentPath = nil;
      self.hostCorePath = corePath;
      if (completion)
         completion(nil);
      return NO;
   }

   content_clear_subsystem();
   if (!content_set_subsystem_by_name(subsystemIdent.UTF8String))
   {
      NSLog(@"[SLOT2] core has no subsystem '%@'", subsystemIdent);
      self.hostContentPath = nil;
      self.hostCorePath = corePath;
      if (completion)
         completion(nil);
      return NO;
   }
   for (NSString *contentFilePath in romPaths)
      content_add_subsystem(contentFilePath.UTF8String);

   loaded = task_push_load_subsystem_with_core(NULL, &info, CORE_TYPE_PLAIN, NULL, NULL);
   loaded = loaded
      && !string_is_empty(path_get(RARCH_PATH_SUBSYSTEM))
      && !gamuroid_host_dummy_core_loaded();
   NSLog(@"[SLOT2] subsystem '%@' with %lu file(s): %s", subsystemIdent,
         (unsigned long)romPaths.count, loaded ? "loaded" : "failed");

   self.hostContentPath = loaded ? romPaths.firstObject : nil;
   self.hostCorePath = corePath;
   if (completion)
      completion(nil);
   return loaded ? YES : NO;
}

- (void)hostStartCoreWithoutContent:(NSString *)corePath {
    if (!LibretroInitial) { return; }
    content_ctx_info_t content_info = {0};
    if (!task_push_load_new_core(corePath.UTF8String, NULL, &content_info,
                                CORE_TYPE_PLAIN, NULL, NULL)) {
        return;
    }
    task_push_start_current_core(&content_info);
}

/* Loads the remembered game with the remembered core again. */
- (void)gamuroid_reloadContent
{
   if (!self.hostContentPath || !self.hostCorePath)
   {
      NSLog(@"[LibretroHost] reload skipped: no remembered game/core");
      return;
   }
   [self hostOpenContent:self.hostContentPath withCore:self.hostCorePath completion:nil];
}

- (void)gamuroid_reapplyFastForward:(float)ratio
{
   if (ratio <= 0.0f)
      return;
   gamuroid_host_after(0.1, ^{
      [self hostSetFastForwardRate:ratio];
   });
}

- (void)gamuroid_loadStateAfterReloadDelay:(NSString *)statePath
{
   if (gamuroid_host_reload_delay > 0.0)
      gamuroid_host_after(gamuroid_host_reload_delay, ^{
         [self hostRestoreStateAtPath:statePath];
      });
   else
      [self hostRestoreStateAtPath:statePath];
}

- (void)hostRestartContent
{
   [self hostRestartContentKeepingState:NO];
}

- (void)hostRestartContentKeepingState:(BOOL)keepState
{
   float ratio = g_custom_fastforward_ratio;

   if (!LibretroInitial)
      return;

   if (!keepState)
   {
      [self gamuroid_reloadContent];
      [self gamuroid_reapplyFastForward:ratio];
      return;
   }

   if (![self hostSaveStateWithCompletion:^(NSString *statePath) {
         if (!statePath || !gamuroid_host_is_live())
            return;
         if (gamuroid_host_frame_driver_installed())
         {
            [self gamuroid_reloadContent];
            [self gamuroid_reapplyFastForward:ratio];
            [self gamuroid_loadStateAfterReloadDelay:statePath];
         }
         else
            needToLoadStatePath = statePath; /* paused: applied by -resume */
      }])
      NSLog(@"[LibretroHost] keep-state reload: state save was not accepted; nothing reloaded");
}

#pragma mark State

- (BOOL)hostSaveStateWithCompletion:(void (^)(NSString *))completion
{
    if (!completion) {
        return NO;
    }
    if (!gamuroid_save_state_runtime_is_ready()) {
        NSLog(@"[saveState] Skip: libretro is not running or is shutting down");
        return NO;
    }

    if (LibretroSaveStateInFlight) {
        NSLog(@"[saveState] Skip: previous save task still in progress");
        return NO;
    }

    LibretroSaveStateInFlight = true;

#ifdef DEBUG
    CFAbsoluteTime saveStartTime = CFAbsoluteTimeGetCurrent();
#endif
    NSString *statePath = gamuroid_new_temp_state_path();
    NSLog(@"[SAVE_STATE] calling content_save_state path=%@", statePath);
#ifdef DEBUG
    CFAbsoluteTime submitStartTime = CFAbsoluteTimeGetCurrent();
#endif
    BOOL saveSubmitted = content_save_state(statePath.UTF8String, true);
#ifdef DEBUG
    CFAbsoluteTime submitElapsedMs = (CFAbsoluteTimeGetCurrent() - submitStartTime) * 1000.0;
    NSLog(@"[PERF][SAVE_STATE] content_save_state submitted=%s elapsedMs=%.1f totalSubmitMs=%.1f main=%s",
          saveSubmitted ? "YES" : "NO",
          submitElapsedMs,
          (CFAbsoluteTimeGetCurrent() - saveStartTime) * 1000.0,
          [NSThread isMainThread] ? "YES" : "NO");
#endif
    if (saveSubmitted) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
#ifdef DEBUG
            CFAbsoluteTime waitStartTime = CFAbsoluteTimeGetCurrent();
#endif
            content_wait_for_save_state_task();
#ifdef DEBUG
            CFAbsoluteTime waitElapsedMs = (CFAbsoluteTimeGetCurrent() - waitStartTime) * 1000.0;
#endif
            dispatch_async(dispatch_get_main_queue(), ^{
                LibretroSaveStateInFlight = false;
                BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:statePath];
                NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:statePath error:nil];
                unsigned long long fileSize = [attrs[NSFileSize] unsignedLongLongValue];
                NSLog(@"[SAVE_STATE] SUCCESS path=%@ exists=%s size=%llu", statePath, fileExists ? "YES" : "NO", fileSize);
#ifdef DEBUG
                NSLog(@"[PERF][SAVE_STATE] waitTask elapsedMs=%.1f fileExists=%s fileSize=%llu",
                      waitElapsedMs,
                      fileExists ? "YES" : "NO",
                      fileSize);
#endif
                completion(statePath);
            });
        });
        return YES;
    }
    NSLog(@"[SAVE_STATE] FAILED: content_save_state returned false for path=%@", statePath);
    LibretroSaveStateInFlight = false;
    return NO;
}

- (BOOL)hostRestoreStateAtPath:(NSString *)path
{
   if (!LibretroInitial || path.length == 0)
      return NO;
   return content_load_state(path.UTF8String, false, false) ? YES : NO;
}

#pragma mark Frame, audio, speed

- (void)hostCaptureFrame:(void (^)(UIImage *))completion
{
   if (!completion)
      return;
   /* Runs on main, so the frame driver cannot step while the viewport is read. */
   dispatch_async(dispatch_get_main_queue(), ^{
      completion([self gamuroid_captureViewport]);
   });
}

- (UIImage *)gamuroid_captureViewport
{
   video_driver_state_t *video_st = video_state_get_ptr();
   runloop_state_t *runloop_st    = runloop_state_get_ptr();
   struct video_viewport viewport = {0};
   uint8_t *pixels;
   BOOL fastMotion;
   BOOL captured                  = NO;
   unsigned attempts;
   UIImage *image                 = nil;

   if (!gamuroid_host_is_live() || !video_st || !video_st->current_video
         || !video_st->current_video->read_viewport)
      return nil;
   if (!video_driver_get_viewport_info(&viewport) || viewport.width == 0 || viewport.height == 0)
      return nil;
   if (!(pixels = (uint8_t *)malloc((size_t)viewport.width * viewport.height * 3)))
      return nil;

   fastMotion = (runloop_st->flags & RUNLOOP_FLAG_FASTMOTION) != 0;
   attempts   = fastMotion ? 10 : 3;
   if (fastMotion)
      runloop_st->flags &= ~RUNLOOP_FLAG_FASTMOTION;
   for (unsigned i = 0; i < attempts && !captured; i++)
   {
      video_driver_cached_frame();
      captured = video_st->current_video->read_viewport(video_st->data, pixels, false);
   }
   if (fastMotion)
      runloop_st->flags |= RUNLOOP_FLAG_FASTMOTION;

   if (captured)
      image = gamuroid_image_from_viewport_pixels(pixels, viewport.width, viewport.height);
   else
      NSLog(@"[LibretroHost] snapshot: viewport read failed after %u attempt(s)", attempts);
   free(pixels);
   return image;
}

/* The argument means "audio enabled" (libretro_bridge_spec.md U1). */
- (void)hostSetAudioEnabled:(BOOL)audioEnabled
{
   audio_driver_state_t *audio_st = audio_state_get_ptr();
   if (audio_st)
      audio_st->mute_enable = audioEnabled ? false : true;
}

/* Sets or clears one flag bit in a flags word. */
#define GAMUROID_ASSIGN_FLAG(word, mask, enable) \
   do { if (enable) (word) |= (mask); else (word) &= ~(mask); } while (0)

/* The RetroArch singletons the fast-forward switch touches, fetched together. */
typedef struct
{
   settings_t *cfg;
   runloop_state_t *run;
   input_driver_state_t *in;
   audio_driver_state_t *aud;
   video_driver_state_t *vid;
} gamuroid_ff_state_t;

static bool gamuroid_ff_state_fetch(gamuroid_ff_state_t *out)
{
   out->vid = video_state_get_ptr();
   out->aud = audio_state_get_ptr();
   out->in  = input_state_get_ptr();
   out->run = runloop_state_get_ptr();
   out->cfg = config_get_ptr();
   return out->cfg && out->run && out->in && out->aud && out->vid;
}

- (void)hostSetFastForwardRate:(float)rate
{
   gamuroid_ff_state_t st;
   BOOL on;
   bool mute_setting;

   if (!gamuroid_ff_state_fetch(&st))
   {
      NSLog(@"[LibretroHost] fast forward ignored: RetroArch state not ready");
      return;
   }

   /* Rates up to 1 (0, 1, negative, NaN) mean normal speed. */
   on                         = rate > 1.0f;
   mute_setting               = st.cfg->bools.audio_fastforward_mute;
   g_custom_fastforward_ratio = on ? rate : 0.0f;

   GAMUROID_ASSIGN_FLAG(st.run->flags, RUNLOOP_FLAG_FASTMOTION, on);
   GAMUROID_ASSIGN_FLAG(st.in->flags, INP_FLAG_NONBLOCKING, on);
   /* Audio is muted only while fast-forwarding with the mute setting; leaving fast
    * forward unmutes only when that setting is on. */
   if (on || mute_setting)
      GAMUROID_ASSIGN_FLAG(st.aud->flags, AUDIO_FLAG_MUTED, on && mute_setting);
   if (!on)
      st.run->fastforward_after_frames = 1;

   driver_set_nonblock_state();

   if (!on && st.cfg->bools.frame_time_counter_reset_after_fastforwarding)
      st.vid->frame_time_count = 0;

   command_event(CMD_EVENT_SET_FRAME_LIMIT, NULL);
}

- (void)hostSetRumbleEnabled:(BOOL)enable
{
   bool flag = enable ? true : false;
   gamuroid_set_rumble_enabled(flag);
}

- (void)hostSetReloadDelay:(double)delay
{
   gamuroid_host_reload_delay = delay;
}

- (void)hostSetSaveExtension:(NSString *)ext
{
   NSString *copy = [ext copy];
   gamuroid_host_save_ext = copy;
}

- (void)hostSetSilentSwitchRespected:(BOOL)respect
{
   RespectSilentMode = respect;
}

#pragma mark Input

/* Shared by the button entry points: the pressed state is the only difference. */
static void gamuroid_host_pad_button(unsigned player, unsigned button, bool pressed)
{
   gamupad_host_set_button(player, button, pressed);
}

- (void)hostButtonUp:(unsigned)button forPlayer:(unsigned)playerIndex
{
   gamuroid_host_pad_button(playerIndex, button, false);
}

- (void)hostButtonDown:(unsigned)button forPlayer:(unsigned)playerIndex
{
   gamuroid_host_pad_button(playerIndex, button, true);
}

- (void)hostSetStickLeft:(BOOL)isLeft x:(CGFloat)x y:(CGFloat)y forPlayer:(unsigned)playerIndex
{
   unsigned stick = RETRO_DEVICE_INDEX_ANALOG_RIGHT;
   if (isLeft)
      stick = RETRO_DEVICE_INDEX_ANALOG_LEFT;
   gamupad_host_set_stick(playerIndex, stick, (float)x, (float)y);
}

- (void)hostHandleTouchEvent:(UIEvent *)event
{
   NSSet<UITouch *> *touches;
   if (@available(iOS 13.4, tvOS 13.4, *))
   {
      if (event.type == UIEventTypeHover)
         return;
   }
   touches = event.allTouches;
   if (touches.count)
      handle_touch_event(touches.allObjects);
}

#if !TARGET_OS_TV
static cocoa_input_data_t *gamuroid_host_apple_input(void)
{
   return (cocoa_input_data_t *)input_state_get_ptr()->current_data;
}
#endif

/* One pointer at (x, y) points, in pixels. */
- (void)hostPointerDownAtX:(CGFloat)x y:(CGFloat)y
{
#if !TARGET_OS_TV
   cocoa_input_data_t *apple = gamuroid_host_apple_input();
   float scale               = cocoa_screen_get_native_scale();
   if (!apple)
      return;
   apple->touch_count         = 1;
   apple->touches[0].screen_y = (int16_t)(y * scale);
   apple->touches[0].screen_x = (int16_t)(x * scale);
#endif
}

- (void)hostPointerUp
{
#if !TARGET_OS_TV
   cocoa_input_data_t *apple = gamuroid_host_apple_input();
   if (apple)
      apple->touch_count = 0;
#endif
}

- (BOOL)hostMotionSensorRequestedForPort:(unsigned)port
{
   bool requested = cocoa_input_motion_requested(port);
   return requested ? YES : NO;
}

- (void)hostSetPSXAnalogMode:(BOOL)isAnalog
{
   /* 517 = RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_ANALOG, 1) (DualShock), 1 = joypad. */
   unsigned device             = isAnalog ? 517 : 1;
   runloop_state_t *runloop_st = runloop_state_get_ptr();
   for (unsigned port = 0; port < 8; port++)
   {
      retro_ctx_controller_info_t pad;
      pad.port   = port;
      pad.device = device;
      if (runloop_st->current_core.retro_set_controller_port_device)
         core_set_controller_port_device(&pad);
      input_config_set_device(port, device);
   }
}

#pragma mark Configuration files

- (NSString *)gamuroid_coreOptionsPath:(NSString *)coreName
{
   if (self.hostWorkspaceRoot.length == 0 || coreName.length == 0)
      return nil;
   return [[[self.hostWorkspaceRoot stringByAppendingPathComponent:@"config"]
      stringByAppendingPathComponent:coreName]
      stringByAppendingPathComponent:[coreName stringByAppendingPathExtension:@"opt"]];
}

- (void)gamuroid_updateCoreOptions:(NSString *)coreName
                            values:(NSDictionary<NSString *, NSString *> *)values
                     appendMissing:(BOOL)appendMissing
                            reload:(BOOL)reload
{
   NSString *path = [self gamuroid_coreOptionsPath:coreName];
   NSMutableArray<NSString *> *lines;
   BOOL changed    = NO;
   BOOL missingKey = NO;

   if (!path)
   {
      NSLog(@"[LibretroHost] core options not updated: no workspace or core name (%@)", coreName);
      return;
   }

   if (!(lines = gamuroid_cfg_read_lines(path)))
   {
      core_options_flush(); /* lets RetroArch write the file for the running core */
      lines = gamuroid_cfg_read_lines(path);
   }
   if (!lines)
   {
      lines   = [NSMutableArray array];
      gamuroid_cfg_apply(lines, values, YES, NULL);
      changed = gamuroid_cfg_write_lines(lines, path);
   }
   else if ((changed = gamuroid_cfg_apply(lines, values, appendMissing, &missingKey)))
      gamuroid_cfg_write_lines(lines, path);

   /* Parity (libretro_bridge_spec.md U9): the single-key form reloads even when
    * the key was missing from an existing file. */
   if (reload && (changed || missingKey))
      [self hostRestartContentKeepingState:YES];
}

- (void)hostSetOption:(NSString *)key to:(NSString *)value forCore:(NSString *)coreName reload:(BOOL)reload
{
   if (key.length == 0 || !value)
   {
      NSLog(@"[LibretroHost] core option update ignored: empty key or value");
      return;
   }
   [self gamuroid_updateCoreOptions:coreName values:@{ key: value } appendMissing:NO reload:reload];
}

- (void)hostSetOptions:(NSDictionary<NSString *, NSString *> *)configs forCore:(NSString *)coreName reload:(BOOL)reload
{
   if (configs.count == 0)
      return;
   [self gamuroid_updateCoreOptions:coreName values:configs appendMissing:YES reload:reload];
}

- (void)hostApplyLiveOptions:(NSDictionary<NSString *, NSString *> *)configs flush:(BOOL)flush
{
   core_option_manager_t *options = runloop_state_get_ptr()->core_options;
   if (!options)
      return;
   for (NSString *key in configs)
   {
      size_t optionIndex;
      size_t valueIndex;
      if (!core_option_manager_get_idx(options, key.UTF8String, &optionIndex))
         continue; /* not an option of this core */
      if (!core_option_manager_get_val_idx(options, optionIndex, configs[key].UTF8String, &valueIndex))
         continue; /* value not offered by the option */
      core_option_manager_set_val(options, optionIndex, valueIndex, false);
      if (flush)
         core_options_flush();
   }
}

- (void)hostSetFrontendSettings:(NSDictionary<NSString *, NSString *> *)configs
{
   NSString *path = gamuroid_host_frontend_config_path();
   NSMutableArray<NSString *> *lines;
   if (configs.count == 0)
      return;
   lines = gamuroid_cfg_read_lines(path) ?: [NSMutableArray array];
   if (gamuroid_cfg_apply(lines, configs, YES, NULL))
      gamuroid_cfg_write_lines(lines, path);
}

- (void)hostSetFrontendSetting:(NSString *)key to:(NSString *)value
{
   if (key.length == 0 || !value)
   {
      NSLog(@"[LibretroHost] retroarch.cfg update ignored: empty key or value");
      return;
   }
   [self hostSetFrontendSettings:@{ key: value }];
}

- (NSString *)hostOptionValue:(NSString *)key forCore:(NSString *)coreName
{
   NSString *path = [self gamuroid_coreOptionsPath:coreName];
   return path ? gamuroid_cfg_value_in_lines(gamuroid_cfg_read_lines(path), key) : nil;
}

- (NSString *)hostFrontendSettingValue:(NSString *)key
{
   return gamuroid_cfg_value_in_lines(gamuroid_cfg_read_lines(gamuroid_host_frontend_config_path()), key);
}

#pragma mark Cheats and discs

- (void)hostAddCheat:(NSString *)code slot:(unsigned)index enabled:(BOOL)enable
{
   runloop_state_t *runloop_st = runloop_state_get_ptr();
   if (runloop_st->current_core.retro_cheat_set)
      runloop_st->current_core.retro_cheat_set(index, enable ? true : false, code.UTF8String);
   else
      NSLog(@"[LibretroHost] cheat ignored: the core has no cheat interface");
}

- (void)hostClearCheats
{
   runloop_state_t *runloop_st = runloop_state_get_ptr();
   if (runloop_st->current_core.retro_cheat_reset)
      runloop_st->current_core.retro_cheat_reset();
}

- (void)hostSelectDisc:(unsigned)index delayed:(BOOL)delay
{
   runloop_state_t *runloop_st;
   BOOL wasPaused;

   if (!gamuroid_host_is_live())
      return;

   command_event(CMD_EVENT_DISK_EJECT_TOGGLE, NULL); /* open the tray */
   if (!delay)
   {
      command_event(CMD_EVENT_DISK_INDEX, &index);
      command_event(CMD_EVENT_DISK_EJECT_TOGGLE, NULL); /* close it */
      return;
   }

   /* PS1 needs frames to run with the tray open before the new disc goes in. */
   runloop_st = runloop_state_get_ptr();
   wasPaused  = (runloop_st->flags & RUNLOOP_FLAG_PAUSED) != 0;
   if (wasPaused)
   {
      rarch_start_draw_observer();
      command_event(CMD_EVENT_UNPAUSE, NULL);
   }
   gamuroid_host_after(0.5, ^{
      unsigned selected = index;
      command_event(CMD_EVENT_DISK_INDEX, &selected);
      command_event(CMD_EVENT_DISK_EJECT_TOGGLE, NULL);
      if (wasPaused)
         [self hostPauseSession];
   });
}

- (NSUInteger)hostSelectedDiscIndex
{
   disk_control_interface_t *disks = &runloop_state_get_ptr()->system.disk_control;
   return disks->cb.get_image_index ? disks->cb.get_image_index() : 0;
}

- (NSUInteger)hostDiscCount
{
   disk_control_interface_t *disks = &runloop_state_get_ptr()->system.disk_control;
   return disks->cb.get_num_images ? disks->cb.get_num_images() : 0;
}

#pragma clang diagnostic pop

@end

ui_companion_driver_t ui_companion_cocoatouch = {
   NULL, /* init */
   NULL, /* deinit */
   NULL, /* toggle */
   ui_companion_cocoatouch_event_command,
   NULL, /* notify_refresh */
   NULL, /* msg_queue_push */
   NULL, /* render_messagebox */
   NULL, /* get_main_window */
   NULL, /* log_msg */
   NULL, /* is_active */
   ui_companion_cocoatouch_get_app_icons,
   ui_companion_cocoatouch_set_app_icon,
   ui_companion_cocoatouch_get_app_icon_texture,
   NULL, /* browser_window */
   NULL, /* msg_window */
   NULL, /* window */
   NULL, /* application */
   "cocoatouch",
};
