#!/usr/bin/env bash
# Official binary distribution, pinned by release asset SHA-256. stdout = path.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION=2.10.1
SHA=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
CACHE="$ROOT/.build"
ARCHIVE="$CACHE/Sparkle-$VERSION.tar.xz"
DEST="$CACHE/sparkle-$VERSION"
mkdir -p "$CACHE"
if [[ ! -f "$ARCHIVE" ]]; then
    DOWNLOAD="$(mktemp "$CACHE/sparkle-download.XXXXXX")"
    trap 'rm -f "$DOWNLOAD"' EXIT
    curl --fail --location --proto '=https' --proto-redir '=https' --retry 2 \
        "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" \
        -o "$DOWNLOAD"
    [[ "$(shasum -a 256 "$DOWNLOAD" | awk '{print $1}')" == "$SHA" ]] || {
        echo "ERROR: Sparkle archive checksum mismatch" >&2; exit 1;
    }
    mv "$DOWNLOAD" "$ARCHIVE"
fi
[[ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" == "$SHA" ]] || {
    echo "ERROR: cached Sparkle archive checksum mismatch: $ARCHIVE" >&2; exit 1;
}
if [[ ! -d "$DEST/Sparkle.framework" ]]; then
    STAGE="$(mktemp -d "$CACHE/sparkle-extract.XXXXXX")"
    tar -xJf "$ARCHIVE" -C "$STAGE"
    mv "$STAGE" "$DEST"
fi
codesign --verify --deep --strict "$DEST/Sparkle.framework"
printf '%s\n' "$DEST"
