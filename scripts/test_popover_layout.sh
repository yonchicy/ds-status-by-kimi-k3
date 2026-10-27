#!/bin/bash
# Actual SwiftUI view regression with a test-only state; no application login or network.
# Optional first argument replaces MenuPopoverView.swift for checking a historical regression.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_DIR/.build/popover-layout-tests"
SDK_PATH="${DEEPSEEKBAR_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
MENU_SOURCE="${1:-$PROJECT_DIR/Sources/DeepSeekBar/MenuPopoverView.swift}"
mkdir -p "$TEST_DIR/ModuleCache"
SWIFT_ARGS=(-sdk "$SDK_PATH" -target "$(uname -m)-apple-macos14.0" -module-cache-path "$TEST_DIR/ModuleCache")
swiftc "${SWIFT_ARGS[@]}" -emit-library -emit-module -module-name DeepSeekBarCore \
    "$PROJECT_DIR/Sources/DeepSeekBarCore/Models.swift" \
    "$PROJECT_DIR/Sources/DeepSeekBarCore/UsageSeries.swift" \
    "$PROJECT_DIR/Sources/DeepSeekBarCore/DeepSeekClient.swift" \
    "$PROJECT_DIR/Tests/PopoverLayout/FixtureData.swift" \
    -emit-module-path "$TEST_DIR/DeepSeekBarCore.swiftmodule" \
    -o "$TEST_DIR/libDeepSeekBarCore.dylib"
swiftc "${SWIFT_ARGS[@]}" -parse-as-library \
    -I "$TEST_DIR" -L "$TEST_DIR" -lDeepSeekBarCore \
    -Xlinker -rpath -Xlinker "$TEST_DIR" \
    "$MENU_SOURCE" "$PROJECT_DIR/Sources/DeepSeekBar/ToolUsageView.swift" \
    "$PROJECT_DIR/Tests/PopoverLayout/main.swift" \
    -o "$TEST_DIR/PopoverLayoutTests"
"$TEST_DIR/PopoverLayoutTests"
