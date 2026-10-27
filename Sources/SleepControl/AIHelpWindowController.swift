import AppKit
import SwiftUI

/// 独立于菜单栏弹出面板，点击其他位置后说明窗口仍保持打开。
@MainActor
final class AIHelpWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AIHelpWindowController(window: nil)
    private var isClosingHelp = false
    fileprivate weak var presentationWindow: NSWindow? {
        didSet { updateWindowOrder() }
    }

    func show(model: PowerModel) {
        if window == nil {
            let helpWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 690),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            helpWindow.title = L10n.text("Stay awake during AI tasks · Help")
            helpWindow.isReleasedWhenClosed = false
            helpWindow.delegate = self
            helpWindow.contentMinSize = NSSize(width: 560, height: 540)
            helpWindow.setFrameAutosaveName("AIHelpWindow")
            helpWindow.contentView = NSHostingView(rootView: AIHelpLiveContent(model: model) { [weak self] in
                self?.window?.performClose(nil)
            })
            helpWindow.center()
            window = helpWindow
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(updateWindowOrder),
                               name: NSApplication.didBecomeActiveNotification, object: NSApp)
            center.addObserver(self, selector: #selector(updateWindowOrder),
                               name: NSApplication.didResignActiveNotification, object: NSApp)
            center.addObserver(self, selector: #selector(panelBecameKey(_:)),
                               name: NSWindow.didBecomeKeyNotification, object: nil)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isClosingHelp = false
            self.positionBesidePanel()
            self.showWindow(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            self.updateWindowOrder()
            self.window?.makeKeyAndOrderFront(nil)
        }
    }

    private func positionBesidePanel() {
        guard let window, let panel = presentationWindow,
              let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let panelFrame = panel.frame
        let size = NSSize(width: min(window.frame.width, visible.width),
                          height: min(window.frame.height, visible.height))
        let gap: CGFloat = 12
        // 先把左右候选位置限制在面板所在屏幕的可见区域，再比较实际遮挡宽度。
        // 顶部与面板对齐；空间不足时向上移动，避免窗口底部超出屏幕。
        let y = min(max(panelFrame.maxY - size.height, visible.minY), visible.maxY - size.height)
        func candidate(x: CGFloat) -> NSRect {
            NSRect(x: min(max(x, visible.minX), visible.maxX - size.width), y: y,
                   width: size.width, height: size.height)
        }
        let right = candidate(x: panelFrame.maxX + gap)
        let left = candidate(x: panelFrame.minX - gap - size.width)
        func overlapWidth(_ frame: NSRect) -> CGFloat {
            let overlap = frame.intersection(panelFrame)
            return overlap.isNull || overlap.isEmpty ? 0 : overlap.width
        }
        // 两侧都不遮挡或遮挡宽度相同时，固定优先右侧。
        let preferred = overlapWidth(right) <= overlapWidth(left) ? right : left
        window.setFrame(preferred, display: false)
    }

    @objc private func updateWindowOrder() {
        guard let window else { return }
        guard !isClosingHelp, NSApp.isActive, window.isVisible, !window.isMiniaturized else {
            window.level = .normal
            return
        }
        // 与实际面板处于同一层并排在它前面，避免跨到更高的系统菜单层级。
        // 离开本应用立即还原，说明窗口不会持续遮挡其他应用。
        let panelLevel = presentationWindow?.level ?? .normal
        window.level = NSWindow.Level(rawValue: max(NSWindow.Level.floating.rawValue, panelLevel.rawValue))
        if let presentationWindow, presentationWindow.isVisible,
           presentationWindow.level == window.level {
            window.order(.above, relativeTo: presentationWindow.windowNumber)
        } else {
            window.orderFront(nil)
        }
    }

    @objc private func panelBecameKey(_ notification: Notification) {
        guard let panel = notification.object as? NSWindow, panel === presentationWindow else { return }
        updateWindowOrder()
    }

    func windowWillClose(_ notification: Notification) {
        isClosingHelp = true
        window?.level = .normal
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isClosingHelp else { return }
            defer { self.isClosingHelp = false }
            // 只恢复仍可见面板的键盘焦点，不重新打开已被用户收起的面板。
            if let panel = self.presentationWindow, panel.isVisible { panel.makeKey() }
        }
    }
}

/// 记录问号所在的独立设置面板，用于说明窗口的定位和排序。
struct AIHelpWindowAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { AnchorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class AnchorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            AIHelpWindowController.shared.presentationWindow = window
        }
    }
}

private struct AIHelpLiveContent: View {
    @ObservedObject var model: PowerModel
    let onClose: () -> Void

    var body: some View {
        AIHelpView(status: model.aiStatus, setupMessage: model.aiSetupMessage,
                   hookMarker: AIIntegration.marker,
                   helperName: AIProtectionStore().helper.lastPathComponent,
                   codexEvents: AIIntegration.codexEvents, onClose: onClose)
            .environment(\.locale, Locale(identifier: L10n.language))
    }
}
