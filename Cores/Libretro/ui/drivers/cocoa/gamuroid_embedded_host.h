// gamuroid_embedded_host.h — Gamuroid.
//
// Embedded-host API of RetroArch_iOS. With GAMUROID_EMBEDDED_HOST the RetroArch_iOS object is not the
// application delegate: the GamuroidRetroHost bridge creates it and drives one libretro session at a time through
// the methods below. Only ui_cocoatouch.m (implementation) and GamuroidRetroHost.m (caller) import this header.
//
// Contract of every method: call on the main thread; completions are delivered on the main queue.
// Parameter types and nullability follow the bridge method each host method serves (cocoa/GamuroidRetroHost.h).
// Host names carry the "host" prefix so that they never collide with the bridge selectors.

#ifndef GAMUROID_EMBEDDED_HOST_H
#define GAMUROID_EMBEDDED_HOST_H

#import <UIKit/UIKit.h>

#include "apple_platform.h"

NS_ASSUME_NONNULL_BEGIN

@interface RetroArch_iOS ()

/* ---- 1. Session ---- */

/* Content, core and workspace root of the current session. The root is kept across sessions. */
@property (nonatomic, copy, nullable) NSString *hostContentPath;
@property (nonatomic, copy, nullable) NSString *hostCorePath;
@property (nonatomic, copy, nullable) NSString *hostWorkspaceRoot;

/* Starts RetroArch for one session; a nil or empty saveDir keeps the default save directory. */
- (void)hostBeginSessionWithSaveDir:(nullable NSString *)saveDir;
- (void)hostPauseSession;
- (void)hostResumeSession;
/* Synchronous teardown. Never sends CMD_EVENT_CLOSE_CONTENT (without the menu it becomes a quit). */
- (void)hostEndSession;

/* Queries: cheap and free of side effects. */
- (BOOL)hostSessionIsOpen;
- (BOOL)hostSessionIsEnding;
- (BOOL)hostCoreAcceptsContent;
- (BOOL)hostCoreIsRunning;
- (uint64_t)hostPresentedFrameCount;

/* ---- 2. Content ---- */

- (BOOL)hostOpenContent:(NSString *)contentPath
               withCore:(NSString *)corePath
             completion:(void (^_Nullable)(NSDictionary *_Nullable info))completion;
- (BOOL)hostOpenSubsystem:(NSString *)subsystemName
                    files:(NSArray<NSString *> *)filePaths
                 withCore:(NSString *)corePath
               completion:(void (^_Nullable)(NSDictionary *_Nullable info))completion;
- (void)hostStartCoreWithoutContent:(NSString *)corePath;
- (void)hostRestartContent;
- (void)hostRestartContentKeepingState:(BOOL)keepState;

/* ---- 3. State ---- */

/* Both save calls write to a new temporary .state file and report its path through the completion. */
- (BOOL)hostSaveStateWithCompletion:(void (^_Nullable)(NSString *_Nullable path))completion;
- (BOOL)hostSaveStateControlledWithCompletion:(void (^_Nullable)(NSString *_Nullable path))completion;
- (BOOL)hostRestoreStateAtPath:(NSString *)path;

/* ---- 4. Presentation and audio ---- */

/* YES = sound on. */
- (void)hostSetAudioEnabled:(BOOL)audioEnabled;
- (void)hostCaptureFrame:(void (^_Nullable)(UIImage *_Nullable image))completion;
- (void)hostSetSilentSwitchRespected:(BOOL)respect;

/* ---- 5. Speed ---- */

/* Rates up to 1 mean normal speed. */
- (void)hostSetFastForwardRate:(float)rate;
- (void)hostSetReloadDelay:(double)seconds;

/* ---- 6. Options and configuration files ---- */

- (void)hostSetOption:(NSString *)key
                   to:(NSString *)value
              forCore:(NSString *)coreName
               reload:(BOOL)reload;
- (void)hostSetOptions:(nullable NSDictionary<NSString *, NSString *> *)options
               forCore:(NSString *)coreName
                reload:(BOOL)reload;
- (void)hostApplyLiveOptions:(nullable NSDictionary<NSString *, NSString *> *)options flush:(BOOL)flush;
- (void)hostSetFrontendSetting:(NSString *)key to:(NSString *)value;
- (void)hostSetFrontendSettings:(nullable NSDictionary<NSString *, NSString *> *)settings;
- (nullable NSString *)hostOptionValue:(NSString *)key forCore:(NSString *)coreName;
- (nullable NSString *)hostFrontendSettingValue:(NSString *)key;

/* ---- 7. Input ---- */

- (void)hostHandleTouchEvent:(UIEvent *)event;
- (void)hostButtonDown:(unsigned)button forPlayer:(unsigned)player;
- (void)hostButtonUp:(unsigned)button forPlayer:(unsigned)player;
- (void)hostSetStickLeft:(BOOL)left x:(CGFloat)x y:(CGFloat)y forPlayer:(unsigned)player;
- (void)hostPointerDownAtX:(CGFloat)x y:(CGFloat)y;
- (void)hostPointerUp;
- (void)hostSetPSXAnalogMode:(BOOL)analog;
- (void)hostSetRumbleEnabled:(BOOL)enabled;
/* YES while the core has a motion sensor switched on for the port. */
- (BOOL)hostMotionSensorRequestedForPort:(unsigned)port;

/* ---- 8. Media and cheats ---- */

- (void)hostSelectDisc:(unsigned)index delayed:(BOOL)delayed;
- (NSUInteger)hostSelectedDiscIndex;
- (NSUInteger)hostDiscCount;
- (void)hostAddCheat:(NSString *)code slot:(unsigned)slot enabled:(BOOL)enabled;
- (void)hostClearCheats;
- (void)hostSetSaveExtension:(nullable NSString *)extension;

@end

NS_ASSUME_NONNULL_END

#endif
