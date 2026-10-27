#!/bin/bash
# Build the menu bar app and its native WidgetKit extension for local use.
set -euo pipefail
cd "$(dirname "$0")"

WITH_WIDGET=true
for arg in "$@"; do
    case "$arg" in
        --with-widget) WITH_WIDGET=true ;;
        --without-widget) WITH_WIDGET=false ;;
        --allow-ad-hoc) : ;; # Compatibility with the earlier build command; now the default.
        --help)
            echo "Usage: ./build_app.sh [--with-widget | --without-widget]"
            echo "Default: native widget included, locally ad-hoc signed; no Team ID required."
            exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
APP_DIR="$PWD/DeepSeekBar.app"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/ModuleCache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$PWD/.build/ModuleCache}"
# This package has no external dependencies or build plugins. Local caches also work inside coding sandboxes.
SWIFT_BUILD_ARGS=(--disable-sandbox --cache-path "$PWD/.build/cache" -c release)
if [ -n "${DEEPSEEKBAR_SDK_PATH:-}" ]; then
    SWIFT_BUILD_ARGS+=(--sdk "$DEEPSEEKBAR_SDK_PATH")
fi
swift build "${SWIFT_BUILD_ARGS[@]}" --product DeepSeekBar
if $WITH_WIDGET; then
    swift build "${SWIFT_BUILD_ARGS[@]}" --product DeepSeekBarWidget
fi
BIN_DIR="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
STAGING_DIR="$(mktemp -d "$PWD/.build/package.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/DeepSeekBar.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN_DIR/DeepSeekBar" "$STAGED_APP/Contents/MacOS/"
cp Info.plist "$STAGED_APP/Contents/"
if [ -d "$BIN_DIR/DeepSeekBar_DeepSeekBar.bundle" ]; then
    cp -R "$BIN_DIR/DeepSeekBar_DeepSeekBar.bundle" "$STAGED_APP/Contents/Resources/"
fi

if $WITH_WIDGET; then
    EXTENSION="$STAGED_APP/Contents/PlugIns/DeepSeekBarWidget.appex"
    mkdir -p "$EXTENSION/Contents/MacOS"
    cp "$BIN_DIR/DeepSeekBarWidget" "$EXTENSION/Contents/MacOS/"
    cp WidgetExtension/Info.plist "$EXTENSION/Contents/"
    codesign --force --sign "$SIGN_IDENTITY" --entitlements WidgetExtension/Widget.entitlements "$EXTENSION"
    codesign --verify --strict "$EXTENSION"
fi

# Seal nested code before the containing app. No App Group or developer team entitlement is needed.
codesign --force --sign "$SIGN_IDENTITY" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
# Keep the previous build until packaging and signature verification have succeeded.
if [ -d "$APP_DIR" ]; then mv "$APP_DIR" "$STAGING_DIR/previous.app"; fi
if ! mv "$STAGED_APP" "$APP_DIR"; then
    if [ -d "$STAGING_DIR/previous.app" ]; then mv "$STAGING_DIR/previous.app" "$APP_DIR"; fi
    exit 1
fi
echo "✅ 完成：$APP_DIR"
echo "   安装并注册小组件：./install_app.sh"
echo "   临时运行：open \"$APP_DIR\""
