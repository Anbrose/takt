// Renders design/takt-handoff/prototype/Icon.dc.html + IconDark.dc.html (512 viewBox) at 1024×1024.
// Usage: swift apps/ios/scripts/make-icon.swift apps/ios/Takt/Assets.xcassets/AppIcon.appiconset
import AppKit

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func render(bg: UInt32, line: UInt32, ring: UInt32, dot: UInt32, to path: String) {
    let size = 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.scaleBy(x: 2, y: 2)
    ctx.translateBy(x: 0, y: 512); ctx.scaleBy(x: 1, y: -1) // SVG coordinates (y down)
    ctx.setFillColor(rgb(bg)); ctx.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
    ctx.setStrokeColor(rgb(line)); ctx.setLineWidth(46); ctx.setLineCap(.round)
    ctx.strokeLineSegments(between: [CGPoint(x: 132, y: 172), CGPoint(x: 380, y: 172)])
    ctx.strokeLineSegments(between: [CGPoint(x: 256, y: 172), CGPoint(x: 256, y: 372)])
    for x in [132.0, 256, 380] {
        let r = CGRect(x: x - 33, y: 172 - 33, width: 66, height: 66)
        ctx.setFillColor(rgb(bg)); ctx.fillEllipse(in: r)
        ctx.setStrokeColor(rgb(ring)); ctx.setLineWidth(18); ctx.strokeEllipse(in: r)
    }
    ctx.setFillColor(rgb(dot)); ctx.fillEllipse(in: CGRect(x: 256 - 42, y: 372 - 42, width: 84, height: 84))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let out = CommandLine.arguments[1]
render(bg: 0xE6397C, line: 0xFFFFFF, ring: 0xFFFFFF, dot: 0xFFFFFF, to: "\(out)/AppIcon.png")
render(bg: 0x1A1A1D, line: 0xF4F1F3, ring: 0xE6397C, dot: 0xE6397C, to: "\(out)/AppIcon-Dark.png")
print("ok")
