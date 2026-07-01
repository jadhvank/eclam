#!/usr/bin/env bash
# Build ElectronicClam.app + ElectronicClamHelper daemon + eclam-hook trampoline.
# Developer ID signed by default (ADR-0020 §③). ADR-0002 §1 layout, §7 codesign
# order. ADR-0006 §E hook binary.
set -euo pipefail

# Resolve repo root regardless of cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ADR-0020 §③ — sign with a stable Developer ID so the daemon's Designated
# Requirement is cdhash-free (identifier + TeamID) and survives upgrades, instead
# of the ad-hoc cdhash that trips the SMAppService LWCR. Override for fast local
# dev iteration with `ECLAM_SIGN_ID=- ./scripts/build.sh` (ad-hoc, no notarize).
SIGN_ID="${ECLAM_SIGN_ID:-Developer ID Application: Changwook Jung (GBQ3DN529X)}"
# A secure timestamp is required for notarization; ad-hoc signing rejects it.
TS_FLAG=(--timestamp)
[[ "$SIGN_ID" == "-" ]] && TS_FLAG=()

# ADR-0023 — the helper enforces an XPC caller code-signing requirement (Team ID
# + app/hook identifiers). Ad-hoc builds have no Team ID and a churning cdhash, so
# compile the helper with -DECLAM_DEV_ADHOC to skip the check and keep the local
# CLI/hook talking to the helper. Developer ID builds enforce it.
HELPER_DEFINES=()
[[ "$SIGN_ID" == "-" ]] && HELPER_DEFINES=(-DECLAM_DEV_ADHOC)

APP="$ROOT/build/ElectronicClam.app"
MACOS_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"
LD_DIR="$APP/Contents/Library/LaunchDaemons"

SHARED_SRC=("$ROOT/Sources/Shared"/*.swift)
# ADR-0007 — CLI handlers live under ElectronicClamApp/CLICommands/.
APP_SRC=("$ROOT/Sources/ElectronicClamApp"/*.swift "$ROOT/Sources/ElectronicClamApp/CLICommands"/*.swift)
HELPER_SRC=("$ROOT/Sources/ElectronicClamHelper"/*.swift)
HOOK_SRC=("$ROOT/Sources/ElectronicClamHook"/*.swift)

TARGET="arm64-apple-macos13.0"   # TODO universal: add x86_64-apple-macos13.0 and lipo

echo "==> Cleaning"
rm -rf "$ROOT/build"
mkdir -p "$MACOS_DIR" "$RES_DIR" "$LD_DIR"

echo "==> Compiling helper"
# IOKit: PowerController binds IOPMSetSystemPowerSetting / IOPMCopySystemPowerSettings
# (SleepDisabled SPI) via @_silgen_name; the framework must be linked (ADR-0001).
# Security: HelperCallerIdentity uses SecCode/SecRequirement to identify the XPC
# caller (hook vs app/CLI) for the least-privilege method guard (ADR-0023 §④).
# `import Security` autolinks it, but pin the flag so the dependency is explicit.
swiftc -O -target "$TARGET" \
    ${HELPER_DEFINES[@]+"${HELPER_DEFINES[@]}"} \
    -framework Foundation -framework IOKit -framework Security \
    -o "$MACOS_DIR/ElectronicClamHelper" \
    "${HELPER_SRC[@]}" "${SHARED_SRC[@]}"

echo "==> Compiling hook (no AppKit)"
swiftc -O -target "$TARGET" \
    -framework Foundation \
    -o "$MACOS_DIR/eclam-hook" \
    "${HOOK_SRC[@]}" "${SHARED_SRC[@]}"

# ADR-0037 S1 — ObjC shim for the private CGVirtualDisplay SPI (clamshell lock
# guard). Reached via NSClassFromString inside the .m, so there is no link-time
# class symbol: a missing class degrades to NO instead of failing the link. ARC
# on, same arm64 target as the app. APP_SRC globs only *.swift, so swiftc never
# sees the .m/.h except via -import-objc-header below.
echo "==> Compiling virtual-display ObjC shim (ADR-0037)"
VD_SHIM_O="$ROOT/build/VirtualDisplayShim.o"
xcrun clang -c -fobjc-arc -target "$TARGET" \
    -o "$VD_SHIM_O" \
    "$ROOT/Sources/ElectronicClamApp/VirtualDisplayShim.m"

echo "==> Compiling app"
# ADR-0037 S1 — link the shim .o, import its clean header as the Swift bridging
# header, and pin -framework CoreGraphics (the shim's mirror/reconfig calls).
swiftc -O -target "$TARGET" \
    -framework AppKit -framework Foundation -framework ServiceManagement -framework IOKit \
    -framework CoreGraphics \
    -import-objc-header "$ROOT/Sources/ElectronicClamApp/VirtualDisplayShim.h" \
    -o "$MACOS_DIR/ElectronicClam" \
    "${APP_SRC[@]}" "${SHARED_SRC[@]}" \
    "$VD_SHIM_O"
# 링크 완료 — 중간 .o 는 이미 앱 바이너리에 링크됐으므로 제거한다. 산출물 폴더
# (build/) 에 .app 옆에 남으면 "이것도 배포해야 하나?" 혼란을 준다(셸 산출물 청소).
rm -f "$VD_SHIM_O"

echo "==> Assembling bundle"
cp "$ROOT/Resources/App-Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/com.jadhvank.eclam.helper.plist" \
    "$LD_DIR/com.jadhvank.eclam.helper.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Menu bar status glyphs (clam art): 3 states (off/bolt/remote) x 2 themes
# (light/dark). MenuBarController picks the variant per state and the Menu Bar
# Icon theme setting (System/Light/Dark); System renders the light art as a
# template so the menu bar tints it per appearance. Regenerate from
# Resources/icon-src/menubar/ via scripts/make-menubar-icons.py.
# Optional during early dev: if missing, the app falls back to SF Symbols.
for icon in clam-off-light clam-bolt-light clam-remote-light \
            clam-off-dark  clam-bolt-dark  clam-remote-dark; do
    if [[ -f "$ROOT/Resources/$icon.png" ]]; then
        cp "$ROOT/Resources/$icon.png" "$RES_DIR/$icon.png"
    else
        echo "    (note: Resources/$icon.png missing — menu bar falls back to SF Symbol)"
    fi
done

# Localizations (ADR-0011). Copy each <lang>.lproj/Localizable.strings into the
# bundle Resources — simple copy, same approach as the PNG assets (§B).
for lproj in "$ROOT/Resources"/*.lproj; do
    [[ -d "$lproj" ]] || continue
    name="$(basename "$lproj")"
    if [[ -f "$lproj/Localizable.strings" ]]; then
        mkdir -p "$RES_DIR/$name"
        cp "$lproj/Localizable.strings" "$RES_DIR/$name/Localizable.strings"
        echo "    localized: $name"
    fi
done

# App icon (.icns). Present once the brand icon lands (Resources/AppIcon.icns);
# Info.plist CFBundleIconFile=AppIcon points at it. Until then, generic icon.
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$RES_DIR/AppIcon.icns"
else
    echo "    (note: Resources/AppIcon.icns missing — Dock/Finder icon stays generic until the brand icon lands)"
fi

# ADR-0020 — pin stable code-signing identifiers. Bare Mach-O binaries (no
# Info.plist) otherwise get an ad-hoc identifier with a content-derived hash
# suffix that changes every rebuild, drifting the daemon's Designated Requirement
# and tripping the SMAppService LWCR on upgrade (Quinn/DTS guidance). The helper
# identifier must match its LaunchDaemon Label (com.jadhvank.eclam.helper).
echo "==> Codesigning daemon (ADR-0002 §7 order) — $SIGN_ID"
codesign --force --sign "$SIGN_ID" ${TS_FLAG[@]+"${TS_FLAG[@]}"} \
    --identifier com.jadhvank.eclam.helper --options runtime \
    "$MACOS_DIR/ElectronicClamHelper"

echo "==> Codesigning hook trampoline"
codesign --force --sign "$SIGN_ID" ${TS_FLAG[@]+"${TS_FLAG[@]}"} \
    --identifier com.jadhvank.eclam.hook --options runtime \
    "$MACOS_DIR/eclam-hook"

# Seal the bundle WITHOUT --deep: a deep re-sign would re-sign the helper/hook
# above with default (hash-suffixed) identifiers, undoing the pinning. Signing
# the bundle non-deep signs the main executable (it inherits com.jadhvank.eclam
# from Info.plist) and seals the already-signed nested binaries as-is. ADR-0020.
echo "==> Sealing app bundle (main exe = com.jadhvank.eclam, nested ids preserved)"
codesign --force --sign "$SIGN_ID" ${TS_FLAG[@]+"${TS_FLAG[@]}"} --options runtime "$APP"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Done: $APP"
