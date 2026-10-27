#!/bin/bash
# 构建应用并生成拖放安装的压缩只读 DMG。
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh "$@"

APP_NAME="SleepControl（Mac 休眠控制）.app"
APP="build/$APP_NAME"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
ARCHS=$(/usr/bin/lipo -archs "$APP/Contents/MacOS/SleepControl")
case "$ARCHS" in
    "arm64"|"x86_64") ARCH_LABEL="$ARCHS" ;;
    *) ARCH_LABEL="universal" ;;
esac
DMG_NAME="SleepControl-$VERSION-$ARCH_LABEL.dmg"
WORK=$(mktemp -d "$PWD/build/.dmg-stage.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
STAGING="$WORK/payload"
mkdir "$STAGING"

/usr/bin/codesign --verify --deep --strict "$APP"
/usr/bin/ditto "$APP" "$STAGING/$APP_NAME"
ln -s /Applications "$STAGING/Applications"
cp LICENSE "$STAGING/License.txt"
cat > "$STAGING/安装说明.txt" <<EOF
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

cat > "$STAGING/Read Me.txt" <<EOF
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

# 先在用户空间生成 HFS+ 文件系统，再压缩；无需挂载镜像或调用磁盘管理服务。
/usr/bin/hdiutil makehybrid -hfs -hfs-volume-name "SleepControl $VERSION" \
    -hfs-openfolder "$STAGING" -o "$WORK/uncompressed.dmg" "$STAGING"
/usr/bin/hdiutil convert "$WORK/uncompressed.dmg" -format UDZO -ov -o "build/$DMG_NAME"
/usr/bin/hdiutil verify "build/$DMG_NAME"
(cd build && /usr/bin/shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256")
printf '已生成安装包: %s/build/%s\n' "$PWD" "$DMG_NAME"
