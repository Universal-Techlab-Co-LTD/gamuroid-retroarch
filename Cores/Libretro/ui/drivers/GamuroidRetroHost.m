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

#pragma mark - Notification names (each string equals its symbol)

NSString * const GamuroidWFCOnlineNotification = @"GamuroidWFCOnlineNotification";
NSString * const GamuroidWFCOfflineNotification = @"GamuroidWFCOfflineNotification";
NSString * const GamuroidRetroHostDidStopNotification = @"GamuroidRetroHostDidStopNotification";
NSString * const LibretroSaveStateLoadFailedNotification = @"LibretroSaveStateLoadFailedNotification";
NSString * const LibretroSaveStateRevisionMismatchNotification = @"LibretroSaveStateRevisionMismatchNotification";
NSString * const GamuroidCoreFilesMissingNotification = @"GamuroidCoreFilesMissingNotification";

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

/// Process-global switch of the core log monitor (written on main, read on core threads).
static atomic_bool sLogMonitorEnabled = false;

static void HandleCoreLogLine(enum retro_log_level level, const char *fmt, va_list args)
{
    if (!atomic_load_explicit(&sLogMonitorEnabled, memory_order_relaxed))
        return;
    /* Only ERROR and WARN lines can match a rule below; skip formatting everything else. */
    if (level != RETRO_LOG_ERROR && level != RETRO_LOG_WARN)
        return;
    if (fmt == NULL)
        return;

    char line[kMonitoredLogLineBytes];
    if (vsnprintf(line, sizeof(line), fmt, args) < 0)
        return;

    NSString *name = nil;
    BOOL attachLine = NO;
    if (level == RETRO_LOG_ERROR) {
        if (strstr(line, "Required files are missing,") != NULL) {
            name = GamuroidCoreFilesMissingNotification;
        } else if (strstr(line, "Failed to load state") != NULL) {
            name = LibretroSaveStateLoadFailedNotification;
            attachLine = YES;
        }
    } else if (strstr(line, "different revision") != NULL) {
        name = LibretroSaveStateRevisionMismatchNotification;
        attachLine = YES;
    }
    if (name == nil)
        return;

    @autoreleasepool {
        NSString *text = [NSString stringWithUTF8String:line];
        if (text == nil)
            return; /* not decodable (possibly cut inside a multi-byte sequence) */
        PostOnMainQueue(name, attachLine ? @{ kMessageUserInfoKey: text } : nil);
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

    gamuroid_register_shutdown_callback(NULL);
    runloop_set_gamuroid_core_log_handler(NULL);
    atomic_store_explicit(&sLogMonitorEnabled, false, memory_order_relaxed);

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
    BOOL result = [[self host] hostRestoreStateAtPath:path];
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
