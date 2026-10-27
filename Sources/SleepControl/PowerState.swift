import Foundation

/// 从 `pmset -g` / `pmset -g custom` 读出的当前电源设置快照。
struct PowerState: Equatable {
    /// `disablesleep`：为 true 时合盖、定时休眠全部被禁止。
    var sleepDisabled = false
    /// 接电源时的系统休眠分钟数，0 表示永不（对应设置面板「显示器关闭时防止自动进入睡眠」）。
    var acSleepMinutes = 1
    /// 接电源时关闭显示器的分钟数，0 表示永不。
    var acDisplaySleepMinutes = 10
    /// 电池供电时关闭显示器的分钟数，0 表示永不。
    var batteryDisplaySleepMinutes = 2

    var preventsACSleep: Bool { acSleepMinutes == 0 }

    static func read() -> PowerState {
        (try? checkedRead()) ?? PowerState()
    }

    static func checkedRead() throws -> PowerState {
        let general = Shell.run(Privileged.pmsetPath, ["-g"], timeout: 2)
        let custom = Shell.run(Privileged.pmsetPath, ["-g", "custom"], timeout: 2)
        guard general.status == 0, custom.status == 0 else {
            throw AIProtectionError.failed(L10n.text("Unable to read power settings: %@\n%@", String(describing: general.output), String(describing: custom.output)))
        }
        return try parse(general: general.output, custom: custom.output)
    }

    static func parse(general: String, custom: String) throws -> PowerState {
        var state = PowerState()
        guard let disabled = Self.value(forKey: "SleepDisabled", in: general), [0, 1].contains(disabled) else {
            throw AIProtectionError.failed(L10n.text("Unable to determine whether sleep is disabled."))
        }
        state.sleepDisabled = disabled == 1

        var section = ""
        var foundAC = false
        for rawLine in custom.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(":") {
                section = line
                continue
            }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, let number = Int(parts[1]) else { continue }
            let key = String(parts[0])
            switch (section, key) {
            case ("AC Power:", "sleep"):
                state.acSleepMinutes = number
                foundAC = true
            case ("AC Power:", "displaysleep"): state.acDisplaySleepMinutes = number
            case ("Battery Power:", "displaysleep"): state.batteryDisplaySleepMinutes = number
            default: break
            }
        }
        guard foundAC else { throw AIProtectionError.failed(L10n.text("Unable to read sleep settings for the power adapter.")) }
        return state
    }

    private static func value(forKey key: String, in text: String) -> Int? {
        for rawLine in text.split(separator: "\n") {
            let parts = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == Substring(key) {
                return Int(parts[1])
            }
        }
        return nil
    }
}
