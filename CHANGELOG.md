# Changelog

## 0.3.2

- Redesigned the DMG as a two-icon drag-and-drop installer, with a Retina background, green direction arrow, and Chinese/English instructions.
- Saved the Finder window size, icon positions, and view settings in the image.
- Moved license and installation notes into a hidden folder to keep the install window clear.
- Added pinned, isolated build tools for reproducible DMG layout generation.

重新设计 DMG 安装界面：只显示应用和 Applications 两个图标，配有高清背景、绿色箭头和中英文拖放提示。安装盘会保存窗口及图标布局，协议与详细说明收进隐藏文件夹。

## 0.3.1

First public source release, under the MIT License.

- English and Chinese UI selected from macOS preferred languages.
- Manual sleep controls, separate display-off timers, and local AI task protection.
- Independent settings and help windows; closing help keeps an open settings panel visible.
- A local event helper and monitor for supported Codex and Claude Code sessions.
- A per-cycle autorelease pool in the standalone monitor to release temporary Foundation objects during long runs.
- English and Chinese installation, configuration, permission, and uninstall documentation.

Release builds are ad-hoc signed, not Apple-notarized. Prebuilt processor architectures are identified in each asset's filename.

首次公开源码版本，采用 MIT 协议。包含中英文界面、休眠与显示器设置、本机 AI 任务保护、独立说明窗口，以及后台监控循环的临时对象释放处理。安装、权限、兼容范围和卸载方法见 README。
