import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let blue = NSColor(srgbRed: 0.05, green: 0.36, blue: 0.84, alpha: 1)
let white = NSColor(srgbRed: 0.98, green: 0.98, blue: 1, alpha: 1)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = base * scale
        let s = CGFloat(size)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let tile = NSRect(x: s * 0.09, y: s * 0.09, width: s * 0.82, height: s * 0.82)
        blue.setFill()
        NSBezierPath(roundedRect: tile, xRadius: s * 0.185, yRadius: s * 0.185).fill()

        white.setStroke()
        let arrows = NSBezierPath()
        arrows.lineWidth = s * 0.082
        arrows.lineCapStyle = .round
        arrows.lineJoinStyle = .round
        for (direction, row) in [(1.0, 0.625), (-1.0, 0.375)] {
            let tip = 0.5 + direction * 0.23
            let shoulder = tip - direction * 0.105
            arrows.move(to: NSPoint(x: s * (0.5 - direction * 0.17), y: s * row))
            arrows.line(to: NSPoint(x: s * tip, y: s * row))
            arrows.move(to: NSPoint(x: s * shoulder, y: s * (row + 0.105)))
            arrows.line(to: NSPoint(x: s * tip, y: s * row))
            arrows.line(to: NSPoint(x: s * shoulder, y: s * (row - 0.105)))
        }
        arrows.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(base)x\(base)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
