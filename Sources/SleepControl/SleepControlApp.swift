import AppKit
import SwiftUI

struct SleepControlApp: App {
    @NSApplicationDelegateAdaptor(SleepControlAppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class SleepControlAppDelegate: NSObject, NSApplicationDelegate {
    private var statusPanel: StatusPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusPanel = StatusPanelController(model: PowerModel(), battery: BatteryMonitor())
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusPanel?.showPanel()
        return false
    }
}
