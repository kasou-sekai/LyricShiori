#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${LYRICSHIORI_BUILD_ROOT:-$ROOT_DIR/.build/sdk27}"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="LyricShiori"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}"
PREBUILT_BIN_DIR="${PREBUILT_BIN_DIR:-}"
DEVELOPER_ROOT="${DEVELOPER_DIR:-/Volumes/Data/Applications/Xcode-beta.app/Contents/Developer}"
SWIFT_EXEC="$DEVELOPER_ROOT/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
SDK_PATH="$(DEVELOPER_DIR="$DEVELOPER_ROOT" xcrun --sdk macosx --show-sdk-path)"
SDK_VERSION="$(DEVELOPER_DIR="$DEVELOPER_ROOT" xcrun --sdk macosx --show-sdk-version)"
APP_PATH="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_PATH/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INFO_PLIST="$ROOT_DIR/Sources/LyricShiori/Supporting/Info.plist"
LOCALIZATION_CATALOG="$ROOT_DIR/Sources/LyricShiori/Resources/Localizable.xcstrings"
XCSTRINGS_TOOL="$DEVELOPER_ROOT/usr/bin/xcstringstool"
MARKETING_VERSION="${MARKETING_VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"

mkdir -p "$BUILD_DIR/clang-module-cache" "$DIST_DIR"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$BUILD_DIR/clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$BUILD_DIR/clang-module-cache}"
export PATH="$DEVELOPER_ROOT/usr/bin:$DEVELOPER_ROOT/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH"

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
    "$SWIFT_EXEC" build \
        --build-system native \
        --configuration "$BUILD_CONFIGURATION" \
        --scratch-path "$BUILD_DIR" \
        --sdk "$SDK_PATH" \
        -Xlinker -platform_version \
        -Xlinker macos \
        -Xlinker 14.0 \
        -Xlinker "$SDK_VERSION"
    BIN_DIR="$("$SWIFT_EXEC" build \
        --build-system native \
        --configuration "$BUILD_CONFIGURATION" \
        --scratch-path "$BUILD_DIR" \
        --sdk "$SDK_PATH" \
        --show-bin-path)"
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
    BUNDLE_PATH="$RESOURCES_DIR/${APP_NAME}_${APP_NAME}.bundle"
    if [[ -d "$BUNDLE_PATH/Contents/Resources" ]]; then
        BUNDLE_RESOURCES="$BUNDLE_PATH/Contents/Resources"
    else
        BUNDLE_RESOURCES="$BUNDLE_PATH"
    fi

    # SwiftPM's native build currently copies string catalogs verbatim instead
    # of compiling them. Runtime localization requires Localizable.strings in
    # language-specific .lproj directories, so compile the catalog explicitly.
    if [[ ! -x "$XCSTRINGS_TOOL" ]]; then
        echo "xcstringstool is unavailable at $XCSTRINGS_TOOL." >&2
        exit 4
    fi
    "$XCSTRINGS_TOOL" compile "$LOCALIZATION_CATALOG" \
        --output-directory "$BUNDLE_RESOURCES"

    for localization_root in \
        "$BUNDLE_PATH" \
        "$BUNDLE_PATH/Contents/Resources"; do
        for localization_dir in "$localization_root"/*.lproj; do
            if [[ -d "$localization_dir" ]]; then
                cp -R "$localization_dir" "$RESOURCES_DIR/"
            fi
        done
    done
fi

for language in en zh-Hans zh-Hant ja; do
    if [[ ! -f "$RESOURCES_DIR/$language.lproj/Localizable.strings" ]]; then
        echo "Missing compiled localization: $language.lproj/Localizable.strings" >&2
        exit 5
    fi
done
printf "APPL????" > "$CONTENTS_DIR/PkgInfo"
chmod +x "$MACOS_DIR/$APP_NAME"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$APP_PATH" >/dev/null
fi

LINKED_SDK="$(vtool -show-build "$MACOS_DIR/$APP_NAME" | awk '/sdk / { print $2; exit }')"
if [[ "$LINKED_SDK" != "$SDK_VERSION" ]]; then
    echo "Expected linked SDK $SDK_VERSION, got $LINKED_SDK." >&2
    exit 3
fi

echo "$APP_PATH"
echo "Linked against macOS SDK $LINKED_SDK"
