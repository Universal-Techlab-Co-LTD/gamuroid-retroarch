/*  RetroArch - A frontend for libretro.
 *  Copyright (C) 2025      - Joseph Mattiello
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

#include <TargetConditionals.h>
#include <Foundation/Foundation.h>
#include <AVFoundation/AVFoundation.h>
#include <libretro.h>
#include <os/lock.h>
#include "../camera/camera_driver.h"
#include "../verbosity.h"
/// For image scaling and color space DSP
#import <Accelerate/Accelerate.h>
#if TARGET_OS_IOS
/// For camera rotation detection
#import <UIKit/UIKit.h>
#endif

// TODO: Add an API to retroarch to allow selection of camera
#ifndef CAMERA_PREFER_FRONTFACING
#define CAMERA_PREFER_FRONTFACING 1  /// Default to front camera
#endif

#ifndef CAMERA_MIRROR_FRONT_CAMERA
#define CAMERA_MIRROR_FRONT_CAMERA 1
#endif

@interface AVCameraManager : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate> {
    // os_unfair_lock guards pointer swap between delegate (sample queue) and poll
    // (main run loop). Lock held only for pointer copy / swap — never during
    // vImage conversion or frame_raw_cb delivery.
    os_unfair_lock _bufferLock;
#if TARGET_OS_IOS
    // Phase F: dynamic camera orientation tracking. lastValidOrientation holds the
    // most recent valid UIDeviceOrientation (portrait / portraitUpsideDown /
    // landscapeLeft / landscapeRight) so that faceUp / faceDown / unknown moments
    // (phone flat on table, undocked, etc.) keep the previously-applied rotation
    // instead of resetting it. orientationObserver retains the
    // UIDeviceOrientationDidChangeNotification subscription token so we can
    // remove it on teardown / re-setup.
    UIDeviceOrientation _lastValidOrientation;
    id<NSObject> _orientationObserver;
#endif
}
@property (strong, nonatomic) AVCaptureSession *session;
@property (strong, nonatomic) AVCaptureDeviceInput *input;
@property (strong, nonatomic) AVCaptureVideoDataOutput *output;
// Double-buffered XRGB8888 frame storage. Delegate writes into backFrameBuffer,
// then atomically swaps front↔back under _bufferLock. Poll reads frontFrameBuffer
// under the same lock (pointer copy only). Both allocated calloc'd at init so
// first poll before any delegate callback returns a legitimate BLACK frame
// (0x00000000 XRGB), never color bars or uninitialised memory.
@property (assign) uint32_t *frontFrameBuffer;
@property (assign) uint32_t *backFrameBuffer;
@property (assign) BOOL hasValidFrame;
@property (assign) size_t width;
@property (assign) size_t height;

- (bool)setupCameraSession;
- (void)lockBuffers;
- (void)unlockBuffers;
#if TARGET_OS_IOS
- (void)applyCurrentDeviceRotation;
#endif
@end

@implementation AVCameraManager

+ (AVCameraManager *)sharedInstance {
    static AVCameraManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AVCameraManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _bufferLock = OS_UNFAIR_LOCK_INIT;
        _hasValidFrame = NO;
#if TARGET_OS_IOS
        _lastValidOrientation = UIDeviceOrientationPortrait;  // safe default before first notification
        _orientationObserver = nil;
#endif
    }
    return self;
}

- (void)lockBuffers   { os_unfair_lock_lock(&_bufferLock);   }
- (void)unlockBuffers { os_unfair_lock_unlock(&_bufferLock); }

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool {
        // Read the buffers and their size once, under the lock, and use only
        // these copies below: avfoundation_free/avfoundation_init replace them on
        // main while this callback runs. avfoundation_free releases the old
        // buffers on this serial queue, so they stay valid until we return.
        [self lockBuffers];
        uint32_t *backBuffer  = self.backFrameBuffer;
        uint32_t *frontBuffer = self.frontFrameBuffer;
        size_t dstWidth       = self.width;
        size_t dstHeight      = self.height;
        [self unlockBuffers];

        // Delegate writes into backFrameBuffer. Need both allocated.
        if (!backBuffer || !frontBuffer)
            return;

        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (!imageBuffer) {
            RARCH_ERR("[Camera]: Failed to get image buffer\n");
            return;
        }

        CVPixelBufferLockBaseAddress(imageBuffer, 0);

        size_t sourceWidth = CVPixelBufferGetWidth(imageBuffer);
        size_t sourceHeight = CVPixelBufferGetHeight(imageBuffer);
        OSType pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer);

#ifdef DEBUG
        RARCH_LOG("[Camera]: Processing frame %zux%zu format: %u\n", sourceWidth, sourceHeight, (unsigned int)pixelFormat);
#endif
        // Create intermediate buffer for full-size converted image
        uint32_t *intermediateBuffer = (uint32_t*)malloc(sourceWidth * sourceHeight * 4);
        if (!intermediateBuffer) {
            RARCH_ERR("[Camera]: Failed to allocate intermediate buffer\n");
            CVPixelBufferUnlockBaseAddress(imageBuffer, 0);
            return;
        }

        vImage_Buffer srcBuffer = {}, intermediateVBuffer = {}, dstBuffer = {};
        vImage_Error err = kvImageNoError;

        // Setup intermediate buffer
        intermediateVBuffer.data = intermediateBuffer;
        intermediateVBuffer.width = sourceWidth;
        intermediateVBuffer.height = sourceHeight;
        intermediateVBuffer.rowBytes = sourceWidth * 4;

        // Setup destination buffer
        // Delegate fills backFrameBuffer, NOT frontFrameBuffer (which poll reads).
        dstBuffer.data = backBuffer;
        dstBuffer.width = dstWidth;
        dstBuffer.height = dstHeight;
        dstBuffer.rowBytes = dstWidth * 4;

        // Convert source format to RGBA
        switch (pixelFormat) {
            case kCVPixelFormatType_32BGRA: {
                srcBuffer.data = CVPixelBufferGetBaseAddress(imageBuffer);
                srcBuffer.width = sourceWidth;
                srcBuffer.height = sourceHeight;
                srcBuffer.rowBytes = CVPixelBufferGetBytesPerRow(imageBuffer);

                // libretro camera contract: XRGB8888 native-endian = memory bytes
                // B, G, R, X. iOS CVPixelBuffer kCVPixelFormatType_32BGRA is
                // already memory bytes B, G, R, A — identity permute keeps byte
                // order. A previous {2,1,0,3} map flipped to RGBA and caused the
                // blue-tint bug (R↔B swap) visible in Tomodachi Life.
                uint8_t permuteMap[4] = {0, 1, 2, 3}; // BGRA pass-through (=XRGB LE)
                err = vImagePermuteChannels_ARGB8888(&srcBuffer, &intermediateVBuffer, permuteMap, kvImageNoFlags);
                break;
            }

            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: {
                // YUV to RGB conversion
                vImage_Buffer srcY = {}, srcCbCr = {};

                srcY.data = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0);
                srcY.width = sourceWidth;
                srcY.height = sourceHeight;
                srcY.rowBytes = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0);

                srcCbCr.data = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 1);
                srcCbCr.width = sourceWidth / 2;
                srcCbCr.height = sourceHeight / 2;
                srcCbCr.rowBytes = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 1);

                vImage_YpCbCrToARGB info;
                vImage_YpCbCrPixelRange pixelRange =
                    (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) ?
                        (vImage_YpCbCrPixelRange){16, 128, 235, 240} :  // Video range
                        (vImage_YpCbCrPixelRange){0, 128, 255, 255};    // Full range

                err = vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_601_4,
                                                                   &pixelRange,
                                                                   &info,
                                                                   kvImage420Yp8_CbCr8,
                                                                   kvImageARGB8888,
                                                                   kvImageNoFlags);

                if (err == kvImageNoError) {
                    /* One pass: the vImage output is ARGB (channel 0 = alpha); the map below makes
                     * the memory byte order B, G, R, A, which is libretro XRGB8888 on a
                     * little-endian CPU. */
                    const uint8_t toBGRA[4] = {3, 2, 1, 0};
                    err = vImageConvert_420Yp8_CbCr8ToARGB8888(&srcY, &srcCbCr, &intermediateVBuffer,
                                                               &info, toBGRA, 255, kvImageNoFlags);
                }
                break;
            }

            default:
                RARCH_ERR("[Camera]: Unsupported pixel format: %u\n", (unsigned int)pixelFormat);
                free(intermediateBuffer);
                CVPixelBufferUnlockBaseAddress(imageBuffer, 0);
                return;
        }

        if (err != kvImageNoError) {
            RARCH_ERR("[Camera]: Error converting color format: %ld\n", err);
            free(intermediateBuffer);
            CVPixelBufferUnlockBaseAddress(imageBuffer, 0);
            return;
        }

        // Rotation + mirror handled by AVCaptureConnection at capture time
        // (see setupCameraSession). Delegate just treats intermediateVBuffer
        // as the source for scale/crop — no vImageRotate90, no vImageReflect,
        // no per-frame allocation for rotation/mirror buffers.
        //
        // NOTE: `rotatedBuffer` kept as a reference (not a fresh allocation)
        // so the rest of the pipeline (scaling / cropping) stays the same.
        // Cleanup below does NOT free rotatedBuffer.data because it aliases
        // intermediateBuffer (freed separately).
        vImage_Buffer rotatedBuffer = intermediateVBuffer;

        // Calculate aspect fill scaling
        float sourceAspect = (float)rotatedBuffer.width / rotatedBuffer.height;
        float targetAspect = (float)dstWidth / dstHeight;

        vImage_Buffer scaledBuffer = {};
        size_t scaledWidth, scaledHeight;

        if (sourceAspect > targetAspect) {
            // Source is wider - scale to match height
            scaledHeight = dstHeight;
            scaledWidth = (size_t)(dstHeight * sourceAspect);
        } else {
            // Source is taller - scale to match width
            scaledWidth = dstWidth;
            scaledHeight = (size_t)(dstWidth / sourceAspect);
        }

        RARCH_LOG("[Camera]: Aspect fill scaling from %zux%zu to %zux%zu\n",
                  rotatedBuffer.width, rotatedBuffer.height, scaledWidth, scaledHeight);

        scaledBuffer.data = malloc(scaledWidth * scaledHeight * 4);
        if (!scaledBuffer.data) {
            RARCH_ERR("[Camera]: Failed to allocate scaled buffer\n");
            // rotatedBuffer aliases intermediateBuffer; one free covers both.
            free(intermediateBuffer);
            CVPixelBufferUnlockBaseAddress(imageBuffer, 0);
            return;
        }

        scaledBuffer.width = scaledWidth;
        scaledBuffer.height = scaledHeight;
        scaledBuffer.rowBytes = scaledWidth * 4;

        // Scale maintaining aspect ratio
        err = vImageScale_ARGB8888(&rotatedBuffer, &scaledBuffer, NULL, kvImageHighQualityResampling);

        if (err != kvImageNoError) {
            RARCH_ERR("[Camera]: Error scaling image: %ld\n", err);
            free(scaledBuffer.data);
            // rotatedBuffer aliases intermediateBuffer; one free covers both.
            free(intermediateBuffer);
            CVPixelBufferUnlockBaseAddress(imageBuffer, 0);
            return;
        }

        // Center crop the scaled image into the destination buffer
        size_t xOffset = (scaledWidth > dstWidth) ? (scaledWidth - dstWidth) / 2 : 0;
        size_t yOffset = (scaledHeight > dstHeight) ? (scaledHeight - dstHeight) / 2 : 0;

        // Copy the centered portion to the BACK buffer (delegate owns it).
        uint32_t *srcPtr = (uint32_t *)scaledBuffer.data;
        uint32_t *dstPtr = backBuffer;

        for (size_t y = 0; y < dstHeight; y++) {
            memcpy(dstPtr + y * dstWidth,
                   srcPtr + (y + yOffset) * scaledWidth + xOffset,
                   dstWidth * 4);
        }

        // Clean up intermediate allocations BEFORE the swap so we never hold
        // them across a potential lock. rotatedBuffer aliases intermediateBuffer
        // — free only once via intermediateBuffer.
        free(scaledBuffer.data);
        free(intermediateBuffer);
        CVPixelBufferUnlockBaseAddress(imageBuffer, 0);

        // Atomic front↔back swap. Lock held only for pointer exchange (< 1 µs);
        // no vImage work, no callbacks, no allocations. If the buffers were
        // detached or replaced meanwhile (camera freed), drop this frame.
        [self lockBuffers];
        if (self.backFrameBuffer == backBuffer && self.frontFrameBuffer == frontBuffer) {
            self.frontFrameBuffer = backBuffer;
            self.backFrameBuffer  = frontBuffer;
            self.hasValidFrame    = YES;
        }
        [self unlockBuffers];
    } // End of autorelease pool
}

- (AVCaptureDevice *)selectCameraDevice {
    RARCH_LOG("[Camera]: Selecting camera device\n");

    NSArray<AVCaptureDevice *> *devices;

#if TARGET_OS_OSX
    // On macOS, use default discovery method
    // Could probably due the same as iOS but need to test.
    devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
#else
    // On iOS/tvOS use modern discovery session
    NSArray<AVCaptureDeviceType> *deviceTypes;
    if (@available(iOS 17.0, *)) {
        deviceTypes = @[
            AVCaptureDeviceTypeExternal,
            AVCaptureDeviceTypeBuiltInWideAngleCamera,
            AVCaptureDeviceTypeBuiltInTelephotoCamera,
            AVCaptureDeviceTypeBuiltInUltraWideCamera,
            //        AVCaptureDeviceTypeBuiltInDualCamera,
            //        AVCaptureDeviceTypeBuiltInDualWideCamera,
            //        AVCaptureDeviceTypeBuiltInTripleCamera,
            //        AVCaptureDeviceTypeBuiltInTrueDepthCamera,
            //        AVCaptureDeviceTypeBuiltInLiDARDepthCamera,
            //        AVCaptureDeviceTypeContinuityCamera,
        ];
    } else {
        deviceTypes = @[
            AVCaptureDeviceTypeBuiltInWideAngleCamera,
            AVCaptureDeviceTypeBuiltInTelephotoCamera,
            AVCaptureDeviceTypeBuiltInUltraWideCamera,
            //        AVCaptureDeviceTypeBuiltInDualCamera,
            //        AVCaptureDeviceTypeBuiltInDualWideCamera,
            //        AVCaptureDeviceTypeBuiltInTripleCamera,
            //        AVCaptureDeviceTypeBuiltInTrueDepthCamera,
            //        AVCaptureDeviceTypeBuiltInLiDARDepthCamera,
            //        AVCaptureDeviceTypeContinuityCamera,
        ];
    }
    AVCaptureDeviceDiscoverySession *discoverySession = [AVCaptureDeviceDiscoverySession
                                                         discoverySessionWithDeviceTypes:deviceTypes
                                                         mediaType:AVMediaTypeVideo
                                                         position:AVCaptureDevicePositionUnspecified];

    devices = discoverySession.devices;
#endif

    if (devices.count == 0) {
        RARCH_ERR("[Camera]: No camera devices found\n");
        return nil;
    }

    // Log available devices
    for (AVCaptureDevice *device in devices) {
        RARCH_LOG("[Camera]: Found device: %s - Position: %d\n",
                  [device.localizedName UTF8String],
                  (int)device.position);
    }

#if TARGET_OS_OSX
    // macOS: Just use the first available camera if only one exists
    if (devices.count == 1) {
        RARCH_LOG("[Camera]: Using only available camera: %s\n",
                  [devices.firstObject.localizedName UTF8String]);
        return devices.firstObject;
    }

    // Try to match by name for built-in cameras
    for (AVCaptureDevice *device in devices) {
        BOOL isFrontFacing = [device.localizedName containsString:@"FaceTime"] ||
                            [device.localizedName containsString:@"Front"];
        if (CAMERA_PREFER_FRONTFACING == isFrontFacing) {
            RARCH_LOG("[Camera]: Selected macOS camera: %s\n",
                      [device.localizedName UTF8String]);
            return device;
        }
    }
#else
    // iOS: Use position property
    AVCaptureDevicePosition preferredPosition = CAMERA_PREFER_FRONTFACING ?
        AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;

    // Try to find preferred camera
    for (AVCaptureDevice *device in devices) {
        if (device.position == preferredPosition) {
            RARCH_LOG("[Camera]: Selected iOS camera position: %d\n",
                      (int)preferredPosition);
            return device;
        }
    }
#endif

    // Fallback to first available camera
    RARCH_LOG("[Camera]: Using fallback camera: %s\n",
              [devices.firstObject.localizedName UTF8String]);
    return devices.firstObject;
}

- (bool)setupCameraSession {
    // Initialize capture session
    self.session = [[AVCaptureSession alloc] init];

    // Get camera device
    AVCaptureDevice *device = [self selectCameraDevice];
    if (!device) {
        RARCH_ERR("[Camera]: No camera device found\n");
        return false;
    }

    // Create device input
    NSError *error = nil;
    self.input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (error) {
        RARCH_ERR("[Camera]: Failed to create device input: %s\n",
                  [error.localizedDescription UTF8String]);
        return false;
    }

    if ([self.session canAddInput:self.input]) {
        [self.session addInput:self.input];
        RARCH_LOG("[Camera]: Added camera input to session\n");
    }

    // Create and configure video output
    self.output = [[AVCaptureVideoDataOutput alloc] init];
    self.output.videoSettings = @{
        (NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };
    // Deliver sample buffers on a dedicated background queue so the capture
    // pipeline never contends with the main run loop.
    static dispatch_queue_t sample_queue;
    static dispatch_once_t sample_queue_once;
    dispatch_once(&sample_queue_once, ^{
        sample_queue = dispatch_queue_create("com.libretro.camera.avfoundation.sample",
                                              DISPATCH_QUEUE_SERIAL);
    });
    [self.output setSampleBufferDelegate:self queue:sample_queue];

    if ([self.session canAddOutput:self.output]) {
        [self.session addOutput:self.output];
        RARCH_LOG("[Camera]: Added video output to session\n");
    }

#if TARGET_OS_IOS
    // Phase F (2026-04-26): dynamic camera orientation tracking.
    //
    // Earlier behavior set videoRotationAngle = 90 (portrait) ONCE in this
    // function. That worked when the user held the phone in portrait but failed
    // when the user physically rotated the device (3DS game UI is portrait-
    // locked, so the game frame stays portrait, but the camera output stayed
    // pinned to portrait coordinates → captured face appeared tilted).
    //
    // Now: subscribe to UIDeviceOrientationDidChangeNotification and recompute
    // the connection rotation each time the device orientation changes. Hold
    // the last-known-good rotation when UIDevice.orientation is Unknown /
    // FaceUp / FaceDown (phone flat on table) so a brief flat moment doesn't
    // reset rotation. videoMirrored = YES for the front camera stays unchanged
    // across orientation flips (selfie-mirror semantics).
    //
    // applyCurrentDeviceRotation() does the work; we just register the
    // observer and bootstrap with the current orientation.
    AVCaptureConnection *conn = [self.output connectionWithMediaType:AVMediaTypeVideo];
    if (conn) {
        const BOOL isFront = (self.input && self.input.device &&
                              self.input.device.position == AVCaptureDevicePositionFront);
        BOOL mirrored = NO;
        if (isFront && conn.supportsVideoMirroring) {
            conn.videoMirrored = YES;
            mirrored = YES;
        }
        RARCH_LOG("[Camera]: configured connection mirrored=%s (front=%s); rotation handled dynamically\n",
                  mirrored ? "YES" : "NO", isFront ? "YES" : "NO");
    } else {
        RARCH_ERR("[Camera]: Could not obtain video capture connection; frames may be wrong orientation\n");
    }

    // Remove any prior observer (setupCameraSession can be called more than
    // once across game sessions on this singleton manager).
    if (_orientationObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_orientationObserver];
        _orientationObserver = nil;
    }
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    __weak typeof(self) weakSelf = self;
    _orientationObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIDeviceOrientationDidChangeNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification * _Nonnull note) {
                    [weakSelf applyCurrentDeviceRotation];
                }];
    [self applyCurrentDeviceRotation];  // bootstrap with whatever orientation iOS reports right now
#endif

    return true;
}

#if TARGET_OS_IOS
// Phase F: dynamic camera orientation. Called on every UIDevice orientation
// change (and once at session start to bootstrap). Maps the four valid
// UIDeviceOrientation cases to AVCaptureConnection rotation; faceUp/faceDown/
// unknown re-uses the last valid orientation so a phone-flat moment doesn't
// reset to portrait. front-camera videoMirrored is unchanged here (set once
// in setupCameraSession; selfie-mirror semantics survive orientation flips).
- (void)applyCurrentDeviceRotation {
    UIDeviceOrientation cur = [[UIDevice currentDevice] orientation];
    if (UIDeviceOrientationIsValidInterfaceOrientation(cur))
        _lastValidOrientation = cur;
    else
        cur = _lastValidOrientation;

    AVCaptureConnection *conn = [self.output connectionWithMediaType:AVMediaTypeVideo];
    if (!conn) return;

    if (@available(iOS 17.0, *)) {
        CGFloat angle;
        switch (cur) {
            case UIDeviceOrientationPortrait:           angle =  90; break;
            case UIDeviceOrientationPortraitUpsideDown: angle = 270; break;
            case UIDeviceOrientationLandscapeLeft:      angle =   0; break;
            case UIDeviceOrientationLandscapeRight:     angle = 180; break;
            default:                                    angle =  90; break;
        }
        if ([conn isVideoRotationAngleSupported:angle]) {
            conn.videoRotationAngle = angle;
            RARCH_LOG("[Camera]: orientation -> videoRotationAngle=%.0f (UIDeviceOrientation=%ld)\n",
                      (double)angle, (long)cur);
        }
    } else {
        if (conn.supportsVideoOrientation) {
            // NOTE: UIDeviceOrientation.landscapeLeft maps to
            // AVCaptureVideoOrientation.landscapeRight (Apple enum naming
            // inversion). See AVCaptureVideoOrientation docs.
            AVCaptureVideoOrientation o;
            switch (cur) {
                case UIDeviceOrientationPortrait:           o = AVCaptureVideoOrientationPortrait;           break;
                case UIDeviceOrientationPortraitUpsideDown: o = AVCaptureVideoOrientationPortraitUpsideDown; break;
                case UIDeviceOrientationLandscapeLeft:      o = AVCaptureVideoOrientationLandscapeRight;     break;
                case UIDeviceOrientationLandscapeRight:     o = AVCaptureVideoOrientationLandscapeLeft;      break;
                default:                                    o = AVCaptureVideoOrientationPortrait;           break;
            }
            conn.videoOrientation = o;
            RARCH_LOG("[Camera]: orientation -> videoOrientation=%ld (UIDeviceOrientation=%ld)\n",
                      (long)o, (long)cur);
        }
    }
}
#endif

- (void)dealloc {
#if TARGET_OS_IOS
    if (_orientationObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_orientationObserver];
        _orientationObserver = nil;
    }
    [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
#endif
}

@end

typedef struct
{
    AVCameraManager *manager;
    unsigned width;
    unsigned height;
} avfoundation_t;

static void generateColorBars(uint32_t *buffer, size_t width, size_t height) {
    const uint32_t colors[] = {
        0xFFFFFFFF,  // White
        0xFFFFFF00,  // Yellow
        0xFF00FFFF,  // Cyan
        0xFF00FF00,  // Green
        0xFFFF00FF,  // Magenta
        0xFFFF0000,  // Red
        0xFF0000FF,  // Blue
        0xFF000000   // Black
    };

    size_t barWidth = width / 8;
    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            size_t colorIndex = x / barWidth;
            buffer[y * width + x] = colors[colorIndex];
        }
    }
}

static void *avfoundation_init(const char *device, uint64_t caps,
                             unsigned width, unsigned height)
{
    RARCH_LOG("[Camera]: Initializing AVFoundation camera %ux%u\n", width, height);

    avfoundation_t *avf = (avfoundation_t*)calloc(1, sizeof(avfoundation_t));
    if (!avf) {
        RARCH_ERR("[Camera]: Failed to allocate avfoundation_t\n");
        return NULL;
    }

    avf->manager = [AVCameraManager sharedInstance];
    avf->width = width;
    avf->height = height;
    avf->manager.width = width;
    avf->manager.height = height;

    // Synchronous permission check — NEVER call requestAccess here. Permission request
    // is done in Swift layer (DetailGameVC preflightRuntimePermissionsIfNeeded at viewDidAppear)
    // BEFORE the core is launched. If we reach here without authorization, fail init
    // cleanly so camera_st->data stays NULL and driver_camera_start silent-returns
    // (blank frames), without racing an async completion handler's free() against
    // the caller using avf.
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    RARCH_LOG("[Camera]: authorizationStatus=%d (authorized=%d) thread=%s\n",
              (int)status, (int)AVAuthorizationStatusAuthorized,
              [NSThread isMainThread] ? "main" : "bg");
    if (status != AVAuthorizationStatusAuthorized) {
        RARCH_ERR("[Camera]: Camera access not authorized (status=%d); failing init.\n", (int)status);
        free(avf);
        return NULL;
    }

    // Allocate double-buffered XRGB storage. calloc → all zeros = BLACK XRGB.
    // Guarantees first poll before any delegate frame returns black (not color
    // bars, not zero-YUV green).
    avf->manager.frontFrameBuffer = (uint32_t*)calloc(width * height, sizeof(uint32_t));
    avf->manager.backFrameBuffer  = (uint32_t*)calloc(width * height, sizeof(uint32_t));
    if (!avf->manager.frontFrameBuffer || !avf->manager.backFrameBuffer) {
        RARCH_ERR("[Camera]: Failed to allocate frame buffers\n");
        if (avf->manager.frontFrameBuffer) { free(avf->manager.frontFrameBuffer); avf->manager.frontFrameBuffer = NULL; }
        if (avf->manager.backFrameBuffer)  { free(avf->manager.backFrameBuffer);  avf->manager.backFrameBuffer  = NULL; }
        free(avf);
        return NULL;
    }
    avf->manager.hasValidFrame = NO;

    // Setup capture session synchronously on the main thread — this only
    // constructs AVCaptureSession + wires inputs/outputs, no hardware I/O.
    // Session start is NOT fired here (single owner: avfoundation_start).
    __block bool setupSuccess = false;

    if ([NSThread isMainThread]) {
        @autoreleasepool {
            setupSuccess = [avf->manager setupCameraSession];
        }
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            @autoreleasepool {
                setupSuccess = [avf->manager setupCameraSession];
            }
        });
    }

    if (!setupSuccess) {
        RARCH_ERR("[Camera]: Failed to setup camera\n");
        free(avf->manager.frontFrameBuffer); avf->manager.frontFrameBuffer = NULL;
        free(avf->manager.backFrameBuffer);  avf->manager.backFrameBuffer  = NULL;
        free(avf);
        return NULL;
    }

    RARCH_LOG("[Camera]: AVFoundation camera init setup OK; awaiting avfoundation_start.\n");
    return avf;
}

static void avfoundation_free(void *data)
{
    avfoundation_t *avf = (avfoundation_t*)data;
    if (!avf)
        return;

    RARCH_LOG("[Camera]: Freeing AVFoundation camera\n");

    // stopRunning below is asynchronous, so the session keeps delivering frames
    // for a while. Detach the delegate first; a callback that is already queued
    // finds NULL buffers (detached below) and returns.
    AVCameraManager *mgr = avf->manager;
    dispatch_queue_t sampleQueue = mgr.output.sampleBufferCallbackQueue;
    [mgr.output setSampleBufferDelegate:nil queue:NULL];

    if (avf->manager.session) {
        // stopRunning is long-blocking; dispatch to avoid stalling the caller
        // (runloop / teardown path runs on main thread).
        AVCaptureSession *session = avf->manager.session;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [session stopRunning];
        });
    }

    [mgr lockBuffers];
    uint32_t *frontBuffer = mgr.frontFrameBuffer;
    uint32_t *backBuffer  = mgr.backFrameBuffer;
    mgr.frontFrameBuffer = NULL;
    mgr.backFrameBuffer  = NULL;
    mgr.hasValidFrame    = NO;
    [mgr unlockBuffers];

    // A callback that is running right now still writes into backBuffer. The
    // sample queue is serial, so freeing on it waits until that callback has
    // returned (no wait on main). Without a queue no callback was ever set up.
    if (sampleQueue) {
        dispatch_async(sampleQueue, ^{
            free(frontBuffer);
            free(backBuffer);
        });
    } else {
        free(frontBuffer);
        free(backBuffer);
    }

    free(avf);
    RARCH_LOG("[Camera]: AVFoundation camera freed\n");
}

static void avfoundation_stop(void *data)
{
    avfoundation_t *avf = (avfoundation_t*)data;
    if (!avf || !avf->manager.session)
        return;

    RARCH_LOG("[Camera]: Stopping AVFoundation camera\n");

    AVCaptureSession *session = avf->manager.session;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [session stopRunning];
        RARCH_LOG("[Camera]: Camera session stopped on background thread\n");
    });
}

static bool avfoundation_start(void *data)
{
    avfoundation_t *avf = (avfoundation_t*)data;
    if (!avf || !avf->manager.session) {
        RARCH_ERR("[Camera]: Cannot start - invalid data\n");
        return false;
    }

    RARCH_LOG("[Camera]: Starting AVFoundation camera\n");

    // Dispatch startRunning to a background queue — it is long-blocking on
    // iOS (hardware open + permission prompt on first call). NEVER usleep
    // on main to poll isRunning; return success immediately and let
    // avfoundation_poll detect the first real frame.
    AVCaptureSession *session = avf->manager.session;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [session startRunning];
        RARCH_LOG("[Camera]: Camera session started on background thread\n");
    });

    return true;
}

static bool avfoundation_poll(void *data,
      retro_camera_frame_raw_framebuffer_t frame_raw_cb,
      retro_camera_frame_opengl_texture_t frame_gl_cb)
{
    avfoundation_t *avf = (avfoundation_t*)data;
    if (!avf || !frame_raw_cb) {
        RARCH_ERR("[Camera]: Cannot poll - invalid data or callback\n");
        return false;
    }

    AVCameraManager *mgr = avf->manager;
    if (!mgr || !mgr.frontFrameBuffer) {
        return false;
    }

    // Snapshot front pointer + validity under the buffer lock. We keep the
    // actual callback invocation OUTSIDE the lock; the front pointer is stable
    // because a swap from the delegate only happens while we are NOT holding
    // it, and the delegate only writes to backFrameBuffer.
    [mgr lockBuffers];
    uint32_t *front = mgr.frontFrameBuffer;
    BOOL valid      = mgr.hasValidFrame;
    [mgr unlockBuffers];

    // First-frame / session-warmup path: deliver a real BLACK XRGB buffer.
    // `front` is calloc'd to 0 at init (XRGB 0x00000000 = black with X
    // ignored), so we never synthesize color bars or uninitialised data.
    // generateColorBars() is compiled out in production; kept only for
    // historical reference.
    if (!valid) {
        static int black_log_count = 0;
        if (black_log_count++ < 3) {
            RARCH_LOG("[Camera:poll] session not ready; delivering black XRGB frame (#%d)\n",
                      black_log_count);
        }
    }

    frame_raw_cb(front, avf->width, avf->height, avf->width * 4);
    return true;
}

camera_driver_t camera_avfoundation = {
   avfoundation_init,
   avfoundation_free,
   avfoundation_start,
   avfoundation_stop,
   avfoundation_poll,
   "avfoundation"
};
