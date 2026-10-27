#!/bin/bash
# Install the verified application in a stable location and register its native extension.
set -euo pipefail
cd "$(dirname "$0")"
SOURCE_APP="$PWD/DeepSeekBar.app"
INSTALL_DIR="${DEEPSEEKBAR_INSTALL_DIR:-/Applications}"
INSTALLED_APP="$INSTALL_DIR/DeepSeekBar.app"
if [ ! -d "$SOURCE_APP" ]; then echo "请先执行 ./build_app.sh" >&2; exit 1; fi
codesign --verify --deep --strict "$SOURCE_APP"
mkdir -p "$INSTALL_DIR"
STAGING_DIR="$(mktemp -d "$INSTALL_DIR/.DeepSeekBar-install.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$SOURCE_APP" "$STAGING_DIR/DeepSeekBar.app"
codesign --verify --deep --strict "$STAGING_DIR/DeepSeekBar.app"
if [ -d "$INSTALLED_APP" ]; then mv "$INSTALLED_APP" "$STAGING_DIR/previous.app"; fi
if ! mv "$STAGING_DIR/DeepSeekBar.app" "$INSTALLED_APP"; then
    if [ -d "$STAGING_DIR/previous.app" ]; then mv "$STAGING_DIR/previous.app" "$INSTALLED_APP"; fi
    exit 1
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALLED_APP"
if [ -d "$INSTALLED_APP/Contents/PlugIns/DeepSeekBarWidget.appex" ]; then
    pluginkit -a "$INSTALLED_APP/Contents/PlugIns/DeepSeekBarWidget.appex"
fi
echo "已安装：$INSTALLED_APP"
echo "打开应用后，右键桌面 → 编辑小组件 → 搜索 DeepSeekBar。"
echo "请只运行安装位置中的一个实例，以便小组件连接。"
