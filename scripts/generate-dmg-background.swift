import AppKit
import Foundation

// Finder uses points for its window and icon positions. Supply both pixel
// densities so its background stays sharp on Retina and standard displays.
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let size = NSSize(width: 760, height: 460)

func centeredText(_ text: String, y: CGFloat, font: NSFont, color: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    (text as NSString).draw(in: NSRect(x: 28, y: y, width: size.width - 56, height: 40),
                           withAttributes: [.font: font, .foregroundColor: color,
                                            .paragraphStyle: paragraph])
}

for scale in [1, 2] {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
        pixelsHigh: Int(size.height) * scale, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Unable to create the installer background")
    }
    bitmap.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let transform = NSAffineTransform()
    transform.scaleX(by: CGFloat(scale), yBy: CGFloat(scale))
    transform.translateX(by: 0, yBy: size.height)
    transform.scaleX(by: 1, yBy: -1)
    transform.concat()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)

    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    let wash = NSGradient(starting: .white,
                          ending: NSColor(srgbRed: 0.96, green: 0.985, blue: 0.97, alpha: 1))!
    wash.draw(in: NSRect(origin: .zero, size: size), angle: -90)

    // Keep the two Finder icons real and draggable; only the arrow is painted.
    let accent = NSColor(srgbRed: 0.09, green: 0.64, blue: 0.38, alpha: 1)
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 329, y: 180))
    arrow.line(to: NSPoint(x: 431, y: 180))
    arrow.move(to: NSPoint(x: 415, y: 164))
    arrow.line(to: NSPoint(x: 431, y: 180))
    arrow.line(to: NSPoint(x: 415, y: 196))
    arrow.lineWidth = 3.5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    accent.setStroke()
    arrow.stroke()

    centeredText("将 SleepControl 拖入「应用程序」", y: 324,
                 font: .systemFont(ofSize: 23, weight: .medium),
                 color: NSColor(srgbRed: 0.15, green: 0.19, blue: 0.17, alpha: 1))
    centeredText("Drag SleepControl to Applications", y: 364,
                 font: .systemFont(ofSize: 16),
                 color: NSColor(srgbRed: 0.43, green: 0.48, blue: 0.45, alpha: 1))

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Unable to encode the installer background")
    }
    let suffix = scale == 2 ? "@2x" : ""
    try png.write(to: output.appendingPathComponent("background\(suffix).png"), options: .atomic)
}
