# Contributing to SleepControl

Bug reports, documentation improvements, translations, and code contributions are welcome. Chinese and English are both fine for issues and pull requests.

## Build and test

Use macOS 13 or later with Xcode 15+ or Command Line Tools with Swift 5.9+.

```bash
swift test
./scripts/build-app.sh
```

Tests use temporary directories and simulated power drivers. Do not add tests that change real `pmset` settings, put the computer to sleep, or alter a contributor's real AI configuration. Use `SLEEPCONTROL_STATE_DIRECTORY` and temporary client configuration directories when testing helper behavior.

For installer changes, run `./scripts/build-dmg.sh` with Python 3.10+. The script installs the pinned tools from `scripts/requirements-dmg.txt` in `.build/dmg-tools/`. `scripts/generate-dmg-background.swift` draws 1× and 2× artwork, and `scripts/dmg-settings.py` defines the matching Finder window and icon positions. Mount the final image and check its layout, Applications link, bundled license, and app signature before publishing it.

## Changes to check

- Keep English and Chinese resources in `Sources/SleepControl/Resources/` in sync. Use `L10n.text` for visible text and diagnostics.
- Keep the complete language resource bundle in app and helper deployments.
- For power changes, cover lid position, power source, manual switches, concurrent work, waiting for input, loss of status, and restoration of settings with simulated drivers.
- AI integrations must not start or take over conversations, respond to approval requests, or persist chat contents and tool arguments.
- Preserve unrelated Codex and Claude Code settings when merging hooks.
- Explain the user-visible change and relevant verification in the pull request.

Contributions are distributed under the project's [MIT License](LICENSE).
