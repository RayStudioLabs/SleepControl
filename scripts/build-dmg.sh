#!/bin/bash
# 构建应用并生成带固定 Finder 布局、Retina 背景的拖放安装 DMG。
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh "$@"

APP_NAME="SleepControl.app"
APP="build/SleepControl（Mac 休眠控制）.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
ARCHS=$(/usr/bin/lipo -archs "$APP/Contents/MacOS/SleepControl")
case "$ARCHS" in
    "arm64"|"x86_64") ARCH_LABEL="$ARCHS" ;;
    *) ARCH_LABEL="universal" ;;
esac
DMG_NAME="SleepControl-$VERSION-$ARCH_LABEL.dmg"
WORK=$(mktemp -d "$PWD/build/.dmg-stage.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
DOCUMENTATION="$WORK/.documentation"
mkdir "$DOCUMENTATION"

/usr/bin/codesign --verify --deep --strict "$APP"
/usr/bin/ditto "$APP" "$WORK/$APP_NAME"
cp LICENSE "$DOCUMENTATION/License.txt"
cat > "$DOCUMENTATION/安装说明.txt" <<EOF
Mac 休眠控制（SleepControl）$VERSION

安装：将「${APP_NAME}」拖到旁边的 Applications 文件夹。
安装后推出此磁盘镜像，从「应用程序」中打开 SleepControl。
程序运行在菜单栏，点击电池图标即可打开控制面板。

系统要求：macOS 13 或更高版本。
处理器架构：$ARCHS

此版本采用本地 ad-hoc 签名，未经过 Apple 公证。
若系统阻止打开，请确认安装包来源后，在「系统设置 → 隐私与安全性」中允许打开。
首次修改休眠设置时，应用可能要求管理员授权；打包与拖放安装本身不需要该授权。
EOF

cat > "$DOCUMENTATION/Read Me.txt" <<EOF
SleepControl $VERSION

Drag the app to the Applications folder beside it.
Eject this disk image, then open SleepControl from Applications.
The app runs in the menu bar. Click its battery icon to open the settings panel.

The interface follows your macOS preferred languages and supports English and Chinese.
After changing your system language, quit and reopen SleepControl.

Requires macOS 13 or later.
Processor architecture: $ARCHS

This build is ad-hoc signed and has not been notarized by Apple.
If macOS blocks it, verify the source of the download and allow it in System Settings > Privacy & Security.
The first change to power settings may require an administrator password.
EOF

# Build-only Python dependencies stay out of the app and the disk image.
DMG_PYTHON="${DMG_PYTHON:-python3}"
if ! "$DMG_PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
    echo "DMG packaging requires Python 3.10 or later (DMG_PYTHON can select it)." >&2
    exit 1
fi
TOOLS="$PWD/.build/dmg-tools"
if [ ! -x "$TOOLS/bin/python" ]; then
    "$DMG_PYTHON" -m venv "$TOOLS"
fi
if ! cmp -s scripts/requirements-dmg.txt "$TOOLS/.requirements"; then
    "$TOOLS/bin/python" -m pip install --disable-pip-version-check -r scripts/requirements-dmg.txt
    cp scripts/requirements-dmg.txt "$TOOLS/.requirements"
fi

swift scripts/generate-dmg-background.swift "$WORK"
"$TOOLS/bin/dmgbuild" -s scripts/dmg-settings.py \
    -D "app=$WORK/$APP_NAME" -D "documentation=$DOCUMENTATION" \
    -D "icon=$PWD/Resources/AppIcon.icns" -D "background=$WORK/background.png" \
    "SleepControl $VERSION" "$WORK/$DMG_NAME"
# Only replace an existing artifact after the new image has built successfully.
/usr/bin/hdiutil verify "$WORK/$DMG_NAME"
mv -f "$WORK/$DMG_NAME" "build/$DMG_NAME"
(cd build && /usr/bin/shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256")
printf '已生成安装包: %s/build/%s\n' "$PWD" "$DMG_NAME"
