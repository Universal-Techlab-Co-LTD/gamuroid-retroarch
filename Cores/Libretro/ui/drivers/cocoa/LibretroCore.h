// LibretroCore.h — Gamuroid.
//
// Public Objective-C interface of the Libretro framework: the app talks to RetroArch only through the
// LibretroCore singleton declared here. This header must not include any RetroArch header.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Notifications (string value = symbol name; posted async on the main queue, object nil)

// Also exported by LibretroCore.m (observed by raw string, not declared here):
//   LibretroDidShutdownNotification   - a core sent RETRO_ENVIRONMENT_SHUTDOWN
//   DidConnectToWFCNotification       - melonDS Wi-Fi Connection state "Associated"
//   DidDisconnectFromWFCNotification  - any other melonDS Wi-Fi Connection state

extern NSString * const MAMEGameFileMissingNotification;
extern NSString * const LibretroSaveStateRevisionMismatchNotification;
extern NSString * const LibretroSaveStateLoadFailedNotification;

#pragma mark - Joypad buttons

/// Libretro RETRO_DEVICE_ID_JOYPAD_* ids. Also the bit index in the virtual pad and the button number in
/// the bundled autoconfig.
typedef NS_ENUM(NSUInteger, LibretroButton) {
    LibretroButtonB      = 0,
    LibretroButtonY      = 1,
    LibretroButtonSelect = 2,
    LibretroButtonStart  = 3,
    LibretroButtonUp     = 4,
    LibretroButtonDown   = 5,
    LibretroButtonLeft   = 6,
    LibretroButtonRight  = 7,
    LibretroButtonA      = 8,
    LibretroButtonX      = 9,
    LibretroButtonL1     = 10,
    LibretroButtonR1     = 11,
    LibretroButtonL2     = 12,
    LibretroButtonR2     = 13,
    LibretroButtonL3     = 14,
    LibretroButtonR3     = 15,
};

#pragma mark - Azahar software keyboard

// Azahar keyboard config — defined inline to avoid header search path issues
typedef NS_ENUM(NSUInteger, LibretroAzaharButtonConfig) {
    LibretroAzaharButtonConfigSingle,
    LibretroAzaharButtonConfigDual,
    LibretroAzaharButtonConfigTriple,
    LibretroAzaharButtonConfigNone,
};

typedef NS_ENUM(NSUInteger, LibretroAzaharAcceptedInput) {
    LibretroAzaharAcceptedInputAnything,
    LibretroAzaharAcceptedInputNotEmpty,
    LibretroAzaharAcceptedInputNotEmptyAndNotBlank,
    LibretroAzaharAcceptedInputNotBlank,
    LibretroAzaharAcceptedInputFixedLength,
};

/// Copy of one keyboard request from the Azahar core. The bridge fills every property.
@interface LibretroAzaharKeyboardConfig : NSObject
@property (nonatomic, assign) LibretroAzaharButtonConfig buttonConfig;
@property (nonatomic, assign) LibretroAzaharAcceptedInput acceptedInput;
@property (nonatomic) BOOL multilineMode;
/// In UTF-16 code units.
@property (nonatomic) NSInteger maxTextLength;
@property (nonatomic) NSInteger maxDigits;
@property (nonatomic, assign) NSInteger okButtonIndex;  // Single=0, Dual=1, Triple=2
/// Prompt text; empty string when the core gave none.
@property (nonatomic, copy, nullable) NSString *hintText;
/// Button captions; exactly as many entries as the core announced.
@property (nonatomic, copy, nullable) NSArray<NSString *> *buttonText;
@property (nonatomic) BOOL preventDigit;
@property (nonatomic) BOOL preventAt;
@property (nonatomic) BOOL preventPercent;
@property (nonatomic) BOOL preventBackslash;
@property (nonatomic) BOOL preventProfanity;
@property (nonatomic) BOOL enableCallback;
@end

#pragma mark - Bridge

/// Single process-wide bridge to RetroArch. Every method is called on the main thread.
@interface LibretroCore : NSObject

/// The RetroArch host object (RetroArch_iOS). nil on the simulator.
@property (nonatomic, strong, nullable) id retroArch_iOS;
@property(nonatomic, assign, readonly) BOOL isRunning;
@property(nonatomic, assign, readonly) BOOL isLibretroInitialized;
@property(nonatomic, assign, readonly) BOOL isLibretroStopping;
@property(nonatomic, assign, readonly) BOOL isCoreReadyForContentLoad;
@property(nonatomic, assign, readonly) BOOL isCoreRunning;
@property(nonatomic, assign, readonly) unsigned long long videoFrameCount;
/// The one bridge object. Alias of the process-wide instance; it is created on first use.
+ (instancetype)sharedInstance;

#pragma mark Input

/// Touch events from the game view (only forwarded while a session is running).
- (void)forwardTouchEvent:(UIEvent *)event NS_SWIFT_NAME(forwardTouchEvent(_:));
/// Virtual pad button press and release for a 0-based player.
- (void)buttonDown:(LibretroButton)button forPlayer:(unsigned)player NS_SWIFT_NAME(buttonDown(_:forPlayer:));
- (void)buttonUp:(LibretroButton)button forPlayer:(unsigned)player NS_SWIFT_NAME(buttonUp(_:forPlayer:));
/// Analog stick position, both axes in -1...1 (up and right are positive). `left` picks the left stick.
- (void)tiltStickLeft:(BOOL)left horizontal:(CGFloat)x vertical:(CGFloat)y forPlayer:(unsigned)player
    NS_SWIFT_NAME(tiltStick(left:horizontal:vertical:forPlayer:));
/// Touch-screen pointer (melonDS DS, Azahar): a press at a point, then its release.
- (void)pointerDownAtX:(CGFloat)x y:(CGFloat)y NS_SWIFT_NAME(pointerDown(x:y:));
- (void)pointerUp NS_SWIFT_NAME(pointerUp());
/// PlayStation pad analog mode on or off.
- (void)setPlayStationAnalogMode:(BOOL)analog NS_SWIFT_NAME(setPlayStationAnalogMode(_:));
- (void)setEnableRumble:(BOOL)enable;
- (BOOL)getSensorEnable:(int)playerIndex;

#pragma mark Options

/// Sets one core option of a named core; `shouldReload` restarts the content so the core re-reads it.
- (void)applyToCore:(NSString *)coreName option:(NSString *)key value:(NSString *)value shouldReload:(BOOL)reload
    NS_SWIFT_NAME(apply(toCore:option:value:shouldReload:));
/// Sets several options of a named core at once.
- (void)applyToCore:(NSString *)coreName options:(NSDictionary<NSString *, NSString *> * _Nullable)options shouldReload:(BOOL)reload
    NS_SWIFT_NAME(apply(toCore:options:shouldReload:));
/// Applies option values to the core that is running now (no restart).
- (void)applyLiveOptions:(NSDictionary<NSString *, NSString *> * _Nullable)options flush:(BOOL)flush
    NS_SWIFT_NAME(applyLiveOptions(_:flush:));
/// Frontend (retroarch.cfg) settings.
- (void)setFrontendSetting:(NSString *)key value:(NSString *)value NS_SWIFT_NAME(setFrontendSetting(_:value:));
- (void)updateLibretroConfigs:(NSDictionary<NSString *, NSString *> *)configs;
- (NSString *)coreConfigValue:(NSString *)coreName key:(NSString *)key;
- (NSString *)libretroConfigValue:(NSString *)key;
/// Tells the running core that its option list changed.
- (void)markCoreOptionsDirty NS_SWIFT_NAME(markCoreOptionsDirty());
- (void)setReloadDelay:(double)delay;
- (void)setCustomSaveExtension:(NSString * _Nullable)customSaveExtension;

#pragma mark Discs

/// Selects a disc of a multi-disc game.
- (void)selectDisc:(unsigned)index delayed:(BOOL)delayed NS_SWIFT_NAME(selectDisc(_:delayed:));
- (NSUInteger)selectedDiscIndex NS_SWIFT_NAME(selectedDiscIndex());
- (NSUInteger)discCount NS_SWIFT_NAME(discCount());

#pragma mark Cheats

/// Sets or updates one cheat slot (the code text is passed to the core as given).
- (void)setCheat:(NSString *)code atIndex:(unsigned)index enabled:(BOOL)enabled NS_SWIFT_NAME(setCheat(_:atIndex:enabled:));

#pragma mark Content

/// Loads a game with a core. The completion receives the core's reply (nil when there is none).
/// Returns NO when the load could not be started.
- (BOOL)openContent:(NSString *)contentPath withCore:(NSString *)corePath
         completion:(void (^ _Nullable)(NSDictionary * _Nullable))completion
    NS_SWIFT_NAME(openContent(_:withCore:completion:));
/// Loads a game through libretro retro_load_game_special. `subsystem` must be registered by the core
/// (melonDS DS: "gba" = NDS ROM, GBA ROM, GBA save; "gbanosav" = NDS ROM, GBA ROM, in that order).
/// Returns NO when the core lacks the subsystem, the load fails or RetroArch falls back to the dummy core.
- (BOOL)openSubsystem:(NSString *)subsystem contentPaths:(NSArray<NSString *> *)contentPaths withCore:(NSString *)corePath
           completion:(void (^ _Nullable)(NSDictionary * _Nullable))completion
    NS_SWIFT_NAME(openSubsystem(_:contentPaths:withCore:completion:));
/// Starts a core that runs without content.
- (void)openCoreWithoutContent:(NSString *)corePath NS_SWIFT_NAME(openCoreWithoutContent(_:));
- (void)reload;
- (void)reloadByKeepState:(BOOL)keepState;

#pragma mark Session and state

/// Starts a RetroArch session and returns the view controller that renders it.
/// `saveDirectory` (nullable) is where this game keeps save RAM.
- (UIViewController *)beginSessionWithSaveDirectory:(NSString * _Nullable)saveDirectory NS_SWIFT_NAME(beginSession(saveDirectory:));
- (void)pauseSession NS_SWIFT_NAME(pauseSession());
- (void)resumeSession NS_SWIFT_NAME(resumeSession());
- (void)endSession NS_SWIFT_NAME(endSession());
/// Save and restore states. For loadState: YES means the request was accepted, not that the state is valid.
- (BOOL)saveState:(void (^ _Nullable)(NSString * _Nullable path))completion;
- (BOOL)saveStateAsyncControlled:(void (^ _Nullable)(NSString * _Nullable path))completion;
- (BOOL)loadState:(NSString *)path;
- (void)snapshot:(void (^)(UIImage *))completion;
/// YES = audio on (the name is historical).
- (void)mute:(BOOL)mute;
- (void)fastForward:(float)rate;
- (void)setRespectSilentMode:(BOOL)respect;
/// Forgets the text of the last core message.
- (void)discardLatestCoreMessage NS_SWIFT_NAME(discardLatestCoreMessage());

/// Last RETRO_ENVIRONMENT_SET_MESSAGE text of a core, unmodified; nil when none.
@property (nonatomic, copy, readonly, nullable) NSString *latestCoreMessage;
/// Root folder of the libretro workspace.
@property (nonatomic, copy, nullable) NSString *workspaceRoot;

- (void)resetCheatCode;

// Screen layout (melonDS DS, Azahar) and NDS network
/// Value of core option gamuroid_screen_layout ("L1;canvas=WxH;upper=x,y,w,h|none;lower=...[;rev=n]"), nil clears.
/// Set it before start; stop clears it. A repeated identical value does nothing.
- (void)setScreenLayout:(NSString * _Nullable)layout;
/// Answer for melonds_firmware_wfc_dns; nil or empty clears it (the option store value is used).
- (void)setNDSWFCDNS:(NSString * _Nullable)dns;
/// After a melonDS DS load: post DidConnectToWFCNotification when the core reports online (2) and
/// DidDisconnectFromWFCNotification on every other change. Stop ends it. No-op for cores without the exports.
- (void)startWFCStatusMonitor;

// Diagnostics
- (void)setLibretroLogMonitor:(BOOL)enabled;

// Azahar software keyboard
- (void)registerAzaharKeyboard:(void(^ _Nullable)(LibretroAzaharKeyboardConfig *_Nonnull config))callback;
- (void)registerAzaharKeyboardErrorCallback:(void(^ _Nullable)(int errorCode, NSString *_Nonnull message))callback;
- (void)inputAzaharKeyboard:(NSString * _Nullable)text buttonIndex:(int)buttonIndex;
- (void)cancelAzaharKeyboard;

@end

NS_ASSUME_NONNULL_END
