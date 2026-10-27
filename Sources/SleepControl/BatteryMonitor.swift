import Foundation
import IOKit.ps

/// 内置电池的当前状态快照，来自 IOKit 电源管理接口。
struct BatteryInfo: Equatable {
    var hasBattery = false
    var percent = 0
    var isCharging = false
    var isCharged = false
    var onACPower = false

    var summary: String {
        guard hasBattery else { return L10n.text("No built-in battery") }
        var parts = [L10n.text("Battery %@%%", String(describing: percent))]
        if isCharging {
            parts.append(L10n.text("Charging"))
        } else if isCharged, onACPower {
            parts.append(L10n.text("Fully charged"))
        } else if onACPower {
            parts.append(L10n.text("Power adapter"))
        } else {
            parts.append(L10n.text("On battery"))
        }
        return parts.joined(separator: " · ")
    }

    static func read() -> BatteryInfo {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return BatteryInfo() }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }

            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : current

            return BatteryInfo(
                hasBattery: true,
                percent: min(max(percent, 0), 100),
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isCharged: description[kIOPSIsChargedKey] as? Bool ?? false,
                onACPower: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            )
        }
        return BatteryInfo()
    }
}

/// 监听系统电源状态变化（插拔电源、电量变化），自动刷新 `info`。
@MainActor
final class BatteryMonitor: ObservableObject {
    @Published private(set) var info = BatteryInfo.read()

    private var runLoopSource: CFRunLoopSource?

    init() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in monitor.refresh() }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
    }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
    }

    func refresh() {
        let latest = BatteryInfo.read()
        if latest != info { info = latest }
    }
}
