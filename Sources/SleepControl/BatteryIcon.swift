import AppKit

/// 仿系统样式的电池图标，输出模板图像以自动适配浅色 / 深色菜单栏。
enum BatteryIcon {
    private static let size = NSSize(width: 27, height: 12)

    static func image(level: Double, charging: Bool) -> NSImage {
        let clamped = min(max(level, 0), 1)
        let image = NSImage(size: size, flipped: false) { _ in
            let body = NSRect(x: 0.5, y: 0.5, width: 23, height: 11)

            // 外框：半透明，与系统电池图标一致
            NSColor.black.withAlphaComponent(0.45).setStroke()
            let outline = NSBezierPath(roundedRect: body, xRadius: 3, yRadius: 3)
            outline.lineWidth = 1
            outline.stroke()

            // 正极凸起
            NSColor.black.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: NSRect(x: 24.5, y: 4, width: 1.5, height: 4),
                         xRadius: 0.75, yRadius: 0.75).fill()

            // 电量填充
            let inner = body.insetBy(dx: 1.5, dy: 1.5)
            let fillWidth = max(1.5, inner.width * clamped)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY,
                                             width: fillWidth, height: inner.height),
                         xRadius: 1.2, yRadius: 1.2).fill()

            if charging {
                drawBolt(in: body, clipTo: inner)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 充电闪电：先从填充中挖空一圈光晕，再画实心闪电，保证在满电与空电时都可见。
    private static func drawBolt(in body: NSRect, clipTo inner: NSRect) {
        let cx = body.midX
        let cy = body.midY
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        func bolt(scale: CGFloat) -> NSBezierPath {
            let path = NSBezierPath()
            let points: [(CGFloat, CGFloat)] = [
                (0.8, 5.0), (-2.6, -0.6), (-0.2, -0.6),
                (-1.0, -5.0), (2.6, 0.6), (0.2, 0.6),
            ]
            for (index, point) in points.enumerated() {
                let p = NSPoint(x: cx + point.0 * scale, y: cy + point.1 * scale)
                if index == 0 { path.move(to: p) } else { path.line(to: p) }
            }
            path.close()
            return path
        }

        // 光晕只在填充区内挖空，不伤及外框
        NSBezierPath(rect: inner).addClip()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.black.setFill()
        let halo = bolt(scale: 0.82)
        halo.lineWidth = 2.0
        halo.lineJoinStyle = .round
        halo.stroke()
        halo.fill()

        NSGraphicsContext.current?.compositingOperation = .sourceOver
        NSColor.black.setFill()
        bolt(scale: 0.78).fill()
    }
}
