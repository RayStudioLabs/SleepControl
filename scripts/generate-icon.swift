import AppKit
import Foundation

// 按 1024 × 1024 的坐标绘制，保持所有图标尺寸的外观一致。
func drawIcon() {
    let background = NSBezierPath(
        roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
        xRadius: 185, yRadius: 185
    )
    let top = NSColor(calibratedRed: 0.23, green: 0.85, blue: 0.46, alpha: 1)
    let bottom = NSColor(calibratedRed: 0.04, green: 0.57, blue: 0.31, alpha: 1)
    NSGradient(starting: top, ending: bottom)!.draw(in: background, angle: -90)

    let body = NSRect(x: 218, y: 348, width: 552, height: 328)
    let outline = NSBezierPath(roundedRect: body, xRadius: 64, yRadius: 64)
    NSColor.white.setStroke()
    outline.lineWidth = 28
    outline.stroke()

    NSColor.white.setFill()
    NSBezierPath(
        roundedRect: NSRect(x: 802, y: 452, width: 34, height: 120),
        xRadius: 17, yRadius: 17
    ).fill()
    NSBezierPath(
        roundedRect: NSRect(x: 254, y: 384, width: 370, height: 256),
        xRadius: 32, yRadius: 32
    ).fill()

    let bolt = NSBezierPath()
    let points: [NSPoint] = [
        NSPoint(x: 532, y: 632), NSPoint(x: 432, y: 496),
        NSPoint(x: 494, y: 496), NSPoint(x: 466, y: 392),
        NSPoint(x: 570, y: 532), NSPoint(x: 508, y: 532),
    ]
    bolt.move(to: points[0])
    for point in points.dropFirst() { bolt.line(to: point) }
    bolt.close()
    NSColor(calibratedRed: 0.04, green: 0.57, blue: 0.31, alpha: 1).setFill()
    bolt.fill()
}

let iconset = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/AppIcon.iconset")
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst(2).first ?? "Resources/AppIcon.icns")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// ICNS 的 PNG 图层：普通分辨率与对应的 Retina 分辨率。
let iconTypes = [
    16: ["icp4", "ic11"], 32: ["icp5", "ic12"], 128: ["ic07", "ic13"],
    256: ["ic08", "ic14"], 512: ["ic09", "ic10"],
]
func chunk(_ type: String, payload: Data) -> Data {
    var data = Data(type.utf8)
    var length = UInt32(payload.count + 8).bigEndian
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(payload)
    return data
}
var representations = Data()

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            fatalError("无法创建图标画布")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
        (transform as NSAffineTransform).concat()
        drawIcon()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("无法生成 PNG 图标")
        }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
        representations.append(chunk(iconTypes[size]![scale - 1], payload: png))
    }
}
try chunk("icns", payload: representations).write(to: output, options: .atomic)
print("已生成图标集：\(iconset.path)")
print("已生成应用图标：\(output.path)")
