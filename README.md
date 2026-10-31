# SleepControl

[简体中文](README.zh-CN.md) · English

A free, open-source macOS menu bar app for controlling sleep when the lid is closed, when a power adapter is connected, and while local AI coding tasks are running.

SleepControl supports Simplified Chinese, Traditional Chinese, English, German, French, Spanish, Japanese, Korean, Portuguese (Brazil), and Italian. The interface, help, and diagnostics follow your macOS preferred languages, with English as the fallback. Restart the app after changing your system or per-app language settings.

## Features

- Keep your Mac awake with the lid closed.
- Prevent idle sleep while connected to a power adapter.
- Keep your Mac awake while supported Codex or Claude Code tasks are working. Waiting for your input or approval does not count as active work.
- Set separate display-off times for battery and power-adapter use.
- Show battery charge and charging status in the menu bar, with an optional percentage.
- Launch at login.

## Requirements

- macOS 13 Ventura or later.
- Download the build that matches your processor. A release marked `arm64` is for Apple silicon; an `x86_64` release is for Intel.
- To build from source: Xcode 15 or later, or Command Line Tools with Swift 5.9 or later.

AI task detection is optional. The other sleep controls work without Codex or Claude Code.

## Install

1. Open [Releases](https://github.com/RayStudioLabs/SleepControl/releases) and download a DMG for your Mac, if a matching build is available.
2. Open the DMG and drag **SleepControl** into **Applications**.
3. Eject the disk image and open the installed app.
4. Click its battery icon in the menu bar to open the settings panel. Click it again to close the panel. Settings refresh automatically when the panel opens and periodically while the app is running.

The installer contains `SleepControl.app`. When upgrading an older copy named `SleepControl（Mac 休眠控制）.app`, quit it and replace that copy with the new app so you keep a single installation.

Current locally built packages are ad-hoc signed and **not notarized by Apple**. macOS may block the first launch. After checking the download source, use **System Settings → Privacy & Security → Open Anyway** if macOS offers that option. You can also build the app yourself.

SleepControl normally runs as a menu bar app, so it does not appear in the Dock or Command-Tab. To bring the help window forward, open the menu bar panel and click its question-mark button.

## Sleep settings

| Setting | What it changes |
| --- | --- |
| Prevent sleep with lid closed | Sets the global `pmset disablesleep` flag. **This prevents all system sleep, not only lid-close sleep.** |
| Prevent sleep on power adapter | Sets power-adapter idle sleep to never; turning it off sets it to one minute. |
| Stay awake during AI tasks | Temporarily prevents sleep while detected local AI work is active, then returns to your chosen sleep rules. |
| Display sleep | Changes the display-off timer separately for battery and power-adapter use. This is not a separate screen-lock security timer. |

The first two switches take priority. If they already keep your Mac awake, the AI setting does not change the result. When both are on, the AI switch is hidden and its previous choice is kept.

When your Mac would otherwise sleep, enabling AI protection delays sleep until all detected work has stopped. After a short settling period, SleepControl checks the current lid position, power source, and settings again. With the lid open, it restores the usual settings and lets macOS handle idle sleep. With the lid closed and sleep still due, it requests sleep.

**A closed Mac can still run and produce heat. Keep it ventilated; do not put it in a bag while sleep is disabled.** The global `disablesleep` flag is not a documented Apple API, so behavior can vary with hardware and macOS updates.

## Administrator permission

On the first change to power settings, SleepControl may ask for an administrator password. It installs `/etc/sudoers.d/lidcontrol`, allowing the current macOS user to run `/usr/bin/pmset` through `sudo` without a password.

This is a persistent permission for that user's use of `pmset`, not just for this app. It remains after a restart or after deleting the app, until you remove the rule. Existing permission is reused. See [Uninstall](#uninstall) for removal instructions.

## Optional AI task detection

1. Turn on **Stay awake during AI tasks**. SleepControl installs its local helper and adds its hooks while keeping other configuration entries.
2. For **Codex CLI**, enter `/hooks`, open each event's hook details, and review and trust the commands containing `SleepControlHelper` and `# sleepcontrol-ai-observer`. Check all SleepControl entries, not only `SessionStart`.
3. For **Claude Code**, use `/hooks` to check that the same helper and marker are present. Its hooks do not use Codex's individual trust step. Make sure hooks are not disabled.
4. Run a local task and watch **AI sleep protection** at the bottom of the help window. Check that the status changes when work starts, finishes, or pauses for you.

If new hooks are missing, fully quit and reopen the relevant AI client. `/clear` does not confirm that configuration has been reloaded. For more detail, use the help window or read [AI integration notes](docs/AI-INTEGRATION.md).

### What is detected

Thinking, generating a response, waiting for a server, tool execution, subtasks, and running background commands count as work. Idle conversations and waits for input, a choice, or approval do not. Any other active task still keeps protection in place.

Detection supports **local Codex and Claude Code sessions**. Desktop Code tasks can work when they use the same local engine and configuration and report their state correctly. Regular Claude chat, Cowork, cloud tasks, and tasks running on a remote machine over SSH are not guaranteed to be detected.

Codex and Claude Code status interfaces can change. An unknown or disconnected status is not treated as proof that a task finished; existing protection is kept until detection recovers or you turn the AI switch off. Test your own client version before relying on it for unattended work.

## Privacy and local files

The app keeps session identifiers, task lifecycle state, and process identifiers locally. It does not save prompt text, responses, or tool arguments. There is no analytics or remote service in SleepControl; AI clients make their own network connections independently.

For compatibility with the project's former name, **LidControl**, these identifiers and paths are retained:

- App identifier: `com.daichenyu.lidcontrol`.
- Helper, state, and configuration backups: `~/Library/Application Support/LidControl/AI/`.
- Passwordless power-setting rule: `/etc/sudoers.d/lidcontrol`.

The helper is named `SleepControlHelper`; its hook marker is `sleepcontrol-ai-observer`.

## Build and test

```bash
git clone https://github.com/RayStudioLabs/SleepControl.git
cd SleepControl
swift test
./scripts/build-app.sh
```

The app is generated at `build/SleepControl.app`. Copy the complete app bundle to Applications. Do not copy only its executable: the app and standalone AI helper need the bundled language resources.

To create a drag-and-drop installer for the current processor architecture:

```bash
./scripts/build-dmg.sh
```

DMG packaging also requires Python 3.10 or later. On the first run, the script downloads pinned build tools into `.build/dmg-tools/`; these are not included in the app. Set `DMG_PYTHON` to select a different Python executable. The installer opens with a Retina background, fixed icon positions, and an Applications shortcut. Its license and installation notes are included in a hidden `.documentation` folder.

This writes `build/SleepControl-<version>-<architecture>.dmg` and a `.sha256` checksum file. It does not create a universal binary automatically. macOS 13 is the deployment target; Intel builds need their own build and validation.

Tests use temporary configuration directories and simulated power drivers. They do not change real sleep settings or put the Mac to sleep.

## Uninstall

1. Turn off AI protection and launch at login, then choose **Quit** from the panel. Normal quitting restores the sleep setting temporarily changed for AI protection.
2. Remove only the SleepControl hook entries identified by `sleepcontrol-ai-observer` from the Codex and Claude Code configuration files. Keep unrelated hooks and settings. Reopen those clients so the old commands are no longer used.
3. Move SleepControl from Applications to the Trash. Once no clients still use its helper, you can remove `~/Library/Application Support/LidControl/AI/`, including its local state and backups.
4. To revoke the persistent passwordless `pmset` permission, remove this app's rule:

   ```bash
   sudo rm /etc/sudoers.d/lidcontrol
   ```

The two manual power switches change system settings and persist independently of the app. Set them to your preferred values before uninstalling. Removing the app does not reset every power setting to a factory default.

## Contributing and support

Bug reports and contributions are welcome through [GitHub Issues](https://github.com/RayStudioLabs/SleepControl/issues) and pull requests. Include your macOS version, processor type, app version, and steps to reproduce. For detection issues, include the AI client version and whether the task ran locally. Do not post private hook files, tokens, chat content, or unredacted state files.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development notes.

## License

SleepControl is released under the [MIT License](LICENSE). It is free to use, copy, modify, and redistribute, including for commercial purposes. Redistributed copies must retain the copyright and license notice. The software is provided without warranty; see the license for the full terms.
