#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="LyricShiori"
APP_PATH="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_PATH/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INFO_PLIST="$ROOT_DIR/Sources/LyricShiori/Supporting/Info.plist"

mkdir -p "$BUILD_DIR/home" "$DIST_DIR"

export HOME="${SWIFTPM_HOME:-$BUILD_DIR/home}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$BUILD_DIR/clang-module-cache}"

swift build --configuration release --scratch-path "$BUILD_DIR"
BIN_DIR="$(swift build --configuration release --scratch-path "$BUILD_DIR" --show-bin-path)"

rm -rf "$APP_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"
printf "APPL????" > "$CONTENTS_DIR/PkgInfo"
chmod +x "$MACOS_DIR/$APP_NAME"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$APP_PATH" >/dev/null
fi

echo "$APP_PATH"
