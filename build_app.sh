#!/bin/bash
# 构建 DeepSeekBar.app：release 编译 + 打包 .app + 本地 ad-hoc 签名
set -euo pipefail
cd "$(dirname "$0")"

echo "▶ swift build -c release"
swift build -c release

APP_DIR="DeepSeekBar.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp .build/release/DeepSeekBar "$APP_DIR/Contents/MacOS/"
cp Info.plist "$APP_DIR/Contents/"
# SPM 资源 bundle（图标等）
if [ -d .build/release/DeepSeekBar_DeepSeekBar.bundle ]; then
    cp -R .build/release/DeepSeekBar_DeepSeekBar.bundle "$APP_DIR/Contents/Resources/"
fi

# ad-hoc 签名，保证能从 Finder/启动台正常打开，也是 SMAppService 登录项的前提。
codesign --force --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "✅ 完成：$APP_DIR"
echo "   运行：open $APP_DIR"
