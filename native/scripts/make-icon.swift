import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let outer = NSBezierPath(roundedRect: NSRect(x: 65, y: 65, width: 894, height: 894), xRadius: 212, yRadius: 212)
        NSGradient(starting: NSColor(red: 0.19, green: 0.60, blue: 0.44, alpha: 1), ending: NSColor(red: 0.07, green: 0.37, blue: 0.29, alpha: 1))!.draw(in: outer, angle: -80)
        NSColor.white.setStroke()
        let envelope = NSBezierPath(roundedRect: NSRect(x: 226, y: 306, width: 572, height: 410), xRadius: 60, yRadius: 60)
        envelope.lineWidth = 34; envelope.stroke()
        let flap = NSBezierPath(); flap.move(to: NSPoint(x: 246, y: 683)); flap.line(to: NSPoint(x: 512, y: 476)); flap.line(to: NSPoint(x: 778, y: 683)); flap.lineWidth = 34; flap.lineJoinStyle = .round; flap.stroke()
        NSColor(red: 0.82, green: 0.99, blue: 0.67, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 652, y: 236, width: 214, height: 214)).fill()
        NSColor(red: 0.08, green: 0.38, blue: 0.28, alpha: 1).setStroke()
        let check = NSBezierPath(); check.move(to: NSPoint(x: 712, y: 344)); check.line(to: NSPoint(x: 747, y: 308)); check.line(to: NSPoint(x: 811, y: 380)); check.lineWidth = 22; check.lineCapStyle = .round; check.lineJoinStyle = .round; check.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
