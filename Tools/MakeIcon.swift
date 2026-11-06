import AppKit

let target = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    let background = NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 220, yRadius: 220)
    NSGradient(starting: NSColor(red: 0.10, green: 0.17, blue: 0.22, alpha: 1), ending: NSColor(red: 0.035, green: 0.055, blue: 0.09, alpha: 1))!.draw(in: background, angle: -50)
    let points = [NSPoint(x: 278, y: 654), NSPoint(x: 746, y: 654), NSPoint(x: 512, y: 285)]
    let triangle = NSBezierPath()
    triangle.move(to: points[0]); triangle.line(to: points[1]); triangle.line(to: points[2]); triangle.close()
    triangle.lineWidth = 33
    triangle.lineJoinStyle = .round
    NSColor(red: 0.39, green: 0.87, blue: 0.72, alpha: 0.65).setStroke()
    triangle.stroke()
    NSColor(red: 0.39, green: 0.87, blue: 0.72, alpha: 1).setFill()
    for point in points { NSBezierPath(ovalIn: NSRect(x: point.x - 76, y: point.y - 76, width: 152, height: 152)).fill() }
    let center = NSBezierPath(roundedRect: NSRect(x: 449, y: 469, width: 126, height: 126), xRadius: 35, yRadius: 35)
    NSColor(red: 0.90, green: 1, blue: 0.97, alpha: 1).setFill()
    center.fill()
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let data = bitmap.representation(using: .png, properties: [:])!
    if size <= 512 { try data.write(to: target.appendingPathComponent("icon_\(size)x\(size).png")) }
    if size >= 32 { try data.write(to: target.appendingPathComponent("icon_\(size / 2)x\(size / 2)@2x.png")) }
}
