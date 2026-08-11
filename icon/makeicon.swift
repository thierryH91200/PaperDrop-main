// Generates the PaperDrop app icon (AudiobookForge visual style: flat
// vivid tile, bold white glyph, soft shadows) at all required sizes.
// Run: swift icon/makeicon.swift   (from apps/PaperDrop/)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: "icon/PaperDrop.iconset", isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // Flat tile with baked rounded corners (matches the reference icon)
    let bg = CGColor(red: 0.16, green: 0.48, blue: 0.93, alpha: 1)
    let tile = CGPath(
        roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
        cornerWidth: s * 0.225, cornerHeight: s * 0.225, transform: nil)
    ctx.addPath(tile)
    ctx.setFillColor(bg)
    ctx.fillPath()

    // Soft shadow under the white shapes
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.025,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

    // Page: white rounded rect, upper half (y measured from the top)
    func rect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat) -> CGPath {
        CGPath(
            roundedRect: CGRect(x: x * s, y: s - (y + h) * s, width: w * s, height: h * s),
            cornerWidth: r * s, cornerHeight: r * s, transform: nil)
    }
    ctx.addPath(rect(x: 0.29, y: 0.14, w: 0.42, h: 0.40, r: 0.035))
    ctx.fillPath()

    // Text lines: background-coloured bars cut into the page (no shadow)
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.setFillColor(bg)
    for (i, w) in [0.28, 0.28, 0.18].enumerated() {
        ctx.addPath(rect(
            x: 0.36, y: 0.22 + Double(i) * 0.09, w: w, h: 0.035, r: 0.0175))
        ctx.fillPath()
    }

    // Drop arrow: bold, centred below the page
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.025,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    let shaftW = 0.10, headW = 0.30, headTop = 0.72, apexY = 0.87, shaftTop = 0.585
    let path = CGMutablePath()
    func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * s, y: s - y * s) }
    path.move(to: pt(0.5 - shaftW / 2, shaftTop))
    path.addLine(to: pt(0.5 + shaftW / 2, shaftTop))
    path.addLine(to: pt(0.5 + shaftW / 2, headTop))
    path.addLine(to: pt(0.5 + headW / 2, headTop))
    path.addLine(to: pt(0.5, apexY))
    path.addLine(to: pt(0.5 - headW / 2, headTop))
    path.addLine(to: pt(0.5 - shaftW / 2, headTop))
    path.closeSubpath()
    ctx.addPath(path)
    ctx.fillPath()

    return ctx.makeImage()!
}

func write(_ image: CGImage, _ name: String) {
    let url = out.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

for base in [16, 32, 128, 256, 512] {
    write(draw(base), "icon_\(base)x\(base).png")
    write(draw(base * 2), "icon_\(base)x\(base)@2x.png")
}
print("iconset written to \(out.path)")
