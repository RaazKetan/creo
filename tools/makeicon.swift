import AppKit

private func piece(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

private func gradient(_ colors: [NSColor], in path: NSBezierPath) {
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: colors)?.draw(in: path.bounds, angle: 90)
    NSGraphicsContext.restoreGraphicsState()
}

/// Render the supplied Creo identity natively at every icon size: warm white tile,
/// orange/red puzzle pieces, and transparent notches cut into the outer pieces.
func icon(_ side: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()

    let inset = side * 0.075
    let plate = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let platePath = NSBezierPath(roundedRect: plate, xRadius: side * 0.205, yRadius: side * 0.205)
    NSColor(srgbRed: 0.995, green: 0.987, blue: 0.965, alpha: 1).setFill()
    platePath.fill()
    NSColor(srgbRed: 0.88, green: 0.86, blue: 0.81, alpha: 0.55).setStroke()
    platePath.lineWidth = max(1, side * 0.002)
    platePath.stroke()

    let unit = plate.width * 0.69
    let x = plate.midX - unit / 2, y = plate.midY - unit / 2
    let radius = unit * 0.105
    let top = piece(NSRect(x: x + unit * 0.46, y: y + unit * 0.51,
                           width: unit * 0.44, height: unit * 0.41), radius: radius)
    let lower = piece(NSRect(x: x + unit * 0.10, y: y + unit * 0.09,
                             width: unit * 0.42, height: unit * 0.42), radius: radius)
    let upperSmall = piece(NSRect(x: x + unit * 0.28, y: y + unit * 0.54,
                                  width: unit * 0.18, height: unit * 0.18),
                           radius: unit * 0.07)
    let lowerSmall = piece(NSRect(x: x + unit * 0.53, y: y + unit * 0.27,
                                  width: unit * 0.20, height: unit * 0.23),
                           radius: unit * 0.07)

    gradient([NSColor(srgbRed: 1.00, green: 0.37, blue: 0.08, alpha: 1),
              NSColor(srgbRed: 0.88, green: 0.10, blue: 0.04, alpha: 1)], in: top)
    gradient([NSColor(srgbRed: 1.00, green: 0.72, blue: 0.25, alpha: 1),
              NSColor(srgbRed: 1.00, green: 0.49, blue: 0.10, alpha: 1)], in: lower)
    gradient([NSColor(srgbRed: 1.00, green: 0.48, blue: 0.08, alpha: 1),
              NSColor(srgbRed: 0.95, green: 0.27, blue: 0.05, alpha: 1)], in: upperSmall)
    gradient([NSColor(srgbRed: 1.00, green: 0.45, blue: 0.08, alpha: 1),
              NSColor(srgbRed: 0.93, green: 0.23, blue: 0.04, alpha: 1)], in: lowerSmall)

    NSColor(srgbRed: 0.995, green: 0.987, blue: 0.965, alpha: 1).setFill()
    [NSPoint(x: x + unit * 0.68, y: y + unit * 0.92),
     NSPoint(x: x + unit * 0.10, y: y + unit * 0.30),
     NSPoint(x: x + unit * 0.63, y: y + unit * 0.27)].forEach { center in
        let notchRadius = unit * 0.052
        NSBezierPath(ovalIn: NSRect(x: center.x - notchRadius, y: center.y - notchRadius,
                                    width: notchRadius * 2, height: notchRadius * 2)).fill()
    }

    image.unlockFocus()
    return image
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

for (base, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                      (256, 1), (256, 2), (512, 1), (512, 2)] {
    let side = base * scale
    guard let tiff = icon(CGFloat(side)).tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    else { continue }
    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
    try png.write(to: out.appendingPathComponent(name))
}
print("wrote iconset to \(out.path)")
