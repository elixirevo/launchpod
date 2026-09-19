import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
// Draw an original vector-based icon; no Apple artwork is redistributed.
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size*scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let n = CGFloat(pixels)
        let rect = NSRect(x: n*0.08, y: n*0.08, width: n*0.84, height: n*0.84)
        let shape = NSBezierPath(roundedRect: rect, xRadius: n*0.19, yRadius: n*0.19)
        NSGradient(starting: NSColor(calibratedRed: 0.17, green: 0.55, blue: 0.92, alpha: 1),
                   ending: NSColor(calibratedRed: 0.23, green: 0.22, blue: 0.62, alpha: 1))!.draw(in: shape, angle: 80)
        for row in 0..<3 {
            for col in 0..<3 {
                NSColor.white.withAlphaComponent(0.92-Double(row)*0.12).setFill()
                NSBezierPath(roundedRect: NSRect(x: n*(0.225+Double(col)*0.2), y: n*(0.225+Double(row)*0.2),
                                                width: n*0.15, height: n*0.15), xRadius: n*0.037, yRadius: n*0.037).fill()
            }
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
