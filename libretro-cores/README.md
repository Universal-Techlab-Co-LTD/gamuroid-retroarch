# Unmodified libretro cores shipped in Gamuroid 3.8.0 (GPL-3.0 / AGPL-3.0)

Gamuroid 3.8.0 (build 24) ships these five emulator cores as separate frameworks, one `<name>.libretro` binary each. **None of them is modified by us**: each binary is built from the exact upstream commit listed below,
with no patch. The corresponding source is therefore the upstream repository at that commit, plus the build script and pin
table in this folder (the "scripts to control compilation"). This repository's tag `gamuroid-3.8.0-r3` holds this folder.

| Core (framework) | Upstream repository | Exact upstream commit | Licence | Version string in the shipped binary | Shipped binary SHA-256 | Mach-O UUID |
|---|---|---|---|---|---|---|
| bsnes (`bsnes.libretro`) | https://github.com/libretro/bsnes | `63ee22f7af8f5d1ada295c2c98fd7bf261fa62a7` | GPL-3.0-only | SerializerVersion 115 (not stored as a plain string) | `e2be55f8e57eb16608e8793c1c8cf74a35a0c24910a12665b4f663371765d263` | `C0843BBA-6B2C-3334-8B84-57CC4A40273A` |
| bsnes-jg (`bsnes-jg.libretro`) | https://github.com/libretro/bsnes-jg | `3f37a92f5ea3dc20b5f14176e9e4da2276fad101` (branch `libretro`) | GPL-3.0-or-later | `2.0.2` | `1332a6d79dc82e57dd326d5a8349406a09dfee8f1ff23df220908cc7129d354b` | `B1745F3F-9919-3A17-A5BB-3F8C50ADD2C3` |
| Gearsystem (`gearsystem.libretro`) | https://github.com/drhelius/Gearsystem | `7acbe0f36192c5435e3448c1e0316379b17f59d8` | GPL-3.0-only | `7acbe0f` | `41f8da627749ba3e3eff845469872d06689a90c1554957c9cd374011a49aee73` | `62B9D56D-DD60-3DA3-ADC0-FA7248993188` |
| PokeMini (`pokemini.libretro`) | https://github.com/libretro/PokeMini | `19095803f1434eb980db6e4004187a4b786e20b6` | GPL-3.0-or-later | `v0.60` | `d6c93a23d3292a7dbf397adcfd9a8e9c6e99e03dbf48cb8f518e11615cf314f4` | `14E762B9-A240-342B-BF10-1876AA8DA773` |
| ClownMDEmu (`clownmdemu.libretro`) | https://github.com/Clownacy/clownmdemu-libretro | `0675a303f01f16f4f113752d02324b87a568d201`, with its git submodules exactly as that commit pins them (`git submodule update --init --recursive`) | AGPL-3.0-or-later | `v1.6.4.1 0675a30` | `938f9ad6671be7f049e5aabf61c2b3dde25d3dc6f7bd485076e317b3da98f089` | `82F65BE0-C6FB-343C-8604-A49D3B5F6406` |

The binaries are stripped and unsigned in the table (the app's build signs them when it embeds them); the SHA-256 is of the
stripped binary produced by the script below. The upstream commits are public; the full licence text of each component is in the
upstream repository (`COPYING` / `LICENSE`) and in the app's open-source licences screen.

## Files in this folder

- `build_libretro_core_ios.sh`: the build script used for the shipped binaries (shallow-fetches the pinned commit and checks that
  `HEAD` equals the pin, builds with `platform=ios-arm64`, runs the release gates). It wraps the compiler so that every upstream
  `-miphoneos-version-min`, `-mcpu`, `-march`, `-arch`, `-isysroot` is replaced by ours: arm64, iOS 15.0, `-mcpu=apple-a7`,
  `-mtune=apple-a14`, plus `-gline-tables-only` (line tables go to a separate dSYM; `strip -x` removes them from the binary).
- `cores.tsv`: the pin table rows for these five cores. Columns: id, framework name, upstream URL, commit, submodules (0/1),
  make directory, makefile, extra make arguments (`-` = none), built dylib name, version string, extra compiler flags
  (`-` = none). The only extra flag is `-Wno-invalid-specialization` for bsnes (Xcode 27.2 libc++ rejects a specialization in
  `nall/traits.hpp`; behaviour is unchanged).

## How to build one core

Requirements: macOS with Xcode 27.2 (SDK iPhoneOS 27.2), `git`, `make`. The shipped binaries above were built with Xcode 27.2.

```sh
GAMUROID_CORE_WORK=$HOME/core-build GAMUROID_CORE_JOBS=4 ./build_libretro_core_ios.sh bsnes   # or bsnes-jg gearsystem pokemini clownmdemu
```

The result is `$GAMUROID_CORE_WORK/out/<framework>` (for example `bsnes.libretro`) and the gate report in
`$GAMUROID_CORE_WORK/results/<id>.txt`. Do not pass `--install`: it copies into the Gamuroid app repository, which is not
published. Two gates need files only the app maintainers have (`$W/old/<id>.exports`, the export list of the binary being
replaced): without it the script prints `gate exports: FAIL no old list` and exits non-zero **after** the binary has been built
and copied to `out/`. Ignore that line when you only want the binary. The script's last gate is an internal release-name check
and does not affect the code.

The machine-code bytes depend on the exact toolchain; a different Xcode produces a different binary with the same source.
Mach-O UUID and SHA-256 therefore match only with the same Xcode, SDK and clang.

## Other components

RetroArch (the host, `Cores/Libretro/`, GPL-3.0-or-later) is in this repository. melonDS DS and melonDS (GPL-3.0) are in
https://github.com/Universal-Techlab-Co-LTD/gamuroid-melondsds (tag `gamuroid-3.8.0`). GPL-2.0 and MPL-2.0 components are
provided on request by email, as the app's open-source licences screen states.
