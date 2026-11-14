#!/bin/bash
# Gamuroid 3.8.0: rebuild one libretro core from a pinned upstream commit for iOS arm64.
# Usage: build_libretro_core_ios.sh <id> [--install] [--clean]
#   <id> is the first column of cores.tsv. Builds in $GAMUROID_CORE_WORK (default ~/core-rebuild-3_8_0), never on exFAT.
#   make runs with -j$GAMUROID_CORE_JOBS (default 8; lower it when the machine swaps).
#   --install  replace Cores/<framework>/<framework name> in the app repo after all gates pass
#   --clean    delete the clone/build dir afterwards
# Toolchain wrapper strips every -miphoneos-version-min / -mcpu / -march / -arch / -isysroot the upstream Makefile
# adds and appends ours (min 15.0, -mcpu=apple-a7, -mtune=apple-a14: never above a7 so that A8 and A9 devices run the binary).
# It also appends -gline-tables-only: line tables only, kept in the object files; dsymutil turns them
# into the DWARF dSYM and strip -x removes the debug map from the shipped binary (no source paths, same machine code).
set -euo pipefail
ID="${1:?core id}"; shift || true
INSTALL=0; CLEAN=0
for a in "$@"; do case "$a" in --install) INSTALL=1;; --clean) CLEAN=1;; *) echo "unknown arg $a" >&2; exit 2;; esac; done
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
W="${GAMUROID_CORE_WORK:-$HOME/core-rebuild-3_8_0}"; mkdir -p "$W/src" "$W/out" "$W/results" "$W/tc"
case "$W" in /Volumes/*) echo "refusing to build on an external volume" >&2; exit 3;; esac
ROW="$(awk -F'\t' -v id="$ID" '$1==id' "$HERE/cores.tsv")"; [ -n "$ROW" ] || { echo "no row for $ID" >&2; exit 2; }
IFS=$'\t' read -r _ FW URL SHA SUBM MDIR MFILE MARGS DYLIB VSTR EXTRA <<<"$ROW"
[ "${EXTRA:--}" = "-" ] && EXTRA=""
EXTRA="${EXTRA//@TC@/$W/tc}"
# Classic-Mac <fp.h> shim: libpng (mupen64plus) includes it when TARGET_OS_MAC is set; the iOS SDK has no such header.
mkdir -p "$W/tc/inc"; printf '#include <math.h>\n' > "$W/tc/inc/fp.h"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
MIN=15.0
for t in clang clang++; do
  cat > "$W/tc/gamu-$t" <<WRAP
#!/bin/bash
args=(); skip=0
for a in "\$@"; do
  if [ \$skip = 1 ]; then skip=0; continue; fi
  case "\$a" in
    -miphoneos-version-min=*|-mcpu=*|-march=*|-mtune=*) ;;
    -arch|-isysroot) skip=1 ;;
    *) args+=("\$a") ;;
  esac
done
exec xcrun --sdk iphoneos $t -arch arm64 -isysroot "$SDK" "\${args[@]}" -miphoneos-version-min=$MIN -mcpu=apple-a7 -mtune=apple-a14 -gline-tables-only $EXTRA
WRAP
  chmod +x "$W/tc/gamu-$t"
done
SRC="$W/src/$ID"; rm -rf "$SRC"; mkdir -p "$SRC"; cd "$SRC"
git init -q . && git remote add origin "$URL" && git fetch -q --depth 1 origin "$SHA" && git checkout -q --detach FETCH_HEAD
[ "$(git rev-parse HEAD)" = "$SHA" ] || { echo "commit mismatch" >&2; exit 4; }
# Gamuroid patches for this core (Scripts/cores/patches/<id>/*.patch, applied in name order on the pinned commit).
PDIR="$HERE/patches/$ID"; PATCHLOG=""
if [ -d "$PDIR" ]; then
  for pf in "$PDIR"/*.patch; do
    git apply --whitespace=nowarn "$pf" || { echo "patch failed: $pf" >&2; exit 4; }
    PATCHLOG="$PATCHLOG $(basename "$pf"):$(shasum -a 256 "$pf" | cut -c1-12)"
  done
  # the Makefile takes GIT_VERSION from the environment when it is set; name the patched build
  # (the value carries its own double quotes: the Makefile pastes it into a -D option)
  export GIT_VERSION="\" ${SHA:0:8}-gamuroid\""
fi
SUBLOG=""
if [ "$SUBM" = 1 ]; then git submodule update -q --init --recursive --depth 1; SUBLOG="$(git submodule status --recursive)"; fi
[ "$MARGS" = "-" ] && MARGS=""
MARGS="${MARGS//@TC@/$W/tc}"
mkdir -p "$W/tc/bin"; ln -sf "$W/tc/gamu-clang" "$W/tc/bin/cc"; ln -sf "$W/tc/gamu-clang++" "$W/tc/bin/c++"
export PATH="$W/tc/bin:$PATH"
cd "$SRC/$MDIR"
echo "== make $ID ($URL @ $SHA)"
# shellcheck disable=SC2086
make -f "$MFILE" -j"${GAMUROID_CORE_JOBS:-8}" $MARGS platform=ios-arm64 IOSSDK="$SDK" CC="$W/tc/gamu-clang" CXX="$W/tc/gamu-clang++" > "$W/results/$ID.build.log" 2>&1 || { tail -30 "$W/results/$ID.build.log"; exit 5; }
BIN="$(find "$SRC" -name "$(basename "$DYLIB")" -type f | head -1)"; [ -n "$BIN" ] || { echo "dylib $DYLIB not found" >&2; exit 5; }
OUT="$W/out/$FW"; cp "$BIN" "$OUT"
# Crashlytics symbols: strip -x removes every local symbol, so keep them in a dSYM made from the unstripped binary first
# (same LC_UUID as $OUT; DWARF line tables from the wrapper's -gline-tables-only)
DSYM="$W/out/$FW.framework.dSYM"; rm -rf "$DSYM"; xcrun dsymutil "$BIN" -o "$DSYM" 2>"$W/results/$ID.dsymutil.log" || true
strip -x "$OUT"
install_name_tool -id "@rpath/$FW.framework/$FW" "$OUT"
# ---- gates
R="$W/results/$ID.txt"; : > "$R"; FAIL=0
say() { echo "$*" | tee -a "$R"; }
say "id=$ID url=$URL commit=$SHA"
[ -n "$PATCHLOG" ] && say "patches:$PATCHLOG"
[ -n "$SUBLOG" ] && say "submodules:" && say "$SUBLOG"
say "xcode=$(xcodebuild -version | tr '\n' ' ') sdk=$(basename "$SDK")"
say "sha256=$(shasum -a 256 "$OUT" | cut -d' ' -f1) size=$(stat -f%z "$OUT") uuid=$(dwarfdump --uuid "$OUT" | awk '{print $2}')"
say "script_sha256=$(shasum -a 256 "$HERE/build_libretro_core_ios.sh" | cut -c1-16) tsv_row_sha256=$(printf '%s' "$ROW" | shasum -a 256 | cut -c1-16)"
say "install_name=$(otool -D "$OUT" | tail -1)"
DU=$(dwarfdump --uuid "$DSYM" 2>/dev/null | awk '{print $2}' || true); OU=$(dwarfdump --uuid "$OUT" | awk '{print $2}')
DW=$(otool -l "$DSYM"/Contents/Resources/DWARF/* 2>/dev/null | grep -c -w __debug_info || true)
if [ -n "$DU" ] && [ "$DU" = "$OU" ] && [ "$DW" -gt 0 ]; then say "gate dsym: PASS $DU DWARF ($(nm -a "$DSYM"/Contents/Resources/DWARF/* | wc -l | tr -d ' ') symbols, dsymutil warnings $(wc -l <"$W/results/$ID.dsymutil.log" | tr -d ' '))"; else say "gate dsym: FAIL (dSYM uuid '$DU', binary '$OU', __debug_info $DW)"; FAIL=1; fi
# the debug map (object-file paths) must be gone from the shipped binary after strip -x
P=$(strings -a "$OUT" | grep -c -F "$W" || true); [ "$P" = 0 ] && say "gate build paths: PASS 0" || { say "gate build paths: FAIL $P"; FAIL=1; }
vtool -show-build "$OUT" | grep -E 'platform|minos|sdk' | tr -s ' \n' ' ' | tee -a "$R"; echo | tee -a "$R"
G_MINOS=$(vtool -show-build "$OUT" | awk '/minos/{print $2}'); [ "$G_MINOS" = "$MIN" ] && say "gate minos: PASS" || { say "gate minos: FAIL ($G_MINOS)"; FAIL=1; }
[ "$(lipo -archs "$OUT")" = arm64 ] && say "gate arch: PASS arm64" || { say "gate arch: FAIL"; FAIL=1; }
C=$(otool -tv "$OUT" | grep -c -w -E 'ldaprb|ldapr|eor3|bcax|casal|ldaddal|swpal' || true); [ "$C" = 0 ] && say "gate cpu: PASS 0" || { say "gate cpu: FAIL $C"; FAIL=1; }
J1=$(strings -a "$OUT" | grep -c -E 'MAP_JIT|pthread_jit_write_protect' || true)
J2=$(nm -u "$OUT" | grep -c -E 'pthread_jit_write_protect_np|vm_protect|mach_vm_protect' || true)
J3=$(nm -u "$OUT" | grep -c -E '^_mprotect$' || true)
# libco (clang aarch64) re-protects its signed, read-only co_swap_function page as PROT_READ|PROT_EXEC (no allocation, no write): upstream
# behaviour, present in the previously shipped binary as well. Allowed only when $W/old/<id>.mprotect exists (shipped binary did the same); reported.
if [ "$J3" != 0 ] && [ -f "$W/old/$ID.mprotect" ]; then say "info mprotect import: $J3 (libco, same as shipped binary)"; J3=0; fi
[ "$J1" = 0 ] && [ "$J2" = 0 ] && [ "$J3" = 0 ] && say "gate nojit: PASS (strings 0, jit imports 0)" || { say "gate nojit: FAIL strings=$J1 imports=$J2 mprotect=$J3"; FAIL=1; }
say "info jit-named symbols: $(nm -a "$OUT" | grep -ci -E 'dynarec|dynarmic|lightrec|jit' || true)"
nm -gU "$OUT" | awk '{print $3}' | grep -E '^_(retro_|gamuroid_)' | sort > "$W/results/$ID.exports.new"
OLD="$W/old/$ID.exports"
if [ -f "$OLD" ]; then
  MISS=$(comm -23 "$OLD" "$W/results/$ID.exports.new" | wc -l | tr -d ' '); XTRA=$(comm -13 "$OLD" "$W/results/$ID.exports.new" | wc -l | tr -d ' ')
  say "exports: old=$(wc -l <"$OLD" | tr -d ' ') new=$(wc -l <"$W/results/$ID.exports.new" | tr -d ' ') missing=$MISS extra=$XTRA"
  [ "$MISS" = 0 ] && say "gate exports: PASS (superset)" || { say "gate exports: FAIL missing: $(comm -23 "$OLD" "$W/results/$ID.exports.new" | tr '\n' ' ')"; FAIL=1; }
else say "gate exports: FAIL no old list"; FAIL=1; fi
V=$(strings -a "$OUT" | grep -c -F -- "$VSTR" || true); [ "$V" -gt 0 ] && say "gate version '$VSTR': PASS ($(strings -a "$OUT" | grep -F -- "$VSTR" | head -2 | tr '\n' '|'))" || { say "gate version '$VSTR': FAIL"; FAIL=1; }
# release name denylist (encoded)
# Allowlist: the exact two mupen64plus ROM-database titles of an N64 homebrew title (third-party data, also in the shipped binary).
ALLOW=$(printf '%s\n%s\n' "$(printf %s R29vZE5hbWU9TWFuaWMgTWluZXIgLSBIaWRkZW4gTGV2ZWxzIGJ5IFJlZGJvWCAoUEQp | base64 -d)" "$(printf %s R29vZE5hbWU9TWFuaWMgTWluZXIgYnkgUmVkYm9YIChQRCk= | base64 -d)")
M=$(strings -a "$OUT" | grep -ci -E "$(printf %s bWFuaWN8ZGFpdW5v | base64 -d)" || true); A=$(strings -a "$OUT" | grep -c -x -F -f <(printf '%s\n' "$ALLOW") || true); M=$((M-A)); [ "$A" -gt 0 ] && say "info name-string allowlist: $A ROM-database title(s)";
 [ "$M" = 0 ] && say "gate name strings: PASS 0" || { say "gate name strings: FAIL $M"; FAIL=1; }
say "RESULT=$([ $FAIL = 0 ] && echo PASS || echo FAIL)"
if [ $FAIL = 0 ] && [ $INSTALL = 1 ]; then
  F="$REPO/Cores/$FW.framework"; rm -rf "$F/_CodeSignature"; cp "$OUT" "$F/$FW"
  /usr/libexec/PlistBuddy -c "Set :MinimumOSVersion $MIN" "$F/Info.plist"
  say "installed=$F/$FW"
  # git-ignored (*.dSYM); the archive phase and Scripts/upload_core_dsyms.sh find it by UUID
  rm -rf "$F.dSYM"; ditto "$DSYM" "$F.dSYM"; say "installed_dsym=$F.dSYM"
fi
[ $CLEAN = 1 ] && rm -rf "$SRC"
[ $FAIL = 0 ]
