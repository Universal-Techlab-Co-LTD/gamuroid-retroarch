// GamuroidRetroHost.m — Gamuroid.
//
// The bridge owns no emulation logic. It forwards app calls to the RetroArch host object (RetroArch_iOS in
// ui_cocoatouch.m), registers the RetroArch/core callbacks the app needs, turns them into notifications on
// the main queue, keeps the gamuroid_screen_layout and WFC DNS answers for melonDS DS and Azahar, and connects
// the Azahar software-keyboard ABI version 2 and the melonDS DS online-state exports to Swift.
//
// Threading: every public method runs on the main thread. RetroArch callbacks may arrive on any thread; they
// copy what they need before returning and hand the result to the main queue asynchronously.

#import "cocoa/GamuroidRetroHost.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <QuartzCore/QuartzCore.h>

#include "../../audio/audio_driver.h"
#include "../../configuration.h"
#include "../../core_option_manager.h"
#include "../../frontend/frontend.h"
#include "../../input/drivers/cocoa_input.h"
#include "../../input/drivers_keyboard/keyboard_event_apple.h"
#include "../../retroarch.h"
#include "../../runloop.h"
#include "../../tasks/task_content.h"
#include "../../verbosity.h"
#include "../ui_companion_driver.h"

#ifdef HAVE_MENU
#include "../../menu/menu_setting.h"
#endif

#include "cocoa/cocoa_common.h"
#include "cocoa/apple_platform.h"
#include "cocoa/gamuroid_embedded_host.h"

#include <boolean.h>
#include <retro_timers.h>
#include <file/file_path.h>
#include <queues/task_queue.h>
#include <string/stdstring.h>

#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifdef HAVE_MFI
#import <GameController/GCMouse.h>
#endif

#ifdef HAVE_SDL2
#define SDL_MAIN_HANDLED
#include "SDL.h"
#endif

#include <stdarg.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>

#ifdef HAVE_DYNAMIC
#include <dynamic/dylib.h>
#endif

#include "../../gfx/video_driver.h"

#ifdef HAVE_VULKAN
#include "../../gfx/common/vulkan_common.h"
#endif

#pragma mark - Notification names (each string equals its symbol)

NSString * const GamuroidWFCOnlineNotification = @"GamuroidWFCOnlineNotification";
NSString * const GamuroidWFCOfflineNotification = @"GamuroidWFCOfflineNotification";
NSString * const GamuroidRetroHostDidStopNotification = @"GamuroidRetroHostDidStopNotification";
NSString * const LibretroSaveStateLoadFailedNotification = @"LibretroSaveStateLoadFailedNotification";
NSString * const LibretroSaveStateRevisionMismatchNotification = @"LibretroSaveStateRevisionMismatchNotification";
NSString * const GamuroidCoreFilesMissingNotification = @"GamuroidCoreFilesMissingNotification";
NSString * const GamuroidSaveStateLoadResultNotification = @"GamuroidSaveStateLoadResultNotification";
NSString * const GamuroidSaveStateLoadResultPathKey = @"GamuroidSaveStateLoadResultPathKey";
NSString * const GamuroidSaveStateLoadResultSuccessKey = @"GamuroidSaveStateLoadResultSuccessKey";
NSString * const GamuroidSaveStateCoreFailureNotification = @"GamuroidSaveStateCoreFailureNotification";
NSString * const GamuroidSaveStateCoreFailureStageKey = @"GamuroidSaveStateCoreFailureStageKey";
NSString * const GamuroidSaveStateCoreFailureLineKey = @"GamuroidSaveStateCoreFailureLineKey";
NSString * const GamuroidCoreDeviceLostNotification = @"GamuroidCoreDeviceLostNotification";
NSString * const GamuroidCoreDeviceLostLineKey = @"GamuroidCoreDeviceLostLineKey";

static NSString * const kMessageUserInfoKey = @"message";

/// Size of the buffer used to format one monitored core log line.
enum { kMonitoredLogLineBytes = 4096 };

static void PostOnMainQueue(NSString *name, NSDictionary *userInfo)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:name object:nil userInfo:userInfo];
    });
}

/// UTF-8 C string → NSString; NULL or undecodable input becomes the empty string.
static NSString *StringFromCoreUTF8(const char *text)
{
    if (text == NULL)
        return @"";
    NSString *decoded = [NSString stringWithUTF8String:text];
    return decoded ?: @"";
}

#pragma mark - RetroArch callbacks

static void HandleCoreShutdownRequest(void)
{
    PostOnMainQueue(GamuroidRetroHostDidStopNotification, nil);
}

#pragma mark - State-load result (hook in tasks/task_save.c, plan C-1)

typedef void (*StateLoadResultFn)(const char *path, bool ok);
extern void gamuroid_state_load_set_result_handler(StateLoadResultFn handler);
extern void gamuroid_state_load_arm_host_request(void);
extern bool gamuroid_state_load_disarm_host_request(void);

/// Runs on the thread that finishes RetroArch's load task, after retro_unserialize returned. It goes to the
/// main queue the same way HandleCoreLogLine does, so a core failure line of this load (emitted while
/// retro_unserialize was running, on this same thread) is already queued ahead of it: the main queue is FIFO
/// for blocks enqueued in program order from one thread.
static void HandleStateLoadResult(const char *path, bool ok)
{
    @autoreleasepool {
        PostOnMainQueue(GamuroidSaveStateLoadResultNotification, @{
            GamuroidSaveStateLoadResultPathKey: StringFromCoreUTF8(path),
            GamuroidSaveStateLoadResultSuccessKey: @(ok),
        });
    }
}

#pragma mark - melonDS DS online state (core exports gamuroid_net_state_get / gamuroid_net_state_listen)

/// Code 2 = associated with the emulated access point (online); 0 and 1 are offline.
enum { kNetStateAssociated = 2 };

typedef void (*NetStateListenerFn)(int code);
typedef int (*NetStateGetFn)(void);
typedef void (*NetStateListenFn)(NetStateListenerFn listener);

/// YES between beginWFCWatch and stop. Main thread only.
static BOOL sNetStateMonitorActive = NO;

static void PostNetState(int code)
{
    PostOnMainQueue(code == kNetStateAssociated ? GamuroidWFCOnlineNotification : GamuroidWFCOfflineNotification, nil);
}

/// Called by the core on the thread running retro_run, only when the code changed. Does not call the core.
static void HandleNetStateChange(int code)
{
    PostNetState(code);
}

/// App-requested switch of the legacy core log rules (written on main, read on core threads). Only
/// -setCoreLogObserver: changes it; the app turns it on around a state load.
static atomic_bool sLogMonitorEnabled = false;
/// Host-owned: YES from beginSession to endSession. The Gamuroid core lines (state load failure, device
/// lost) are watched for the whole session, because they can appear at any time of play.
static atomic_bool sSessionLogMonitor = false;

/// Value of "stage=" in a [GAMUROID_STATE_LOAD] line: "pre" or "post". Anything else (missing, misspelled)
/// is "post": the safe reading, because it makes the app relaunch the title instead of trusting a core
/// that may have torn its system down.
static NSString *StateLoadStageFromLine(const char *line)
{
    const char *stage = strstr(line, "stage=");
    if (stage != NULL) {
        stage += strlen("stage=");
        if (strncmp(stage, "pre", 3) == 0 && (stage[3] == '\0' || stage[3] == ' ' || stage[3] == '\n'))
            return @"pre";
        if (strncmp(stage, "post", 4) == 0 && (stage[4] == '\0' || stage[4] == ' ' || stage[4] == '\n'))
            return @"post";
    }
    NSLog(@"[GAMUROID_STATE_LOAD] stage missing or unknown in core line; treating it as post");
    return @"post";
}

static void HandleCoreLogLine(enum retro_log_level level, const char *fmt, va_list args)
{
#ifdef DEBUG
    /* Gamuroid DEBUG: the core's 3DS measurement lines ([GAMUROID_3DS_*], [TransCacheStat] activation counters,
     * [GAMUROID_STATE_SAVE_TIME]) reach the
     * device only through os_log, which prints "%s" arguments as <private> off-device. Echo them to stdout, where
     * a console-attached harness reads them. Any level; formatted from a copy because the rules below consume args. */
    if (fmt != NULL && atomic_load_explicit(&sSessionLogMonitor, memory_order_relaxed)) {
        va_list echoArgs;
        char echoLine[kMonitoredLogLineBytes];
        va_copy(echoArgs, args);
        int echoLength = vsnprintf(echoLine, sizeof(echoLine), fmt, echoArgs);
        va_end(echoArgs);
        if (echoLength >= 0 && (strstr(echoLine, "[GAMUROID_3DS_") != NULL || strstr(echoLine, "[TransCacheStat]") != NULL ||
                                strstr(echoLine, "[GAMUROID_STATE_SAVE_TIME]") != NULL)) {
            fputs(echoLine, stdout);
            if (echoLine[0] != '\0' && echoLine[strlen(echoLine) - 1] != '\n')
                fputc('\n', stdout);
            fflush(stdout);
        }
    }
#endif
    BOOL legacyRules = atomic_load_explicit(&sLogMonitorEnabled, memory_order_relaxed);
    BOOL sessionRules = atomic_load_explicit(&sSessionLogMonitor, memory_order_relaxed);
    if (!legacyRules && !sessionRules)
        return;
    /* Only ERROR and WARN lines can match a rule below; skip formatting everything else. The session
     * rules (state load failure, device lost) only match ERROR lines, so a WARN is formatted only while the
     * legacy observer is on (its "different revision" rule). */
    if (level != RETRO_LOG_ERROR && !(legacyRules && level == RETRO_LOG_WARN))
        return;
    if (fmt == NULL)
        return;

    char line[kMonitoredLogLineBytes];
    if (vsnprintf(line, sizeof(line), fmt, args) < 0)
        return;

    NSString *name = nil;
    BOOL attachLine = NO;
    BOOL stateLoadFailure = NO;
    BOOL deviceLost = NO;
    if (level == RETRO_LOG_ERROR) {
        if (sessionRules && strstr(line, "[GAMUROID_STATE_LOAD] result=fail") != NULL) {
            name = GamuroidSaveStateCoreFailureNotification;
            stateLoadFailure = YES;
        } else if (sessionRules && strstr(line, "[GAMUROID_DEVICE_LOST]") != NULL) {
            name = GamuroidCoreDeviceLostNotification;
            deviceLost = YES;
        } else if (!legacyRules) {
            return;
        } else if (strstr(line, "Required files are missing,") != NULL) {
            name = GamuroidCoreFilesMissingNotification;
        } else if (strstr(line, "Failed to load state") != NULL) {
            name = LibretroSaveStateLoadFailedNotification;
            attachLine = YES;
        }
    } else if (legacyRules && strstr(line, "different revision") != NULL) {
        name = LibretroSaveStateRevisionMismatchNotification;
        attachLine = YES;
    }
    if (name == nil)
        return;

    @autoreleasepool {
        NSString *text = [NSString stringWithUTF8String:line];
        if (text == nil)
            return; /* not decodable (possibly cut inside a multi-byte sequence) */
        NSDictionary *userInfo = nil;
        if (stateLoadFailure) {
            userInfo = @{ GamuroidSaveStateCoreFailureStageKey: StateLoadStageFromLine(line),
                          GamuroidSaveStateCoreFailureLineKey: text };
        } else if (deviceLost) {
            userInfo = @{ GamuroidCoreDeviceLostLineKey: text };
        } else if (attachLine) {
            userInfo = @{ kMessageUserInfoKey: text };
        }
        PostOnMainQueue(name, userInfo);
    }
}

#pragma mark - Azahar software keyboard (core side, ABI version 2)

/// Keyboard ABI version this bridge speaks (core export gamuroid_kbd_abi).
enum { kKeyboardABIVersion = 2 };

/// Request record of keyboard ABI version 2 (spec section 6.4): natural alignment, 64-bit pointers.
/// Later versions only append fields; `size` tells how many bytes are valid.
typedef struct GamuroidKeyboardRequest {
    uint32_t size;
    uint32_t abi;
    uint32_t flags;
    uint32_t button_count;
    uint32_t confirm_button;
    uint32_t accept;
    uint32_t max_length;
    uint32_t max_digits;
    const char *hint;
    const char * const *labels;
} GamuroidKeyboardRequest;

_Static_assert(sizeof(GamuroidKeyboardRequest) == 48, "keyboard ABI v2 request record is 48 bytes");

enum {
    kKeyboardFlagMultiline     = 1u << 0,
    kKeyboardFlagNoDigits      = 1u << 1,
    kKeyboardFlagNoAt          = 1u << 2,
    kKeyboardFlagNoPercent     = 1u << 3,
    kKeyboardFlagNoBackslash   = 1u << 4,
    kKeyboardFlagProfanity     = 1u << 5,
    kKeyboardFlagGameCallback  = 1u << 6,
};

/// The record carries at most this many labels (3DS keyboard: 0 to 3 buttons).
enum { kKeyboardMaxButtons = 3 };

typedef void (*KeyboardRequestHandlerFn)(const GamuroidKeyboardRequest *request);
typedef void (*KeyboardErrorHandlerFn)(int code, const char *utf8_message);
typedef int  (*KeyboardABIFn)(void);
typedef void (*KeyboardBindFn)(KeyboardRequestHandlerFn request, KeyboardErrorHandlerFn error);
typedef void (*KeyboardSubmitFn)(const char *utf8_text, int button);
typedef void (*KeyboardAbortFn)(void);

/// Swift handlers. Written and read on the main thread only.
static void (^sKeyboardRequestHandler)(LibretroAzaharKeyboardConfig *config);
static void (^sKeyboardErrorHandler)(int errorCode, NSString *message);

/// Handle of the core library RetroArch has loaded right now, or NULL.
static void *LoadedCoreHandle(void)
{
#ifdef HAVE_DYNAMIC
    runloop_state_t *runloop = runloop_state_get_ptr();
    return runloop ? (void *)runloop->lib_handle : NULL;
#else
    return NULL;
#endif
}

static void *CoreExport(void *handle, const char *name)
{
#ifdef HAVE_DYNAMIC
    if (handle == NULL)
        return NULL;
    return (void *)dylib_proc((dylib_t)handle, name);
#else
    (void)handle;
    (void)name;
    return NULL;
#endif
}

/// YES when the core behind @p handle exports keyboard ABI version 2. Every other keyboard export is used only
/// after this check.
static BOOL CoreSpeaksKeyboardABI(void *handle)
{
    KeyboardABIFn abi = (KeyboardABIFn)CoreExport(handle, "gamuroid_kbd_abi");
    return abi != NULL && abi() == kKeyboardABIVersion;
}

static void AbortKeyboardInLoadedCore(void)
{
    void *handle = LoadedCoreHandle();
    if (!CoreSpeaksKeyboardABI(handle))
        return;
    KeyboardAbortFn abortRequest = (KeyboardAbortFn)CoreExport(handle, "gamuroid_kbd_abort");
    if (abortRequest != NULL)
        abortRequest();
}

static LibretroAzaharButtonConfig ButtonConfigForCount(uint32_t count)
{
    switch (count) {
        case 0:  return LibretroAzaharButtonConfigNone;
        case 1:  return LibretroAzaharButtonConfigSingle;
        case 2:  return LibretroAzaharButtonConfigDual;
        case 3:  return LibretroAzaharButtonConfigTriple;
        default:
            NSLog(@"[Azahar SWKBD] unexpected button count %u; using three buttons", count);
            return LibretroAzaharButtonConfigTriple;
    }
}

static LibretroAzaharKeyboardConfig *KeyboardConfigFromRequest(const GamuroidKeyboardRequest *request)
{
    uint32_t flags = request->flags;
    LibretroAzaharKeyboardConfig *config = [LibretroAzaharKeyboardConfig new];
    config.buttonConfig     = ButtonConfigForCount(request->button_count);
    config.allowedEntry    = (LibretroAzaharAcceptedInput)request->accept;
    config.maxTextLength    = (NSInteger)request->max_length;
    config.digitLimit        = (NSInteger)request->max_digits;
    config.okButtonIndex    = (NSInteger)request->confirm_button;
    config.allowsLineBreaks    = (flags & kKeyboardFlagMultiline) != 0;
    config.blocksDigits     = (flags & kKeyboardFlagNoDigits) != 0;
    config.blocksAtSign        = (flags & kKeyboardFlagNoAt) != 0;
    config.blocksPercent   = (flags & kKeyboardFlagNoPercent) != 0;
    config.blocksBackslash = (flags & kKeyboardFlagNoBackslash) != 0;
    config.blocksProfanity = (flags & kKeyboardFlagProfanity) != 0;
    config.callbackActive   = (flags & kKeyboardFlagGameCallback) != 0;
    config.hintText         = StringFromCoreUTF8(request->hint);

    uint32_t count = MIN(request->button_count, (uint32_t)kKeyboardMaxButtons);
    NSMutableArray<NSString *> *captions = [NSMutableArray arrayWithCapacity:count];
    for (uint32_t i = 0; i < count; i++) {
        const char *caption = (request->labels != NULL) ? request->labels[i] : NULL;
        [captions addObject:StringFromCoreUTF8(caption)];
    }
    config.buttonText = captions;
    return config;
}

/// Bound into the core with gamuroid_kbd_bind; the core calls it on the thread running retro_run. The record
/// is only valid during this call, so everything is copied before returning. The answer goes back later
/// through gamuroid_kbd_submit / gamuroid_kbd_abort on the main queue, never from inside this call.
static void KeyboardRequestTrampoline(const GamuroidKeyboardRequest *request)
{
    @autoreleasepool {
        if (request == NULL || request->abi != kKeyboardABIVersion
            || request->size < (uint32_t)sizeof(GamuroidKeyboardRequest)) {
            NSLog(@"[Azahar SWKBD] request rejected: abi %u size %u, expected abi %d size >= %zu; aborting",
                  request ? request->abi : 0u, request ? request->size : 0u,
                  kKeyboardABIVersion, sizeof(GamuroidKeyboardRequest));
            dispatch_async(dispatch_get_main_queue(), ^{
                AbortKeyboardInLoadedCore();
            });
            return;
        }
        LibretroAzaharKeyboardConfig *config = KeyboardConfigFromRequest(request);
        dispatch_async(dispatch_get_main_queue(), ^{
            void (^handler)(LibretroAzaharKeyboardConfig *) = sKeyboardRequestHandler;
            if (handler != nil) {
                handler(config);
            } else {
                /* Nothing can answer: end the request so the game does not wait forever. */
                NSLog(@"[Azahar SWKBD] no keyboard handler registered; aborting the request");
                AbortKeyboardInLoadedCore();
            }
        });
    }
}

/// Bound into the core with gamuroid_kbd_bind; called on the thread running retro_run.
static void KeyboardErrorTrampoline(int errorCode, const char *utf8Message)
{
    @autoreleasepool {
        NSString *message = StringFromCoreUTF8(utf8Message);
        dispatch_async(dispatch_get_main_queue(), ^{
            void (^handler)(int, NSString *) = sKeyboardErrorHandler;
            if (handler != nil) {
                handler(errorCode, message);
            } else {
                NSLog(@"[Azahar SWKBD] error %d dropped: no error handler registered", errorCode);
            }
        });
    }
}

/// Binds (or with @p bind NO unbinds) both trampolines in the core behind @p handle. Returns YES when the core
/// speaks keyboard ABI version 2 and the bind call was made.
static BOOL BindKeyboardTrampolines(void *handle, BOOL bind)
{
    if (!CoreSpeaksKeyboardABI(handle))
        return NO;
    KeyboardBindFn bindHandlers = (KeyboardBindFn)CoreExport(handle, "gamuroid_kbd_bind");
    if (bindHandlers == NULL)
        return NO;
    if (bind)
        bindHandlers(KeyboardRequestTrampoline, KeyboardErrorTrampoline);
    else
        bindHandlers(NULL, NULL);
    return YES;
}

/// Registers (or with @p listen NO removes) the online-state listener in the core behind @p handle.
/// When registering, a state that is already "online" is posted once.
static void ListenForNetState(void *handle, BOOL listen)
{
    NetStateListenFn setListener = (NetStateListenFn)CoreExport(handle, "gamuroid_net_state_listen");
    if (setListener == NULL)
        return; /* not melonDS DS (DeSmuME, other cores): feature off */
    setListener(listen ? HandleNetStateChange : NULL);
    if (!listen)
        return;
    NetStateGetFn getState = (NetStateGetFn)CoreExport(handle, "gamuroid_net_state_get");
    if (getState != NULL && getState() == kNetStateAssociated)
        PostNetState(kNetStateAssociated);
}

/// Called by runloop.c (weak reference) right after it loads a core library: bind the keyboard (Azahar) and
/// re-register the online-state listener when the monitor is active (melonDS DS).
void gamuroid_apply_azahar_keyboard_callbacks_for_handle(void *handle)
{
    if (handle == NULL)
        return;
    if (BindKeyboardTrampolines(handle, YES))
        NSLog(@"[Azahar SWKBD] keyboard ABI %d bound in the loaded core", kKeyboardABIVersion);
    if (sNetStateMonitorActive)
        ListenForNetState(handle, YES);
}

#pragma mark - Keyboard config value class

@implementation LibretroAzaharKeyboardConfig
@end

#pragma mark - Bridge

static inline const char *LibretroBoolString(BOOL value)
{
    return value ? "YES" : "NO";
}

#ifdef HAVE_VULKAN
/// The frontend's Vulkan context while a Vulkan video driver is active, else NULL. Main thread only.
static vulkan_context_t *CurrentVulkanContext(void)
{
    video_driver_state_t *videoState = video_state_get_ptr();
    if (videoState == NULL || (videoState->flags & VIDEO_FLAG_ACTIVE) == 0
            || videoState->current_video != &video_vulkan || videoState->data == NULL)
        return NULL;
    return ((vk_t *)videoState->data)->context;
}

/// A fence whose wait timed out stays unsignaled, so it may not be destroyed yet: it is kept here (with the
/// device it belongs to) and reclaimed by the next call once the GPU has caught up. endSession settles it
/// before the device goes away, so a handle never outlives its session. Main thread only.
static VkFence sQuiesceLeakedFence = VK_NULL_HANDLE;
static VkDevice sQuiesceLeakedDevice = VK_NULL_HANDLE;

static void ReclaimQuiesceFence(VkDevice currentDevice)
{
    if (sQuiesceLeakedFence == VK_NULL_HANDLE)
        return;
    if (sQuiesceLeakedDevice != currentDevice) {
        /* The device it belonged to was destroyed with its session; nothing is left to free. */
        sQuiesceLeakedFence = VK_NULL_HANDLE;
        sQuiesceLeakedDevice = VK_NULL_HANDLE;
        return;
    }
    if (vkGetFenceStatus(currentDevice, sQuiesceLeakedFence) != VK_NOT_READY) {
        vkDestroyFence(currentDevice, sQuiesceLeakedFence, NULL);
        sQuiesceLeakedFence = VK_NULL_HANDLE;
        sQuiesceLeakedDevice = VK_NULL_HANDLE;
    }
}

/// Takes the frontend's queue lock without waiting longer than @p deadline (CACurrentMediaTime seconds): a
/// core thread stuck inside a queue call must not hang the main thread.
static BOOL LockQueueUntil(slock_t *lock, CFTimeInterval deadline)
{
    if (lock == NULL)
        return YES;
    while (!slock_try_lock(lock)) {
        if (CACurrentMediaTime() >= deadline)
            return NO;
        struct timespec pause = { 0, 1000000 }; /* 1 ms poll of a bounded wait, not a delay that masks a race */
        nanosleep(&pause, NULL);
    }
    return YES;
}

/// Called at the start of endSession, while the session's device still exists. Destroys the kept fence when
/// the GPU has already finished it; if it is still pending the handle is only forgotten (a leaked fence
/// handle is harmless, a call on a fence of a destroyed device is not). Either way nothing is kept across
/// sessions, so a later device allocated at the same address can never be matched with it.
static void SettleQuiesceFenceAtSessionEnd(void)
{
    if (sQuiesceLeakedFence == VK_NULL_HANDLE)
        return;
    vulkan_context_t *context = CurrentVulkanContext();
    if (context != NULL && context->device == sQuiesceLeakedDevice
            && vkGetFenceStatus(context->device, sQuiesceLeakedFence) != VK_NOT_READY)
        vkDestroyFence(context->device, sQuiesceLeakedFence, NULL);
    sQuiesceLeakedFence = VK_NULL_HANDLE;
    sQuiesceLeakedDevice = VK_NULL_HANDLE;
}
#endif /* HAVE_VULKAN */

@interface GamuroidRetroHost()

@property (assign) BOOL isRunning;
@property (nonatomic, copy, nullable) NSString *runtimeWorkspace;
@property (nonatomic, copy, nullable) NSString *lastLibretroCorePath;

// Forward decl — called before their definitions later in this file.
- (void)cancelAzaharKeyboard;

@end

@implementation GamuroidRetroHost
{
    /// gamuroid_screen_layout value last handed to RetroArch since the last forget.
    BOOL _screenLayoutKnown;
    NSString *_screenLayout;                // nil = "cleared"
}

#pragma mark Singleton

+ (instancetype)sharedInstance
{
    static GamuroidRetroHost *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[super allocWithZone:NULL] initSingletonInstance];
    });
    return shared;
}

+ (instancetype)allocWithZone:(struct _NSZone *)zone
{
    (void)zone;
    return [self sharedInstance];
}

- (instancetype)initSingletonInstance
{
    self = [super init];
    if (self) {
#if !TARGET_OS_SIMULATOR
        _retroArch_iOS = [[RetroArch_iOS alloc] init];
#endif
    }
    return self;
}

/// alloc returns the shared object, which is already initialized.
- (instancetype)init
{
    return self;
}

- (id)copyWithZone:(struct _NSZone *)zone
{
    (void)zone;
    return self;
}

- (id)mutableCopyWithZone:(struct _NSZone *)zone
{
    (void)zone;
    return self;
}

/// Typed view of the host; nil on the simulator, which makes every forwarded call a no-op.
- (RetroArch_iOS *)host
{
    return (RetroArch_iOS *)_retroArch_iOS;
}

#pragma mark Live state

- (BOOL)isLibretroInitialized {
    RetroArch_iOS *retroArch = [self host];
    if (!retroArch) {
        return NO;
    }
    return [retroArch hostSessionIsOpen];
}

- (BOOL)isLibretroStopping {
    RetroArch_iOS *retroArch = [self host];
    if (!retroArch) {
        return NO;
    }
    return [retroArch hostSessionIsEnding];
}

- (BOOL)isCoreReadyForContentLoad {
    RetroArch_iOS *retroArch = [self host];
    if (!retroArch) {
        return NO;
    }
    return [retroArch hostCoreAcceptsContent];
}

- (BOOL)coreLoopRunning {
    RetroArch_iOS *retroArch = [self host];
    if (!retroArch) {
        return NO;
    }
    return [retroArch hostCoreIsRunning];
}

- (unsigned long long)videoFrameCount {
    RetroArch_iOS *retroArch = [self host];
    if (!retroArch) {
        return 0;
    }
    return [retroArch hostPresentedFrameCount];
}

- (NSString *)latestCoreMessage {
    const char *message = runloop_get_last_core_message();
    if (!message || !*message) {
        return nil;
    }
    return [NSString stringWithUTF8String:message];
}

- (BOOL)isFlycastCorePath:(NSString * _Nullable)corePath {
    return [corePath.lowercaseString containsString:@"flycast"];
}

- (BOOL)shouldTraceFlycastRuntime {
    return [self isFlycastCorePath:self.lastLibretroCorePath];
}

- (void)discardLatestCoreMessage {
    runloop_clear_last_core_message();
}

- (NSString *)workspaceRoot {
    return self.runtimeWorkspace ?: [self host].hostWorkspaceRoot;
}

- (void)setWorkspaceRoot:(NSString *)workspace
{
    self.runtimeWorkspace = [workspace copy];
    [self host].hostWorkspaceRoot = workspace;
}

#pragma mark Lifecycle

- (UIViewController *)beginSessionWithSaveDirectory:(NSString *_Nullable)saveFolderOverride {
    /* C-5: the frame counter starts at 0 for this session. Nothing renders yet (the previous session is over
     * and its core is unloaded), and the video driver resets it again when it initializes. */
    video_driver_state_t *videoState = video_state_get_ptr();
    if (videoState != NULL)
        __atomic_store_n(&videoState->frame_count, (uint64_t)0, __ATOMIC_RELAXED);
    [[self host] hostBeginSessionWithSaveDir:saveFolderOverride];
    // Re-wire any Azahar keyboard callbacks that were registered before the
    // core dylib was dlopen'd. No-op if handle is still null or no callbacks pending.
    BindKeyboardTrampolines(LoadedCoreHandle(), YES);
    self.isRunning = self.isLibretroInitialized;
    if ([self shouldTraceFlycastRuntime]) {
        NSLog(@"[DC_TRACE] startWithCustomSaveDir saveFolderOverride=%@ lastCorePath=%@ libretroInitialized=%s coreRunning=%s",
              saveFolderOverride ?: @"<nil>",
              self.lastLibretroCorePath ?: @"<nil>",
              LibretroBoolString(self.isRunning),
              LibretroBoolString([self coreLoopRunning]));
    }
    gamuroid_register_shutdown_callback(HandleCoreShutdownRequest);
    runloop_set_gamuroid_core_log_handler(HandleCoreLogLine);
    /* Watch the Gamuroid core lines (state load failure, device lost) for the whole session; the legacy
     * rules keep following -setCoreLogObserver:. Cleared in endSession. */
    atomic_store_explicit(&sSessionLogMonitor, true, memory_order_relaxed);
    gamuroid_state_load_set_result_handler(HandleStateLoadResult);
    return [CocoaView get];
}

- (void)pauseSession {
    if ([self shouldTraceFlycastRuntime]) {
        NSLog(@"[DC_TRACE] pause corePath=%@ isRunning=%s coreRunning=%s frameCount=%llu",
              self.lastLibretroCorePath ?: @"<nil>",
              LibretroBoolString(self.isRunning),
              LibretroBoolString([self coreLoopRunning]),
              [self videoFrameCount]);
    }
    [[self host] hostPauseSession];
}

- (void)resumeSession {
    if ([self shouldTraceFlycastRuntime]) {
        NSLog(@"[DC_TRACE] resume corePath=%@ isRunning=%s coreRunning=%s frameCount=%llu",
              self.lastLibretroCorePath ?: @"<nil>",
              LibretroBoolString(self.isRunning),
              LibretroBoolString([self coreLoopRunning]),
              [self videoFrameCount]);
    }
    [[self host] hostResumeSession];
}

- (void)endSession {
    // Clear layout sentinel caches before teardown — next session/core swap
    // gets fresh state. Prevents stale cache hits when same-value layout
    // is pushed in new session.
    [self forgetLayoutMemory];
    runloop_set_gamuroid_screen_layout(NULL);

    if ([self shouldTraceFlycastRuntime]) {
        NSLog(@"[DC_TRACE] stop corePath=%@ isRunning=%s coreRunning=%s frameCount=%llu",
              self.lastLibretroCorePath ?: @"<nil>",
              LibretroBoolString(self.isRunning),
              LibretroBoolString([self coreLoopRunning]),
              [self videoFrameCount]);
    }
    self.isRunning = NO;
#ifdef HAVE_VULKAN
    SettleQuiesceFenceAtSessionEnd();
#endif

    gamuroid_register_shutdown_callback(NULL);
    runloop_set_gamuroid_core_log_handler(NULL);
    atomic_store_explicit(&sLogMonitorEnabled, false, memory_order_relaxed);
    atomic_store_explicit(&sSessionLogMonitor, false, memory_order_relaxed);
    gamuroid_state_load_set_result_handler(NULL);

    sNetStateMonitorActive = NO;
    // Cancel any in-flight keyboard request in the core before tearing the
    // dylib down. Must happen BEFORE dlclose so retro_keyboard_cancel is still
    // resolvable. Keep the saved Swift callbacks registered: Azahar can stop
    // and immediately restart inside the same GamuroidPlayScreen (permission
    // return, Vulkan cleanup, active-core restart). Clearing them here makes
    // the first SWKBD request after restart fall through to the core's empty
    // input fallback.
    void *handle = LoadedCoreHandle();
    AbortKeyboardInLoadedCore();
    BindKeyboardTrampolines(handle, NO);
    ListenForNetState(handle, NO);
    [[self host] hostEndSession];
}

#pragma mark Content

- (BOOL)openContent:(NSString *)contentLocation withCore:(NSString *)corePath completion:(void(^ _Nullable)(NSDictionary *_Nullable))completion {
    // New content/core load — clear layout caches so first push for this content
    // applies fresh (some load paths may bypass -stop, e.g., direct core swap).
    [self forgetLayoutMemory];
    [self discardLatestCoreMessage];

    self.lastLibretroCorePath = corePath;
    if ([corePath.lowercaseString containsString:@"melonds"]) {
        NSLog(@"[NDSLayoutTrace] bootContentFile corePath=%@ contentLocation=%@",
              corePath ?: @"<nil>",
              contentLocation ?: @"<nil>");
    } else if ([corePath.lowercaseString containsString:@"flycast"]) {
        NSLog(@"[DC_TRACE] bootContentFile corePath=%@ contentLocation=%@ isRunning=%s",
              corePath ?: @"<nil>",
              contentLocation ?: @"<nil>",
              LibretroBoolString(self.isRunning));
    }
    return [[self host] hostOpenContent:contentLocation withCore:corePath completion:completion];
}

- (BOOL)openSubsystem:(NSString *)subsystemIdent
         contentPaths:(NSArray<NSString *> *)romPaths
             withCore:(NSString *)corePath
           completion:(void(^ _Nullable)(NSDictionary *_Nullable))completion {
    [self forgetLayoutMemory];
    [self discardLatestCoreMessage];

    self.lastLibretroCorePath = corePath;
    return [[self host] hostOpenSubsystem:subsystemIdent files:romPaths withCore:corePath completion:completion];
}

- (void)openCoreWithoutContent:(NSString *)corePath
{
    [[self host] hostStartCoreWithoutContent:corePath];
}

- (void)reload
{
    [[self host] hostRestartContent];
}

- (void)reloadByKeepState:(BOOL)keepState
{
    [[self host] hostRestartContentKeepingState:keepState];
}

#pragma mark State

- (BOOL)saveState:(void(^ _Nullable)(NSString *_Nullable path))completion {
    if ([self shouldTraceFlycastRuntime]) {
        NSLog(@"[DC_TRACE] saveState request corePath=%@ isRunning=%s coreRunning=%s frameCount=%llu",
              self.lastLibretroCorePath ?: @"<nil>",
              LibretroBoolString(self.isRunning),
              LibretroBoolString([self coreLoopRunning]),
              [self videoFrameCount]);
    }
    BOOL result = [[self host] hostSaveStateWithCompletion:completion];
    if ([self shouldTraceFlycastRuntime]) {
        NSLog(@"[DC_TRACE] saveState result=%s corePath=%@",
              LibretroBoolString(result),
              self.lastLibretroCorePath ?: @"<nil>");
    }
    return result;
}

- (BOOL)saveStateAsyncControlled:(void(^ _Nullable)(NSString *_Nullable path))completion {
    if ([self shouldTraceFlycastRuntime]) {
        NSLog(@"[DC_TRACE] saveStateAsyncControlled request corePath=%@ isRunning=%s coreRunning=%s frameCount=%llu",
              self.lastLibretroCorePath ?: @"<nil>",
              LibretroBoolString(self.isRunning),
              LibretroBoolString([self coreLoopRunning]),
              [self videoFrameCount]);
    }
    BOOL result = [[self host] hostSaveStateControlledWithCompletion:completion];
    if ([self shouldTraceFlycastRuntime]) {
        NSLog(@"[DC_TRACE] saveStateAsyncControlled result=%s corePath=%@",
              LibretroBoolString(result),
              self.lastLibretroCorePath ?: @"<nil>");
    }
    return result;
}

- (BOOL)loadState:(NSString *_Nonnull)path {
    if ([self shouldTraceFlycastRuntime]) {
        NSLog(@"[DC_TRACE] loadState request corePath=%@ path=%@ isRunning=%s coreRunning=%s frameCount=%llu",
              self.lastLibretroCorePath ?: @"<nil>",
              path ?: @"<nil>",
              LibretroBoolString(self.isRunning),
              LibretroBoolString([self coreLoopRunning]),
              [self videoFrameCount]);
    }
    /* C-1: mark the load task content_load_state() creates inside hostRestoreStateAtPath: (same thread, same
     * call), so its final result is reported once through GamuroidSaveStateLoadResultNotification. */
    gamuroid_state_load_arm_host_request();
    BOOL result = [[self host] hostRestoreStateAtPath:path];
    BOOL queued = gamuroid_state_load_disarm_host_request();
    if (result && !queued) {
        /* Accepted but no marked task exists: no result would ever arrive, so refuse instead of lying. */
        NSLog(@"[GAMUROID_STATE_LOAD] host accepted the load but queued no reportable task; refusing path=%@", path ?: @"<nil>");
        result = NO;
    } else if (!result && queued) {
        /* Cannot happen (a queued task makes content_load_state return true); the result is still reported. */
        NSLog(@"[GAMUROID_STATE_LOAD] host refused a load that queued a task; the task result will still be reported path=%@", path ?: @"<nil>");
    }
    if ([self shouldTraceFlycastRuntime]) {
        NSLog(@"[DC_TRACE] loadState result=%s corePath=%@ path=%@",
              LibretroBoolString(result),
              self.lastLibretroCorePath ?: @"<nil>",
              path ?: @"<nil>");
    }
    return result;
}

#pragma mark Frame, audio, speed

- (void)snapshot:(void (^)(UIImage *))completion
{
#if TARGET_OS_SIMULATOR
    if (completion != nil)
        completion(nil);
#else
    [[self host] hostCaptureFrame:completion];
#endif
}

#pragma mark GPU quiesce (plan C-4)

- (BOOL)quiesceGPUWithTimeout:(NSTimeInterval)timeout
{
    CFTimeInterval start = CACurrentMediaTime();
    const char *result = "skip";
    BOOL ok = YES;
    int vkCode = 0;
#ifdef HAVE_VULKAN
    vulkan_context_t *context = self.isLibretroInitialized ? CurrentVulkanContext() : NULL;
    if (context != NULL && context->device != VK_NULL_HANDLE && context->queue != VK_NULL_HANDLE) {
        CFTimeInterval deadline = start + MAX(timeout, 0.0);
        VkDevice device = context->device;
        VkFence fence = VK_NULL_HANDLE;
        VkFenceCreateInfo fenceInfo = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
        ReclaimQuiesceFence(device);
        VkResult status = vkCreateFence(device, &fenceInfo, NULL, &fence);
        if (status == VK_SUCCESS) {
            /* An empty submit signals the fence only after everything submitted to this queue before it. */
            VkSubmitInfo submit = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO };
            BOOL submitted = NO;
            if (LockQueueUntil(context->queue_lock, deadline)) {
                status = vkQueueSubmit(context->queue, 1, &submit, fence);
                if (context->queue_lock != NULL)
                    slock_unlock(context->queue_lock);
                if (status == VK_SUCCESS) {
                    submitted = YES;
                    CFTimeInterval remaining = MAX(deadline - CACurrentMediaTime(), 0.0);
                    status = vkWaitForFences(device, 1, &fence, VK_TRUE, (uint64_t)(remaining * 1e9));
                }
            } else {
                status = VK_TIMEOUT; /* queue lock still held by a core thread at the deadline */
            }
            if (submitted && status == VK_TIMEOUT) {
                /* The fence is queued behind GPU work that has not finished: keep it, free it later. */
                sQuiesceLeakedFence = fence;
                sQuiesceLeakedDevice = device;
            } else {
                vkDestroyFence(device, fence, NULL);
            }
        }
        if (status == VK_SUCCESS) {
            result = "ok";
        } else if (status == VK_TIMEOUT) {
            result = "timeout";
            ok = NO;
        } else {
            /* VK_ERROR_DEVICE_LOST, or any other failure that leaves the queue unusable: report "lost". */
            result = "lost";
            ok = NO;
            vkCode = (int)status;
        }
    }
#else
    (void)timeout;
#endif
    long elapsedMs = (long)llround((CACurrentMediaTime() - start) * 1000.0);
    if (vkCode != 0)
        NSLog(@"[GAMUROID_GPU_QUIESCE] result=%s ms=%ld vk=%d", result, elapsedMs, vkCode);
    else
        NSLog(@"[GAMUROID_GPU_QUIESCE] result=%s ms=%ld", result, elapsedMs);
    return ok;
}

+ (uint64_t)threadSafeFrameCount
{
    video_driver_state_t *videoState = video_state_get_ptr();
    if (videoState == NULL)
        return 0;
    /* video_driver_frame() adds one per frame the core hands over (duplicated frames included); the video
     * driver resets it at init and beginSession at the start. The load only avoids a torn read. */
    return __atomic_load_n(&videoState->frame_count, __ATOMIC_RELAXED);
}

- (void)mute:(BOOL)mute
{
    /* Parity: YES = audio enabled. */
    [[self host] hostSetAudioEnabled:mute];
}

- (void)fastForward:(float)rate
{
    [[self host] hostSetFastForwardRate:rate];
}

- (void)setHonorsRingerSwitch:(BOOL)respect
{
    [[self host] hostSetSilentSwitchRespected:respect];
}

#pragma mark Input forwarding

- (void)forwardTouchEvent:(UIEvent *)event
{
    if (self.isRunning)
        [[self host] hostHandleTouchEvent:event];
}



- (void)pointerDownAtX:(CGFloat)x y:(CGFloat)y
{
    [[self host] hostPointerDownAtX:x y:y];
}

- (void)pointerUp
{
    [[self host] hostPointerUp];
}

- (void)setPlayStationAnalogMode:(BOOL)analog
{
    [[self host] hostSetPSXAnalogMode:analog];
}

- (void)tiltStickLeft:(BOOL)left horizontal:(CGFloat)x vertical:(CGFloat)y forPlayer:(unsigned)player
{
    RetroArch_iOS *host = [self host];
    [host hostSetStickLeft:left x:x y:y forPlayer:player];
}

- (void)buttonUp:(LibretroButton)button forPlayer:(unsigned)player
{
    [self deliverButton:button pressed:NO forPlayer:player];
}

- (void)buttonDown:(LibretroButton)button forPlayer:(unsigned)player
{
    [self deliverButton:button pressed:YES forPlayer:player];
}

/// Shared tail of buttonDown / buttonUp: converts the button to the host's unsigned id and picks the host call.
- (void)deliverButton:(LibretroButton)button pressed:(BOOL)pressed forPlayer:(unsigned)player
{
    RetroArch_iOS *host = [self host];
    unsigned buttonID = (unsigned)button;
    if (pressed)
        [host hostButtonDown:buttonID forPlayer:player];
    else
        [host hostButtonUp:buttonID forPlayer:player];
}

#pragma mark Input

- (void)setRumbleOn:(BOOL)enable
{
    [[self host] hostSetRumbleEnabled:enable];
}

- (BOOL)motionSensorsOn:(int)playerIndex
{
    return [[self host] hostMotionSensorRequestedForPort:(unsigned)playerIndex];
}

#pragma mark Configuration

- (void)applyToCore:(NSString *)coreName option:(NSString *)key value:(NSString *)value shouldReload:(BOOL)reload {
    if ([coreName.lowercaseString containsString:@"melonds"]) {
        NSLog(@"[NDSLayoutTrace] updateCoreConfig key core=%@ reload=%s %@=%@",
              coreName,
              reload ? "YES" : "NO",
              key ?: @"<nil>",
              value ?: @"<nil>");
    } else if ([coreName.lowercaseString containsString:@"flycast"]) {
        self.lastLibretroCorePath = coreName;
        NSLog(@"[DC_TRACE] updateCoreConfig key core=%@ reload=%s %@=%@",
              coreName ?: @"<nil>",
              reload ? "YES" : "NO",
              key ?: @"<nil>",
              value ?: @"<nil>");
    }
    [[self host] hostSetOption:key to:value forCore:coreName reload:reload];
}

- (void)applyToCore:(NSString *)coreName options:(NSDictionary<NSString*, NSString*> *_Nullable)configs shouldReload:(BOOL)reload {
    if ([coreName.lowercaseString containsString:@"melonds"]) {
        NSLog(@"[NDSLayoutTrace] updateCoreConfig configs core=%@ reload=%s configs=%@",
              coreName,
              reload ? "YES" : "NO",
              configs ?: @{});
    } else if ([coreName.lowercaseString containsString:@"flycast"]) {
        self.lastLibretroCorePath = coreName;
        NSLog(@"[DC_TRACE] updateCoreConfig configs core=%@ reload=%s configs=%@",
              coreName ?: @"<nil>",
              reload ? "YES" : "NO",
              configs ?: @{});
    }
    [[self host] hostSetOptions:configs forCore:coreName reload:reload];
}

- (void)applyLiveOptions:(NSDictionary<NSString *, NSString *> *)configs flush:(BOOL)flush
{
    [[self host] hostApplyLiveOptions:configs flush:flush];
}

- (void)setFrontendSetting:(NSString *)key value:(NSString *)value
{
    [[self host] hostSetFrontendSetting:key to:value];
}

- (void)applyRetroOptions:(NSDictionary<NSString *, NSString *> *)configs
{
    [[self host] hostSetFrontendSettings:configs];
}

- (NSString *)coreOptionValue:(NSString *)coreName key:(NSString *)key
{
    return [[self host] hostOptionValue:key forCore:coreName];
}

- (NSString *)retroOptionValue:(NSString *)key
{
    return [[self host] hostFrontendSettingValue:key];
}

- (void)setRestoreDelay:(double)delay
{
    [[self host] hostSetReloadDelay:delay];
}

- (void)setSaveSuffixOverride:(NSString * _Nullable)saveSuffixOverride
{
    [[self host] hostSetSaveExtension:saveSuffixOverride];
}

- (void)markCoreOptionsDirty
{
    core_option_manager_t *options = NULL;
    if (retroarch_ctl(RARCH_CTL_CORE_OPTIONS_LIST_GET, &options) && options != NULL)
        options->updated = true;
    retroarch_ctl(RARCH_CTL_CORE_OPTION_UPDATE_DISPLAY, NULL);
}

#pragma mark Discs

- (NSUInteger)discCount
{
    return [[self host] hostDiscCount];
}

- (NSUInteger)selectedDiscIndex
{
    return [[self host] hostSelectedDiscIndex];
}

- (void)selectDisc:(unsigned)index delayed:(BOOL)delay
{
    [[self host] hostSelectDisc:index delayed:delay];
}

#pragma mark Cheats

- (void)setCheat:(NSString *)code atIndex:(unsigned)index enabled:(BOOL)enable
{
    [[self host] hostAddCheat:code slot:index enabled:enable];
}

- (void)clearCheats
{
    [[self host] hostClearCheats];
}

#pragma mark Screen layouts

- (void)forgetLayoutMemory
{
    _screenLayoutKnown = NO;
    _screenLayout = nil;
}

- (void)setScreenLayout:(NSString *)layout
{
    if (_screenLayoutKnown) {
        if (layout == nil ? _screenLayout == nil : [layout isEqualToString:_screenLayout])
            return; /* UIKit layout passes repeat the same value many times per second */
    }

    const char *utf8 = layout.UTF8String; /* nil layout -> NULL -> cleared */
    if (layout != nil && utf8 == NULL) {
        NSLog(@"[LayoutBridge] screen layout not representable as UTF-8; ignored");
        return;
    }
    if (runloop_set_gamuroid_screen_layout(utf8))
        [self markCoreOptionsDirty];
    _screenLayoutKnown = YES;
    _screenLayout = [layout copy];
#ifdef DEBUG
    NSLog(@"[LayoutBridge] gamuroid_screen_layout=%@", layout ?: @"<cleared>");
#endif
}

#pragma mark NDS network

- (void)setDSServerAddress:(NSString *)dns
{
    /* nil (or an empty string) clears the answer: melonds_firmware_wfc_dns then comes from the option store. */
    const char *utf8 = (dns.length > 0) ? dns.UTF8String : NULL;
    if (runloop_set_gamuroid_wfc_dns(utf8))
        [self markCoreOptionsDirty];
}

- (void)beginWFCWatch
{
    sNetStateMonitorActive = YES;
    ListenForNetState(LoadedCoreHandle(), YES);
}

#pragma mark Diagnostics

- (void)setCoreLogObserver:(BOOL)enabled
{
    atomic_store_explicit(&sLogMonitorEnabled, enabled ? true : false, memory_order_relaxed);
}

#pragma mark Azahar software keyboard (app side)

- (void)bind3DSTextEntry:(void (^)(LibretroAzaharKeyboardConfig *))handler
{
    sKeyboardRequestHandler = [handler copy];
    /* The trampolines are bound at every core load; binding again is harmless and covers a core that was
     * loaded before this bridge version registered anything. A request that arrives with no handler is ended. */
    BindKeyboardTrampolines(LoadedCoreHandle(), YES);
}

- (void)registerAzaharKeyboardErrorCallback:(void (^)(int, NSString *))handler
{
    sKeyboardErrorHandler = [handler copy];
}

- (void)submit3DSTextEntry:(NSString *)text buttonIndex:(int)buttonIndex
{
    void *handle = LoadedCoreHandle();
    if (!CoreSpeaksKeyboardABI(handle))
        return;
    KeyboardSubmitFn submit = (KeyboardSubmitFn)CoreExport(handle, "gamuroid_kbd_submit");
    if (submit == NULL)
        return;
    const char *utf8 = text.UTF8String;
    submit(utf8 != NULL ? utf8 : "", buttonIndex);
}

- (void)cancelAzaharKeyboard
{
    AbortKeyboardInLoadedCore();
}

@end
