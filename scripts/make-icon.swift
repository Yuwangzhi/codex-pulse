import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let size = CGFloat(pixels)
        let rect = NSRect(x: size * 0.06, y: size * 0.06, width: size * 0.88, height: size * 0.88)
        NSColor(calibratedRed: 0.08, green: 0.16, blue: 0.15, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: size * 0.21, yRadius: size * 0.21).fill()
        let path = NSBezierPath()
        let coords: [(CGFloat, CGFloat)] = [(0.20,0.50),(0.34,0.50),(0.43,0.72),(0.55,0.28),(0.65,0.50),(0.80,0.50)]
        path.move(to: NSPoint(x: coords[0].0 * size, y: coords[0].1 * size))
        for (x,y) in coords.dropFirst() { path.line(to: NSPoint(x:x * size,y:y * size)) }
        path.lineWidth = size * 0.065; path.lineJoinStyle = .round; path.lineCapStyle = .round
        NSColor(calibratedRed: 0.32, green: 0.89, blue: 0.68, alpha: 1).setStroke(); path.stroke()
        image.unlockFocus()
        let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try representation.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
