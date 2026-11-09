# RetroArch frontend (Libretro target) source as shipped in Gamuroid 3.8.0 (revision r2)

This snapshot is the RetroArch (libretro frontend) source tree that the Gamuroid iOS app compiles as its `Libretro.framework`
target, plus Gamuroid's glue files. It contains only the C / Objective-C tree, its bundled dependencies and the build flag file.
It does NOT contain the Gamuroid app's own (Swift) source. All Swift files in this tree are RetroArch's own `pkg/apple` files,
byte-identical to upstream.

| Item | Value |
|---|---|
| Component | RetroArch as the libretro host of the Gamuroid app (`Libretro.framework`) |
| Licence | GPL-3.0-or-later (`LICENSE` at the top = `Cores/Libretro/COPYING`; per-file headers). Bundled libraries keep their own licences (libretro-common MIT, etc.) |
| Upstream | https://github.com/libretro/RetroArch, commit `57acb067b8cc113c86df9b2d45e80d37c9f7f4a2` (v1.21.0 line) |
| Matches app version | Gamuroid 3.8.0, revision r2 (tag `gamuroid-3.8.0-r2`). Taken from paths `Cores/Libretro/` and `Gamuroid/Libretro/` of the Gamuroid app's private repository at commit `e0141de570780de93651764fc90aa86fdb0205c6`; not fetchable, and not needed: this repository holds every file of those two paths. Tag `gamuroid-3.8.0` is the earlier revision (r1) of the same version; r2 supersedes it and matches the final app tree |
| Binary | compiled into the app's `Libretro.framework` (no separate binary SHA) |

## Layout

- `Cores/Libretro/` : RetroArch tree with Gamuroid changes. Gamuroid glue files: `gamuroid_frontend_values.h`,
  `input/drivers_joypad/gamuroid_joypad.m` and `gamuroid_joypad_host.h`, `ui/drivers/GamuroidRetroHost.m`, `ui/drivers/cocoa/GamuroidRetroHost.h`,
  `ui/drivers/cocoa/gamuroid_embedded_host.h`; and edits in `runloop.c`, `ui/drivers/ui_cocoatouch.m`, `ui/drivers/cocoa/cocoa_common.m`,
  `input/drivers/cocoa_input.m`, `audio/drivers_microphone/coreaudio_mic.m` and others. RetroArch is built **without** `HAVE_MENU`.
- `Gamuroid/Libretro/` : `LibretroConfig.xcconfig` (the preprocessor flags of the shipped build), `Libretro.h` (framework umbrella header), `git_version.h`.

## Interface to the app

`GamuroidRetroHost.h` is the public Objective-C interface of the framework (start, stop, pause, resume, state save and load, cheats, options, input,
video and audio hooks). `gamuroid_embedded_host.h` and `gamuroid_joypad_host.h` declare the callbacks the host (the Gamuroid app) provides.
The app side is not published; any other host can implement these headers. `cocoa_common.m` imports `RetroArch-Swift.h` only under
`HAVE_IOS_SWIFT`, which the Gamuroid build does not define.

## Build

The shipped framework is compiled by a framework target of the Gamuroid app's Xcode project. That project file is part of the app and
is not in this repository, so its complete settings for this target are listed here. To rebuild, create an iOS framework target with
them in an Xcode project placed in `Gamuroid/` (the xcconfig resolves `SRCBASE = $(SRCROOT)/../Cores/Libretro`):

- **Base configuration:** `Gamuroid/Libretro/LibretroConfig.xcconfig` (every preprocessor flag, the header search paths, C++ standard
  `c++11`, ARC on). Release adds `-DNDEBUG -DNS_BLOCK_ASSERTIONS=1` through the same file.
- **Sources (6 files, all under `Cores/Libretro/`):** `griffin/griffin.c` (RetroArch's unity-build entry), `griffin/griffin_objc.m`,
  `griffin/griffin_cpp.cpp`, `griffin/griffin_glslang.cpp`, `ui/drivers/GamuroidRetroHost.m`, `pkg/apple/JITSupport.m`.
- **Public header:** `Cores/Libretro/ui/drivers/cocoa/GamuroidRetroHost.h`; umbrella header `Gamuroid/Libretro/Libretro.h`;
  `Gamuroid/Libretro/git_version.h` supplies `GIT_VERSION` (`HAVE_GIT_VERSION`).
- **Target settings (Release):** product `Libretro.framework` (`MACH_O_TYPE = mh_dylib`, `DEFINES_MODULE = YES`,
  `DYLIB_INSTALL_NAME_BASE = @rpath`), `IPHONEOS_DEPLOYMENT_TARGET = 15.0`, arm64, `GCC_OPTIMIZATION_LEVEL = s`,
  `GCC_C_LANGUAGE_STANDARD = gnu17`, `CLANG_CXX_LANGUAGE_STANDARD = c++11`, `TARGETED_DEVICE_FAMILY = 1,2`,
  `LD_RUNPATH_SEARCH_PATHS = @executable_path/Frameworks @executable_path/Frameworks/MoltenVK.framework`.
- **Linked system frameworks:** AVFoundation, AudioToolbox, CFNetwork, CoreAudio, CoreGraphics, CoreLocation, CoreMedia, CoreText,
  CoreVideo, Foundation, GameController, GLKit, Metal, MetalKit, MobileCoreServices, OpenAL, OpenGLES, QuartzCore, UIKit, and `libz.tbd`.
  MoltenVK is loaded at run time from the app bundle (Vulkan driver); it is not linked by this target.

RetroArch's own Apple project files remain under `Cores/Libretro/pkg/apple/`.

## Public test keys kept from upstream

`Cores/Libretro/pkg/msvc-uwp/RetroArch-msvcUWP/RetroArch-msvcUWP_TemporaryKey.pfx` and `Cores/Libretro/deps/bearssl-0.6/samples/*.pem` are
byte-identical to the files in libretro/RetroArch at the base commit; the private-key blocks in `deps/mbedtls/certs.c`, `pkparse.c` and `pkwrite.c`
are upstream test fixtures.
