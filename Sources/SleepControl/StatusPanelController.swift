import AppKit
import Combine
import SwiftUI

/// 自行管理面板生命周期，不随说明窗口失去焦点或关闭而收起。
@MainActor
final class StatusPanelController: NSObject {
    private let model: PowerModel
    private let battery: BatteryMonitor
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = SettingsPanel(contentRect: .zero,
                                      styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
    private var subscriptions = Set<AnyCancellable>()
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init(model: PowerModel, battery: BatteryMonitor) {
        self.model = model
        self.battery = battery
        super.init()
        item.autosaveName = "SleepControlStatusItem"
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.setAccessibilityLabel(L10n.text("Mac Sleep Control"))
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: SettingsPanelView()
            .environmentObject(model).environmentObject(battery)
            .environment(\.locale, Locale(identifier: L10n.language))
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12)))

        model.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &subscriptions)
        battery.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &subscriptions)
        refreshStatusItem()
    }

    private func scheduleRefresh() {
        // objectWillChange 在属性写入前发出，下一轮读取更新后的值。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshStatusItem()
            if self.panel.isVisible { self.positionPanel() }
        }
    }

    private func refreshStatusItem() {
        guard let button = item.button else { return }
        let info = battery.info
        button.image = info.hasBattery
            ? BatteryIcon.image(level: Double(info.percent) / 100, charging: info.isCharging)
            : NSImage(systemSymbolName: "powerplug", accessibilityDescription: L10n.text("Power"))
        let showPercent = UserDefaults.standard.object(forKey: "showBatteryPercent") as? Bool ?? true
        button.title = info.hasBattery && showPercent ? " \(info.percent)%" : ""
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.imagePosition = .imageLeading
        let lid = model.manualSleepDisabled ? L10n.text("Prevent sleep with lid closed: On") : L10n.text("Prevent sleep with lid closed: Off")
        button.toolTip = "\(info.summary)\n\(lid)\n\(model.aiStatus)"
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        battery.refresh()
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        startOutsideClickMonitoring()
    }

    private func positionPanel() {
        guard let button = item.button, let buttonWindow = button.window,
              let screen = buttonWindow.screen else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        let fitting = panel.contentView?.fittingSize ?? NSSize(width: L10n.panelWidth, height: 400)
        let size = NSSize(width: L10n.panelWidth, height: min(ceil(fitting.height), visible.height))
        let x = min(max(anchor.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let y = min(max(anchor.minY - 6 - size.height, visible.minY), visible.maxY - size.height)
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
    }

    private func startOutsideClickMonitoring() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53, event.window === self.panel {
                    self.hidePanel()
                    return nil
                }
            } else if let window = event.window,
                      window !== self.panel,
                      window !== self.item.button?.window,
                      window !== AIHelpWindowController.shared.window,
                      window.parent !== self.panel {
                self.hidePanel()
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hidePanel()
        }
    }

    private func hidePanel() {
        panel.orderOut(nil)
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }
}

private final class SettingsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
