#!/usr/bin/env bash
# Prepare and verify a signed appcast locally. Does not publish anything.
# Usage: prepare-update.sh APP FINAL_ZIP OUTPUT_DIRECTORY
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# == 3 ]] || { echo "Usage: $0 APP FINAL_ZIP OUTPUT_DIRECTORY" >&2; exit 1; }
APP="$1"
ZIP="$2"
OUT="$3"
REPO="${REPO:-jadhvank/eclam}"
ACCOUNT=com.jadhvank.eclam.sparkle
SPARKLE="$("$ROOT/scripts/fetch-sparkle.sh")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")"
[[ "$PUBLIC_KEY" == "$("$SPARKLE/bin/generate_keys" --account "$ACCOUNT" -p)" ]] || {
    echo "ERROR: Sparkle Keychain public key does not match the app" >&2; exit 1;
}
codesign --verify --deep --strict "$APP"
# Ensure the archive being signed is the app whose key/configuration we checked.
python3 - "$APP" "$ZIP" "$REPO" <<'PY'
import hashlib, plistlib, sys, zipfile
from pathlib import Path
app, archive, repo = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['SUFeedURL'] == f'https://github.com/{repo}/releases/latest/download/appcast.xml', 'Feed destination mismatch'
assert info['SUAllowsAutomaticUpdates'] is False and info['SUAutomaticallyUpdate'] is False, 'Unattended updates must be disabled'
assert info['SUVerifyUpdateBeforeExtraction'] is True, 'Pre-extraction verification required'
with zipfile.ZipFile(archive) as z:
    prefix = app.name + '/'
    assert plistlib.loads(z.read(prefix + 'Contents/Info.plist')) == info, 'Archive metadata mismatch'
    for executable in ['ElectronicClam', 'ElectronicClamHelper']:
        rel = 'Contents/MacOS/' + executable
        assert hashlib.sha256(z.read(prefix + rel)).digest() == hashlib.sha256((app / rel).read_bytes()).digest(), 'Archive executable mismatch'
PY
[[ ! -e "$OUT" ]] || { echo "ERROR: use a new output directory: $OUT" >&2; exit 1; }
mkdir -p "$OUT"
cp "$ZIP" "$OUT/$(basename "$ZIP")"
"$SPARKLE/bin/generate_appcast" --account "$ACCOUNT" --maximum-deltas 0 \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    --link "https://github.com/$REPO" -o "$OUT/appcast.xml" "$OUT"
python3 "$ROOT/scripts/validate-appcast.py" "$OUT/appcast.xml" "$ZIP" "$VERSION" "$BUILD" "$REPO"
SIGNATURE="$(python3 - "$OUT/appcast.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
print(root.find('./channel/item/enclosure').attrib['{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature'])
PY
)"
xcrun swift "$ROOT/scripts/verify-update.swift" "$PUBLIC_KEY" "$ZIP" "$SIGNATURE"
echo "Verified appcast: $OUT/appcast.xml"
