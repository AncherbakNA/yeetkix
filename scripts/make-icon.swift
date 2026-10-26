import AppKit

let fm = FileManager.default
let folder = URL(fileURLWithPath: "build/AppIcon.iconset", isDirectory: true)
try fm.createDirectory(at: folder, withIntermediateDirectories: true)

func star(center: NSPoint, radius: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: center.x, y: center.y + radius))
    p.curve(to: NSPoint(x: center.x + radius, y: center.y), controlPoint1: NSPoint(x: center.x + radius * 0.18, y: center.y + radius * 0.22), controlPoint2: NSPoint(x: center.x + radius * 0.22, y: center.y + radius * 0.18))
    p.curve(to: NSPoint(x: center.x, y: center.y - radius), controlPoint1: NSPoint(x: center.x + radius * 0.22, y: center.y - radius * 0.18), controlPoint2: NSPoint(x: center.x + radius * 0.18, y: center.y - radius * 0.22))
    p.curve(to: NSPoint(x: center.x - radius, y: center.y), controlPoint1: NSPoint(x: center.x - radius * 0.18, y: center.y - radius * 0.22), controlPoint2: NSPoint(x: center.x - radius * 0.22, y: center.y - radius * 0.18))
    p.curve(to: NSPoint(x: center.x, y: center.y + radius), controlPoint1: NSPoint(x: center.x - radius * 0.22, y: center.y + radius * 0.18), controlPoint2: NSPoint(x: center.x - radius * 0.18, y: center.y + radius * 0.22))
    p.close(); return p
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let factor = CGFloat(pixels) / 1024
    let transform = NSAffineTransform(); transform.scale(by: factor); transform.concat()
    let rect = NSRect(x: 86, y: 86, width: 852, height: 852)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 196, yRadius: 196)
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.16); shadow.shadowBlurRadius = 32; shadow.shadowOffset = NSSize(width: 0, height: -16); shadow.set()
    NSColor.systemPurple.setFill(); shape.fill()
    NSShadow().set()
    NSGradient(colors: [NSColor(srgbRed: 0.66, green: 0.55, blue: 0.96, alpha: 1), NSColor(srgbRed: 0.42, green: 0.31, blue: 0.79, alpha: 1)])!.draw(in: shape, angle: -65)
    let bolt = NSBezierPath()
    bolt.move(to: NSPoint(x: 575, y: 815))
    for point in [NSPoint(x: 325, y: 465), NSPoint(x: 482, y: 465), NSPoint(x: 431, y: 224), NSPoint(x: 710, y: 577), NSPoint(x: 552, y: 577)] { bolt.line(to: point) }
    bolt.close()
    NSColor.white.setFill(); bolt.fill()
    NSColor.white.withAlphaComponent(0.7).setFill(); star(center: NSPoint(x: 745, y: 748), radius: 57).fill()
    NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 2 ? "@2x" : ""
    try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", folder.path, "-o", "Resources/AppIcon.icns"]
try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(1) }
