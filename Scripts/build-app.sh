#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="LyricShiori"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}"
PREBUILT_BIN_DIR="${PREBUILT_BIN_DIR:-}"
APP_PATH="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_PATH/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INFO_PLIST="$ROOT_DIR/Sources/LyricShiori/Supporting/Info.plist"
MARKETING_VERSION="${MARKETING_VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"

mkdir -p "$BUILD_DIR/home" "$DIST_DIR"

export HOME="${SWIFTPM_HOME:-$BUILD_DIR/home}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$BUILD_DIR/clang-module-cache}"

if [[ "$BUILD_CONFIGURATION" != "debug" && "$BUILD_CONFIGURATION" != "release" ]]; then
    echo "BUILD_CONFIGURATION must be debug or release." >&2
    exit 1
fi

if [[ -n "$PREBUILT_BIN_DIR" ]]; then
    BIN_DIR="$PREBUILT_BIN_DIR"
    if [[ ! -x "$BIN_DIR/$APP_NAME" ]]; then
        echo "PREBUILT_BIN_DIR does not contain an executable $APP_NAME." >&2
        exit 1
    fi
else
    swift build --configuration "$BUILD_CONFIGURATION" --scratch-path "$BUILD_DIR"
    BIN_DIR="$(swift build --configuration "$BUILD_CONFIGURATION" --scratch-path "$BUILD_DIR" --show-bin-path)"
fi

rm -rf "$APP_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"
if [[ -n "$MARKETING_VERSION" ]]; then
    if [[ ! "$MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
        echo "MARKETING_VERSION must contain two or three numeric components." >&2
        exit 1
    fi
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$CONTENTS_DIR/Info.plist"
fi
if [[ -n "$BUILD_NUMBER" ]]; then
    if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
        echo "BUILD_NUMBER must be numeric." >&2
        exit 1
    fi
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$CONTENTS_DIR/Info.plist"
fi
if [[ -d "$BIN_DIR/${APP_NAME}_${APP_NAME}.bundle" ]]; then
    cp -R "$BIN_DIR/${APP_NAME}_${APP_NAME}.bundle" "$RESOURCES_DIR/"
fi
printf "APPL????" > "$CONTENTS_DIR/PkgInfo"
chmod +x "$MACOS_DIR/$APP_NAME"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$APP_PATH" >/dev/null
fi

echo "$APP_PATH"
