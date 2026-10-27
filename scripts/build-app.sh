#!/bin/bash
# 编译 SleepControl 并打包为 build/SleepControl（Mac 休眠控制）.app（ad-hoc 签名）。
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release "$@" 2>&1 | tail -n 3

APP="build/SleepControl（Mac 休眠控制）.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/SleepControl" "$APP/Contents/MacOS/SleepControl"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R ".build/release/SleepControl_SleepControl.bundle" "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
touch "$APP"

echo "已生成: $(pwd)/$APP"
printf '运行:   open "%s"\n' "$APP"
printf '安装:   cp -R "%s" /Applications/\n' "$APP"
