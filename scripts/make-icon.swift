import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let tile = NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 210, yRadius: 210)
        NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.34, blue: 0.38, alpha: 1), ending: NSColor(calibratedRed: 0.04, green: 0.13, blue: 0.20, alpha: 1))!.draw(in: tile, angle: -70)

        let tablet = NSBezierPath(roundedRect: NSRect(x: 180, y: 235, width: 650, height: 490), xRadius: 55, yRadius: 55)
        NSColor(calibratedRed: 0.08, green: 0.22, blue: 0.27, alpha: 1).setFill()
        tablet.fill()
        NSColor(calibratedWhite: 0.96, alpha: 0.9).setStroke()
        tablet.lineWidth = 26; tablet.stroke()
        NSColor(calibratedRed: 0.40, green: 0.85, blue: 0.78, alpha: 1).setFill()
        for x in [254, 322, 390, 458] {
            NSBezierPath(ovalIn: NSRect(x: x, y: 659, width: 23, height: 23)).fill()
        }
        NSColor(calibratedWhite: 1, alpha: 0.1).setStroke()
        let surface = NSBezierPath(roundedRect: NSRect(x: 230, y: 285, width: 550, height: 325), xRadius: 24, yRadius: 24)
        surface.lineWidth = 8; surface.stroke()

        let pen = NSBezierPath()
        pen.move(to: NSPoint(x: 429, y: 388))
        pen.line(to: NSPoint(x: 748, y: 781))
        pen.lineWidth = 78; pen.lineCapStyle = .round
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 22; shadow.shadowOffset = NSSize(width: 0, height: -14); shadow.set()
        NSColor(calibratedWhite: 0.98, alpha: 1).setStroke(); pen.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let nib = NSBezierPath()
        nib.move(to: NSPoint(x: 374, y: 321))
        nib.line(to: NSPoint(x: 400, y: 412))
        nib.line(to: NSPoint(x: 458, y: 365))
        nib.close()
        NSColor(calibratedWhite: 0.98, alpha: 1).setFill(); nib.fill()
        let grip = NSBezierPath()
        grip.move(to: NSPoint(x: 477, y: 447)); grip.line(to: NSPoint(x: 490, y: 463))
        grip.lineWidth = 80
        NSColor(calibratedRed: 0.40, green: 0.85, blue: 0.78, alpha: 1).setStroke(); grip.stroke()

        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
