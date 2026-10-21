#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SDK_DIR="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"

if [[ ! -d "$SDK_DIR/platforms" ]]; then
  echo "Android SDK not found at $SDK_DIR. Set ANDROID_SDK_ROOT first." >&2
  exit 1
fi

export ANDROID_HOME="$SDK_DIR"
export ANDROID_SDK_ROOT="$SDK_DIR"

cd "$SCRIPT_DIR"
./gradlew clean testDebugUnitTest lintDebug assembleDebug assembleRelease

mkdir -p "$REPO_ROOT/dist"
APK="$SCRIPT_DIR/app/build/outputs/apk/debug/app-debug.apk"
OUTPUT="$REPO_ROOT/dist/FarmHarvest-Android-debug.apk"
cp "$APK" "$OUTPUT"

if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$OUTPUT" > "$OUTPUT.sha256"
else
  sha256sum "$OUTPUT" > "$OUTPUT.sha256"
fi

echo "Installable debug APK: $OUTPUT"
