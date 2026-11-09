/*  RetroArch - A frontend for libretro.
 *  Copyright (C) 2025 - Joseph Mattiello
 *
 *  RetroArch is free software: you can redistribute it and/or modify it under the terms
 *  of the GNU General Public License as published by the Free Software Found-
 *  ation, either version 3 of the License, or (at your option) any later version.
 *
 *  Gamuroid changes (base: libretro/RetroArch
 *  PR #17981 as merged in ca405929ad, GPLv3): the driver context owns no microphone,
 *  every open allocates its own microphone record and close releases it; the unit is
 *  started by start_mic only; close restores the game's playback audio category.
 */

#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#include "audio/microphone_driver.h"
#include "queues/fifo_queue.h"
#include "verbosity.h"
#include <memory.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdlib.h>

#include "audio/audio_driver.h"
#include "configuration.h"
#include "../../verbosity.h"

/// One open microphone: created by open_mic, released by close_mic.
typedef struct coreaudio_microphone
{
    AudioUnit audio_unit; /// CoreAudio audio unit
    AudioStreamBasicDescription format; /// Audio format
    fifo_buffer_t *sample_buffer; /// Sample buffer
    bool is_running; /// Whether the microphone is running
    int sample_rate; /// Current sample rate
    bool use_float; /// Whether to use float format
} coreaudio_microphone_t;

/// Driver context: owns no microphone. Kept non-empty so init can return a
/// distinct non-NULL pointer.
typedef struct coreaudio_microphone_driver
{
    unsigned open_count; /// microphones currently open (diagnostic only)
} coreaudio_microphone_driver_t;

#ifdef DEBUG
/* [AUDIO_LIFECYCLE] DEBUG-only leak probe (2026-06-10, T2 audio-churn investigation).
 * Live RemoteIO *input* (mic) AudioUnits. NDS-only (melonDS mic). open_mic creates
 * exactly one on success; close_mic disposes it. MUST return to 0 after an NDS
 * session ends. open/close are serialized on the microphone-driver path. */
static int g_audio_lifecycle_coreaudio_mic_live = 0;
#endif

/// Callback for receiving audio samples
static OSStatus coreaudio_input_callback(
    void *inRefCon,
    AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList *ioData)
{
    coreaudio_microphone_t *microphone = (coreaudio_microphone_t*)inRefCon;
    AudioBufferList bufferList;
    OSStatus status;
    void *tempBuffer = NULL;

    /// Calculate required buffer size
    size_t bufferSize = inNumberFrames * microphone->format.mBytesPerFrame;
    if (bufferSize == 0) {
        RARCH_ERR("[CoreAudio]: Invalid buffer size calculation\n");
        return kAudio_ParamError;
    }

    /// Allocate temporary buffer
    tempBuffer = malloc(bufferSize);
    if (!tempBuffer) {
        RARCH_ERR("[CoreAudio]: Failed to allocate temporary buffer\n");
        return kAudio_MemFullError;
    }

    /// Set up buffer list
    bufferList.mNumberBuffers = 1;
    bufferList.mBuffers[0].mDataByteSize = (UInt32)bufferSize;
    bufferList.mBuffers[0].mData = tempBuffer;

    /// Render audio data
    status = AudioUnitRender(microphone->audio_unit,
                           ioActionFlags,
                           inTimeStamp,
                           inBusNumber,
                           inNumberFrames,
                           &bufferList);

    if (status == noErr) {
        /// Write to FIFO buffer
        fifo_write(microphone->sample_buffer,
                  bufferList.mBuffers[0].mData,
                  bufferList.mBuffers[0].mDataByteSize);
    } else {
        RARCH_ERR("[CoreAudio]: Failed to render audio: %d\n", status);
    }

    /// Clean up temporary buffer
    free(tempBuffer);
    return status;
}

/// Initialize CoreAudio microphone driver
static void *coreaudio_microphone_init(void)
{
    coreaudio_microphone_driver_t *driver =
        (coreaudio_microphone_driver_t*)calloc(1, sizeof(*driver));
    if (!driver)
        RARCH_ERR("[CoreAudio]: Failed to allocate microphone driver\n");
    return driver;
}

/// Free CoreAudio microphone driver. Microphones are closed by RetroArch's generic
/// layer (close_mic) before the driver is freed; nothing here touches them.
static void coreaudio_microphone_free(void *driver_context)
{
    coreaudio_microphone_driver_t *driver = (coreaudio_microphone_driver_t*)driver_context;
    if (!driver)
        return;
    if (driver->open_count != 0)
        RARCH_WARN("[CoreAudio]: Freeing microphone driver with %u microphone(s) still open\n",
                   driver->open_count);
    free(driver);
}

/// Hands over whatever samples are queued, never waiting for more. Returns the byte count
/// (0 = nothing queued yet; the generic microphone layer then supplies silence) or -1 on bad input.
static int coreaudio_pull_queued_samples(void *unused_driver, void *mic_handle,
                                         void *destination, size_t size)
{
    (void)unused_driver;
    coreaudio_microphone_t *mic = (coreaudio_microphone_t *)mic_handle;
    if (mic == NULL || destination == NULL) {
        RARCH_ERR("[CoreAudio]: read called with a missing microphone or buffer\n");
        return -1;
    }

    size_t avail    = FIFO_READ_AVAIL(mic->sample_buffer);
    size_t read_amt = (avail < size) ? avail : size;
    /* Diagnostic — log first few reads to verify frame pipeline. */
    static int coreaudio_mic_read_log_count = 0;
    if (coreaudio_mic_read_log_count < 3) {
        coreaudio_mic_read_log_count++;
        RARCH_LOG("[CoreAudioMic:read#%d] avail=%zu size=%zu read_amt=%zu\n",
                  coreaudio_mic_read_log_count, avail, size, read_amt);
    }

    if (read_amt != 0)
        fifo_read(mic->sample_buffer, destination, read_amt);
    return (int)read_amt;
}

/// Reads never block, so there is no mode to switch.
static void coreaudio_ignore_nonblock_request(void *driver_context, bool nonblock)
{
    (void)driver_context;
    (void)nonblock;
}

#if TARGET_OS_IPHONE
/// Back to the playback category the game uses (same rule as content load in
/// ui_cocoatouch.m): Ambient when RetroArch respects the silent switch, else Playback.
static void coreaudio_microphone_restore_playback_category(void)
{
    settings_t *settings = config_get_ptr();
    bool respect_silent  = !settings || settings->bools.audio_respect_silent_mode;
    NSError *error       = nil;
    AVAudioSessionCategoryOptions options =
        AVAudioSessionCategoryOptionMixWithOthers |
        AVAudioSessionCategoryOptionAllowBluetoothA2DP |
        AVAudioSessionCategoryOptionAllowAirPlay;
    [[AVAudioSession sharedInstance]
        setCategory:respect_silent ? AVAudioSessionCategoryAmbient : AVAudioSessionCategoryPlayback
        withOptions:options
              error:&error];
    if (error)
        RARCH_ERR("[CoreAudio]: Failed to restore audio session category: %s\n",
                  [[error localizedDescription] UTF8String]);
}
#endif

/// Helper method to set audio format
static void coreaudio_microphone_set_format(coreaudio_microphone_t *microphone, bool use_float)
{
    microphone->use_float = use_float; /// Store the format choice
    microphone->format.mSampleRate = microphone->sample_rate;
    microphone->format.mFormatID = kAudioFormatLinearPCM;
    microphone->format.mFormatFlags = use_float ?
        (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked) :
        (kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked);
    microphone->format.mFramesPerPacket = 1;
    microphone->format.mChannelsPerFrame = 1;
    microphone->format.mBitsPerChannel = use_float ? 32 : 16;
    microphone->format.mBytesPerFrame = microphone->format.mChannelsPerFrame * microphone->format.mBitsPerChannel / 8;
    microphone->format.mBytesPerPacket = microphone->format.mBytesPerFrame * microphone->format.mFramesPerPacket;

    RARCH_LOG("[CoreAudio] Format setup: sample_rate=%d, bits=%d, bytes_per_frame=%d\n",
              (int)microphone->format.mSampleRate,
              microphone->format.mBitsPerChannel,
              microphone->format.mBytesPerFrame);
}

/// Open microphone device
static void *coreaudio_microphone_open_mic(void *driver_context,
                                         const char *device,
                                         unsigned rate,
                                         unsigned latency,
                                         unsigned *new_rate)
{
#if TARGET_OS_IPHONE
    /// Sync permission check — NEVER call requestRecordPermission here. Swift
    /// layer (DetailGameVC preflightRuntimePermissionsIfNeeded at viewDidAppear)
    /// requests permission BEFORE core launch. If we reach here without
    /// authorization, fail cleanly so microphone_driver_open_mic returns NULL
    /// → core mic input path trả silence/empty samples.
    AVAudioSessionRecordPermission perm = [[AVAudioSession sharedInstance] recordPermission];
    RARCH_LOG("[CoreAudioMic:perm] status=%d (granted=%d)\n",
              (int)perm, (int)AVAudioSessionRecordPermissionGranted);
    if (perm != AVAudioSessionRecordPermissionGranted) {
        RARCH_ERR("[CoreAudioMic]: recordPermission not granted (status=%d). Failing open.\n",
                  (int)perm);
        return NULL;
    }
#endif

    coreaudio_microphone_driver_t *driver = (coreaudio_microphone_driver_t*)driver_context;
    if (!driver) {
        RARCH_ERR("[CoreAudio]: Invalid driver context\n");
        return NULL;
    }

    coreaudio_microphone_t *microphone = (coreaudio_microphone_t*)calloc(1, sizeof(*microphone));
    if (!microphone) {
        RARCH_ERR("[CoreAudio]: Failed to allocate microphone\n");
        return NULL;
    }

    /// Initialize handle fields
    microphone->sample_rate = rate;
    microphone->use_float = false; /// Default to integer format

    /// Validate requested sample rate
    if (rate != 44100 && rate != 48000) {
        RARCH_WARN("[CoreAudio]: Requested sample rate %u not supported, defaulting to 48000\n", rate);
        rate = 48000;
    }

#if TARGET_OS_IPHONE
    /// Configure audio session. Bitwise | (not logical ||) to OR option flags.
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    NSError *error = nil;
    AVAudioSessionCategoryOptions categoryOptions =
        AVAudioSessionCategoryOptionMixWithOthers |
        AVAudioSessionCategoryOptionAllowBluetoothA2DP |
        AVAudioSessionCategoryOptionAllowAirPlay |
        AVAudioSessionCategoryOptionDefaultToSpeaker;
    [audioSession setCategory:AVAudioSessionCategoryPlayAndRecord
                  withOptions:categoryOptions
                        error:&error];
    if (error) {
        RARCH_ERR("[CoreAudio]: Failed to set audio session category: %s\n", [[error localizedDescription] UTF8String]);
        free(microphone);
        return NULL;
    }

    /// Set preferred sample rate
    [audioSession setPreferredSampleRate:rate error:&error];
    if (error) {
        RARCH_ERR("[CoreAudio]: Failed to set preferred sample rate: %s\n", [[error localizedDescription] UTF8String]);
        free(microphone);
        return NULL;
    }

    /// Get actual sample rate
    Float64 actualRate = [audioSession sampleRate];
    if (new_rate) {
        *new_rate = (unsigned)actualRate;
    }
    microphone->sample_rate = (int)actualRate;

    RARCH_LOG("[CoreAudio] Using sample rate: %d Hz\n", microphone->sample_rate);
#else

#endif

    /// Set format using helper method
    coreaudio_microphone_set_format(microphone, false); /// Default to 16-bit integer

    /// Calculate FIFO buffer size
    size_t fifoBufferSize = (latency * microphone->sample_rate * microphone->format.mBytesPerFrame) / 1000;
    if (fifoBufferSize == 0) {
        RARCH_WARN("[CoreAudio]: Calculated FIFO buffer size is 0 for latency: %u, sample_rate: %d, bytes_per_frame: %d\n",
                  latency, microphone->sample_rate, microphone->format.mBytesPerFrame);
        fifoBufferSize = 1024; /// Default to a reasonable buffer size
    }

    RARCH_LOG("[CoreAudio] FIFO buffer size: %zu bytes\n", fifoBufferSize);

    /// Create sample buffer
    microphone->sample_buffer = fifo_new(fifoBufferSize);
    if (!microphone->sample_buffer) {
        RARCH_ERR("[CoreAudio]: Failed to create sample buffer\n");
        goto error;
    }

    /// Initialize audio unit
    AudioComponentDescription desc = {
        .componentType = kAudioUnitType_Output,
#if TARGET_OS_IPHONE
        .componentSubType = kAudioUnitSubType_RemoteIO,
#else
        .componentSubType = kAudioUnitSubType_HALOutput,
#endif
        .componentManufacturer = kAudioUnitManufacturer_Apple,
        .componentFlags = 0,
        .componentFlagsMask = 0
    };

    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    OSStatus status = AudioComponentInstanceNew(comp, &microphone->audio_unit);
    if (status != noErr) {
        RARCH_ERR("[CoreAudio]: Failed to create audio unit\n");
        goto error;
    }

    /// Enable input
    UInt32 flag = 1;
    status = AudioUnitSetProperty(microphone->audio_unit,
                                 kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Input,
                                 1, // Input bus
                                 &flag,
                                 sizeof(flag));
    if (status != noErr) {
        RARCH_ERR("[CoreAudio]: Failed to enable input\n");
        goto error;
    }

    /// Set format using helper method
    coreaudio_microphone_set_format(microphone, false); /// Default to 16-bit integer
    status = AudioUnitSetProperty(microphone->audio_unit,
                                 kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Output,
                                 1, // Input bus
                                 &microphone->format,
                                 sizeof(microphone->format));
    if (status != noErr) {
        RARCH_ERR("[CoreAudio]: Failed to set format: %d\n", status);
        goto error;
    }

    /// Set callback
    AURenderCallbackStruct callback = { coreaudio_input_callback, microphone };
    status = AudioUnitSetProperty(microphone->audio_unit,
                                 kAudioOutputUnitProperty_SetInputCallback,
                                 kAudioUnitScope_Global,
                                 1, // Input bus
                                 &callback,
                                 sizeof(callback));
    if (status != noErr) {
        RARCH_ERR("[CoreAudio]: Failed to set callback\n");
        goto error;
    }

    /// Initialize audio unit
    status = AudioUnitInitialize(microphone->audio_unit);
    if (status != noErr) {
        RARCH_ERR("[CoreAudio]: Failed to initialize audio unit: %d\n", status);
        goto error;
    }

    /// The unit is started by start_mic: RetroArch calls it right after open when the
    /// core has the microphone enabled, and stop_mic otherwise.
    driver->open_count++;

#ifdef DEBUG
    g_audio_lifecycle_coreaudio_mic_live++;
    printf("[AUDIO_LIFECYCLE] core=libretro kind=mic_unit driver=coreaudio_mic event=create unit=%p live=%d\n",
          (void*)microphone->audio_unit, g_audio_lifecycle_coreaudio_mic_live);
    fflush(stdout);
#endif

    return microphone;

error:
    if (microphone->audio_unit) {
        AudioComponentInstanceDispose(microphone->audio_unit);
        microphone->audio_unit = nil;
    }
    if (microphone->sample_buffer)
        fifo_free(microphone->sample_buffer);
    free(microphone);
    return NULL;
}

/// Close microphone
static void coreaudio_microphone_close_mic(void *driver_context, void *microphone_context)
{
    coreaudio_microphone_driver_t *driver = (coreaudio_microphone_driver_t*)driver_context;
    coreaudio_microphone_t *microphone = (coreaudio_microphone_t*)microphone_context;
    if (microphone) {
        if (microphone->is_running)
            AudioOutputUnitStop(microphone->audio_unit);
        
        if(microphone->audio_unit) {
            AudioComponentInstanceDispose(microphone->audio_unit);
#ifdef DEBUG
            g_audio_lifecycle_coreaudio_mic_live--;
            printf("[AUDIO_LIFECYCLE] core=libretro kind=mic_unit driver=coreaudio_mic event=dispose unit=%p live=%d\n",
                  (void*)microphone->audio_unit, g_audio_lifecycle_coreaudio_mic_live);
            fflush(stdout);
#endif
            microphone->audio_unit = nil;
        }
        if (microphone->sample_buffer)
            fifo_free(microphone->sample_buffer);
        free(microphone);
        if (driver && driver->open_count > 0)
            driver->open_count--;
#if TARGET_OS_IPHONE
        coreaudio_microphone_restore_playback_category();
#endif
    } else {
        RARCH_ERR("[CoreAudio]: Failed to close microphone\n");
    }
}

/// Start microphone
static bool coreaudio_microphone_start_mic(void *driver_context, void *microphone_context)
{
    RARCH_LOG("[CoreAudio]: Starting microphone\n");
    coreaudio_microphone_t *microphone = (coreaudio_microphone_t*)microphone_context;
    if (!microphone) {
        RARCH_ERR("[CoreAudio]: Failed to start microphone\n");
        return false;
    }
    RARCH_LOG("[CoreAudio]: Starting audio unit\n");

    OSStatus status = AudioOutputUnitStart(microphone->audio_unit);
    if (status == noErr) {
        RARCH_LOG("[CoreAudio]: Audio unit started successfully\n");
        microphone->is_running = true;
        return true;
    } else {
        RARCH_ERR("[CoreAudio]: Failed to start microphone: %d\n", status);
    }
    return false;
}

/// Stop microphone
static bool coreaudio_microphone_stop_mic(void *driver_context, void *microphone_context)
{
    coreaudio_microphone_t *microphone = (coreaudio_microphone_t*)microphone_context;
    if (!microphone) {
        RARCH_ERR("[CoreAudio]: Failed to stop microphone\n");
        return false;
    }

    if (microphone->is_running) {
        OSStatus status = AudioOutputUnitStop(microphone->audio_unit);
        if (status == noErr) {
            microphone->is_running = false;
            return true;
        } else {
            RARCH_ERR("[CoreAudio]: Failed to stop microphone: %d\n", status);
        }
    }
    return true; /// Already stopped
}

/// Check if microphone is alive
static bool coreaudio_microphone_mic_alive(const void *driver_context, const void *microphone_context)
{
    coreaudio_microphone_t *microphone = (coreaudio_microphone_t*)microphone_context;
    (void)driver_context;

    return microphone && microphone->is_running;
}

/// Check if microphone uses float samples
static bool coreaudio_microphone_mic_use_float(const void *driver_context, const void *microphone_context)
{
    coreaudio_microphone_t *microphone = (coreaudio_microphone_t*)microphone_context;
    (void)driver_context;

    return microphone && microphone->use_float;
}

/// Get device list (not implemented for CoreAudio)
static struct string_list *coreaudio_microphone_device_list_new(const void *driver_context)
{
    (void)driver_context;
    return NULL;
}

/// Free device list (not implemented for CoreAudio)
static void coreaudio_microphone_device_list_free(const void *driver_context, struct string_list *devices)
{
    (void)driver_context;
    (void)devices;
}

/// Check if microphone is using float format
static bool coreaudio_microphone_use_float(const void *driver_context, const void *microphone_context)
{
    coreaudio_microphone_t *microphone = (coreaudio_microphone_t *)microphone_context;
    if (!microphone)
        return false;

    return microphone->use_float;
}

/// CoreAudio microphone driver structure
microphone_driver_t microphone_coreaudio = {
    coreaudio_microphone_init,
    coreaudio_microphone_free,
    coreaudio_pull_queued_samples,
    coreaudio_ignore_nonblock_request,
    "coreaudio",
    coreaudio_microphone_device_list_new,
    coreaudio_microphone_device_list_free,
    coreaudio_microphone_open_mic,
    coreaudio_microphone_close_mic,
    coreaudio_microphone_mic_alive,
    coreaudio_microphone_start_mic,
    coreaudio_microphone_stop_mic,
    coreaudio_microphone_mic_use_float
};
