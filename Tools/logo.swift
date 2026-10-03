import AppKit

/// A drop: a circle with a point straight above it, the sides tangent to the circle.
func drop(center c: CGPoint, radius r: CGFloat) -> CGPath {
    let d = r * 2.05
    let tip = CGPoint(x: c.x, y: c.y + d)
    let half = acos(r / d)
    let path = CGMutablePath()
    path.move(to: tip)
    path.addLine(to: CGPoint(x: c.x + r * sin(half), y: c.y + r * cos(half)))
    path.addArc(center: c, radius: r, startAngle: .pi / 2 - half, endAngle: .pi / 2 + half - 2 * .pi, clockwise: true)
    path.closeSubpath()
    return path
}

func render(size: Int, tile: Bool, to url: URL) {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if tile {
        // macOS icon grid: 824/1024 tile with a soft shadow.
        let inset = s * 100 / 1024
        let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let shape = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil)
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.addPath(shape); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
    }
    let scale: CGFloat = tile ? 1 : 1.3
    let c = CGPoint(x: s / 2, y: s * (tile ? 0.42 : 0.38))
    let layers: [(CGFloat, NSColor)] = [(0.205, NSColor(srgbRed: 0.231, green: 0.510, blue: 0.965, alpha: 1)),
                                        (0.150, NSColor(srgbRed: 0.659, green: 0.776, blue: 0.996, alpha: 1)),
                                        (0.105, NSColor.white)]
    for (index, (radius, color)) in layers.enumerated() {
        let r = s * radius * scale
        // Inner drops sit lower so the rings read evenly around the round part.
        let center = CGPoint(x: c.x, y: c.y - CGFloat(index) * s * 0.018 * scale)
        ctx.addPath(drop(center: center, radius: r)); ctx.setFillColor(color.cgColor); ctx.fillPath()
    }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
render(size: 1024, tile: true, to: out.appendingPathComponent("logo-1024.png"))
