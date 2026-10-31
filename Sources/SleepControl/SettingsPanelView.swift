import SwiftUI

struct SettingsPanelView: View {
    @EnvironmentObject private var model: PowerModel
    @EnvironmentObject private var battery: BatteryMonitor
    @AppStorage("showBatteryPercent") private var showBatteryPercent = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            sleepSection
            Divider()
            lockSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: L10n.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 顶部

    private var header: some View {
        HStack {
            Image(nsImage: BatteryIcon.image(level: Double(battery.info.percent) / 100,
                                             charging: battery.info.isCharging))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "SleepControl").font(.headline)
                Text(battery.info.summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.busy {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: - 休眠

    private var sleepSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Sleep")).font(.subheadline).foregroundStyle(.secondary)

            Toggle(isOn: Binding(
                get: { model.manualSleepDisabled },
                set: { model.setLidKeepAwake($0) }
            )) {
                Text(L10n.text("Prevent sleep with lid closed"))
            }
            .disabled(model.busy || !model.loaded)

            Toggle(isOn: Binding(
                get: { model.state.preventsACSleep },
                set: { model.setPreventACSleep($0) }
            )) {
                Text(L10n.text("Prevent sleep on power adapter"))
            }
            .disabled(model.busy || !model.loaded)

            if !(model.manualSleepDisabled && model.state.preventsACSleep) {
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(
                        get: { model.aiEnabled },
                        set: { model.setAIEnabled($0) }
                    )) {
                        Text(L10n.text("Stay awake during AI tasks"))
                    }
                    .disabled(model.busy || !model.loaded)

                    Spacer(minLength: 0)

                    Button {
                        AIHelpWindowController.shared.show(model: model)
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.text("Read how this works and how to set up Codex and Claude Code"))
                    .accessibilityLabel(L10n.text("Help with staying awake during AI tasks"))
                    .accessibilityIdentifier("ai-task-help-button")
                    .background(AIHelpWindowAnchor().frame(width: 0, height: 0))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .toggleStyle(.switch)
    }

    // MARK: - 锁屏

    private var lockSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Display sleep")).font(.subheadline).foregroundStyle(.secondary)

            displaySleepPicker(
                title: L10n.text("On power adapter"),
                selection: model.state.acDisplaySleepMinutes,
                onChange: model.setACDisplaySleep
            )
            displaySleepPicker(
                title: L10n.text("On battery"),
                selection: model.state.batteryDisplaySleepMinutes,
                onChange: model.setBatteryDisplaySleep
            )
        }
        .disabled(model.busy)
    }

    private func displaySleepPicker(
        title: String,
        selection: Int,
        onChange: @escaping (Int) -> Void
    ) -> some View {
        let choices = PowerModel.displaySleepChoices.contains(selection)
            ? PowerModel.displaySleepChoices
            : (PowerModel.displaySleepChoices + [selection]).sorted { a, b in
                // 0（永不）排最后
                if a == 0 { return false }
                if b == 0 { return true }
                return a < b
            }
        return Picker(title, selection: Binding(get: { selection }, set: onChange)) {
            ForEach(choices, id: \.self) { minutes in
                Text(PowerModel.label(forMinutes: minutes)).tag(minutes)
            }
        }
        .pickerStyle(.menu)
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            )) {
                Text(L10n.text("Launch at login"))
            }

            Toggle(L10n.text("Show battery percentage in menu bar"), isOn: $showBatteryPercent)

            if let message = model.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button(L10n.text("Quit")) { model.quit() }
                    .keyboardShortcut("q")
            }
        }
        .toggleStyle(.switch)
        .disabled(model.busy)
    }
}
