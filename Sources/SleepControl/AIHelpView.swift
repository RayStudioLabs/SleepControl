import AppKit
import SwiftUI

struct AIHelpView: View {
    let status: String
    let setupMessage: String?
    let hookMarker: String
    let helperName: String
    let codexEvents: [String]
    let onClose: () -> Void
    @State private var selectedTab = 0
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            Picker(L10n.text("Help category"), selection: $selectedTab) {
                Text(L10n.text("How it works")).tag(0)
                Text(L10n.text("Codex setup")).tag(1)
                Text(L10n.text("Claude Code setup")).tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Group {
                switch selectedTab {
                case 1: guideScroll { codexGuide }
                case 2: guideScroll { claudeGuide }
                default: guideScroll { behaviorGuide }
                }
            }
            .id(selectedTab)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 18)

            VStack(alignment: .leading, spacing: 8) {
                Divider()
                Text(L10n.text("AI sleep protection")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(status).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let setupMessage {
                    Text(setupMessage).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button(L10n.text("Close"), action: onClose)
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 560, minHeight: 540)
    }

    private func guideScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            content()
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .textSelection(.enabled)
        }
    }

    private var behaviorGuide: some View {
        VStack(alignment: .leading, spacing: 20) {
            section(L10n.text("What does this switch do?")) {
                Text(L10n.text("When this is on, your Mac stays awake while AI tasks are running. Once they stop, the first two switches in the panel determine whether your Mac can sleep."))
                Text(L10n.text("If the first two switches already keep your Mac awake, the AI switch has nothing extra to do. When both switches are on, the AI switch is hidden. Turn either one off to show it again; your previous choice is kept."))
            }
            section(L10n.text("What counts as a running task?")) {
                bullet(L10n.text("The AI is thinking, writing a response, or waiting for a server to respond."))
                bullet(L10n.text("The AI is running a command, script, or another tool."))
                bullet(L10n.text("A subtask started by the AI, or a command running in the background, has not finished."))
            }
            section(L10n.text("What if the AI is waiting for you?")) {
                Text(L10n.text("When the AI pauses for you to type, choose an option, or approve an action, it no longer keeps your Mac awake. An idle conversation does not keep it awake either."))
                Text(L10n.text("If you have several conversations open, all their tasks need to stop first. Your Mac stays awake while any background task is still running, even if a conversation is waiting for you."))
            }
            section(L10n.text("What happens when tasks stop?")) {
                Text(L10n.text("After all tasks stop, SleepControl waits about two seconds, then checks the power source, lid position, and switch settings. If the lid is closed and your settings allow sleep, it puts your Mac to sleep. If the lid is open, it restores your usual settings and lets macOS decide when to sleep automatically."))
                Text(L10n.text("If task status cannot be read for a while, SleepControl does not assume the tasks have finished. Any sleep protection already in place is kept until the connection recovers or you turn the AI switch off."))
            }
            section(L10n.text("Which AI apps are supported?")) {
                Text(L10n.text("Codex and Claude Code on Mac computers are supported. Tasks in their desktop apps also need to run locally and report their status to SleepControl. Follow the setup steps in the other two tabs, then run a task to check that it is detected."))
                Text(L10n.text("Cloud tasks, tasks running on a remote computer over SSH, regular Claude chats, and Cowork are not guaranteed to be detected."))
            }
        }
    }

    private var codexGuide: some View {
        VStack(alignment: .leading, spacing: 20) {
            step(1, L10n.text("Turn on “Stay awake during AI tasks”")) {
                Text(L10n.text("SleepControl installs its helper and adds the hooks needed to receive task status to ~/.codex/hooks.json. Your other settings are kept, so you do not need to edit the file yourself. The first time you change power settings, you may need to enter an administrator password."))
            }
            step(2, L10n.text("Enter /hooks in the Codex CLI")) {
                Text(L10n.text("Use ↑ / ↓ to select an event such as SessionStart or UserPromptSubmit, press Return, then open the hook’s command details. The list shows event names, so there will not be an event called SleepControl."))
                Text(L10n.text("A hook may be called Unnamed hook. That is normal. Look for the helper filename and marker below in its command to identify the SleepControl hook."))
                hookIdentity
            }
            step(3, L10n.text("Trust the SleepControl hooks")) {
                Text(L10n.text("Check that the hook comes from your user configuration and its command contains the filename and marker above, then trust it. Check all %@ events below, not just SessionStart:", String(describing: codexEvents.count)))
                Text(codexEvents.joined(separator: " · "))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(L10n.text("You do not need to trust an unchanged hook again. If the helper path or hook contents change later, Codex may ask you to review it again."))
            }
            step(4, L10n.text("Run a Codex task to check the setup")) {
                Text(L10n.text("Choose a task that runs on this Mac and takes a little time. Watch the status at the bottom of this window. If your usual settings allow sleep, Codex should appear while the task runs. The status should change when the task finishes or pauses for your input."))
            }
            section(L10n.text("Desktop app and common questions")) {
                bullet(L10n.text("In the desktop app, choose a project or Worktree task that runs on this computer and uses the same user configuration. Run a task to check that SleepControl recognizes both active work and pauses for your input."))
                bullet(L10n.text("If the hooks are missing from /hooks, quit Codex completely and reopen it, then check again. Entering /clear does not mean the hook configuration has been reloaded."))
                bullet(L10n.text("If you changed CODEX_HOME, make sure SleepControl and Codex use the same configuration directory. Conversations that are not connected to the local Codex service may not reliably distinguish running tasks from requests for your approval."))
            }
            Link(L10n.text("Codex hook documentation ↗"), destination: URL(string: "https://learn.chatgpt.com/docs/hooks")!)
        }
    }

    private var claudeGuide: some View {
        VStack(alignment: .leading, spacing: 20) {
            step(1, L10n.text("Turn on “Stay awake during AI tasks”")) {
                Text(L10n.text("SleepControl adds the hooks needed to receive task status to ~/.claude/settings.json. Your other settings are kept, so there is no need to add these hooks yourself."))
            }
            step(2, L10n.text("Enter /hooks in Claude Code")) {
                Text(L10n.text("Find the hooks from your user settings, open their command details, and look for the filename and marker below. In Claude Code, /hooks lets you view the configuration. You do not need to trust each hook as you do in Codex."))
                hookIdentity
            }
            step(3, L10n.text("Check whether hooks have been disabled")) {
                Text(L10n.text("If your configuration includes disableAllHooks, make sure it is not true. Setting it to true disables all hooks, so SleepControl cannot receive task status. Set it to false or leave it unset to allow hooks. Project settings, administrator settings, and launch options can also disable hooks."))
                Text(L10n.text("Claude Code usually picks up configuration changes automatically. If the hooks are still missing or tasks are not detected, reopen the local conversation and try again."))
            }
            step(4, L10n.text("Run a Claude Code task to check the setup")) {
                Text(L10n.text("Choose a task that runs on this Mac and takes a little time. Watch the status at the bottom of this window. If your usual settings allow sleep, Claude should appear while the task runs. The status should change when the task finishes or pauses for your input. Seeing the configuration in /hooks alone does not confirm that SleepControl is receiving task status."))
            }
            section(L10n.text("Desktop app and custom configuration folders")) {
                Text(L10n.text("For Code tasks in the desktop app that use the local Claude Code engine, follow the same steps to check the setup. Regular Claude chats, Cowork, cloud tasks, and remote SSH tasks are not guaranteed to be detected."))
                Text(L10n.text("If you changed CLAUDE_CONFIG_DIR, make sure SleepControl and Claude Code use the same configuration directory. If “status unknown” appears after updating Claude Code, check that the hooks are still present and enabled. SleepControl may also need an update to support the new version."))
            }
            Link(L10n.text("Claude Code hook documentation ↗"), destination: URL(string: "https://code.claude.com/docs/en/hooks")!)
        }
    }

    private var hookIdentity: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Helper file: %@", String(describing: helperName)))
                .font(.system(size: 12, design: .monospaced))
            Text(L10n.text("Command ends with: # %@", String(describing: hookMarker)))
                .font(.system(size: 12, design: .monospaced))
            Button(copied ? L10n.text("Marker copied") : L10n.text("Copy hook marker")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hookMarker, forType: .string)
                copied = true
            }
            .font(.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content().fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step<Content: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content().fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
