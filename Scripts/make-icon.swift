#!/usr/bin/env swift
// Renders the app icon and writes Resources/AppIcon.icns. Usage: swift Scripts/make-icon.swift
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func linearGradient(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [])
}

/// A page with a folded top-right corner.
func pagePath(_ rect: CGRect, fold: CGFloat, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
    p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: radius)
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - fold))
    p.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.maxY))
    p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: radius)
    p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: radius)
    p.closeSubpath()
    return p
}

func drawArrowArc(_ ctx: CGContext, center: CGPoint, radius: CGFloat, from start: CGFloat, to end: CGFloat) {
    let a0 = start * .pi / 180, a1 = end * .pi / 180
    ctx.addArc(center: center, radius: radius, startAngle: a0, endAngle: a1, clockwise: false)
    ctx.strokePath()
    let tip = CGPoint(x: center.x + radius * cos(a1), y: center.y + radius * sin(a1))
    let direction = CGPoint(x: -sin(a1), y: cos(a1))
    let normal = CGPoint(x: cos(a1), y: sin(a1))
    let head: CGFloat = 30
    ctx.move(to: CGPoint(x: tip.x + direction.x * head, y: tip.y + direction.y * head))
    ctx.addLine(to: CGPoint(x: tip.x + normal.x * head - direction.x * 4, y: tip.y + normal.y * head - direction.y * 4))
    ctx.addLine(to: CGPoint(x: tip.x - normal.x * head - direction.x * 4, y: tip.y - normal.y * head - direction.y * 4))
    ctx.closePath()
    ctx.fillPath()
}

func drawIcon(_ ctx: CGContext) {
    // Background squircle (macOS icon grid: 824pt body inside 1024pt canvas).
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = roundedRect(body, 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x2563EB))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    linearGradient(ctx, [color(0x5B9BFF), color(0x1D4ED8)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    ctx.restoreGState()

    // Back side of the sheet, tilted behind.
    let pageRect = CGRect(x: 312, y: 238, width: 380, height: 500)
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 488)
    ctx.rotate(by: 9 * .pi / 180)
    ctx.translateBy(x: -512 + 34, y: -488 + 26)
    ctx.addPath(pagePath(pageRect, fold: 0, radius: 26))
    ctx.setFillColor(color(0xFFFFFF, 0.45))
    ctx.fillPath()
    ctx.restoreGState()

    // Front page.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x0B1F5C, 0.45))
    ctx.addPath(pagePath(pageRect, fold: 96, radius: 26))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.move(to: CGPoint(x: pageRect.maxX - 96, y: pageRect.maxY))
    ctx.addLine(to: CGPoint(x: pageRect.maxX - 96, y: pageRect.maxY - 80))
    ctx.addArc(tangent1End: CGPoint(x: pageRect.maxX - 96, y: pageRect.maxY - 96),
               tangent2End: CGPoint(x: pageRect.maxX, y: pageRect.maxY - 96), radius: 16)
    ctx.addLine(to: CGPoint(x: pageRect.maxX, y: pageRect.maxY - 96))
    ctx.closePath()
    ctx.setFillColor(color(0xCBD5E1))
    ctx.fillPath()

    // Text lines.
    ctx.setFillColor(color(0xCBD5E1))
    for (i, width) in [210, 290, 260, 300, 180, 280, 240].enumerated() {
        let y = pageRect.maxY - 150 - CGFloat(i) * 46
        ctx.addPath(roundedRect(CGRect(x: pageRect.minX + 44, y: y, width: CGFloat(width), height: 20), 10))
    }
    ctx.fillPath()

    // Scan beam with the already-scanned area tinted above it.
    let beamY: CGFloat = 470
    ctx.saveGState()
    ctx.addPath(pagePath(pageRect, fold: 96, radius: 26))
    ctx.clip()
    linearGradient(ctx, [color(0x22D3EE, 0.0), color(0x22D3EE, 0.28)],
                   from: CGPoint(x: 0, y: beamY + 150), to: CGPoint(x: 0, y: beamY))
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 28, color: color(0x22D3EE, 0.9))
    ctx.addPath(roundedRect(CGRect(x: pageRect.minX - 34, y: beamY - 9, width: pageRect.width + 68, height: 18), 9))
    ctx.setFillColor(color(0x67E8F9))
    ctx.fillPath()
    ctx.restoreGState()

    // Duplex badge: two arrows turning the sheet over.
    let badge = CGPoint(x: 706, y: 300)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: color(0x000000, 0.35))
    ctx.addEllipse(in: CGRect(x: badge.x - 128, y: badge.y - 128, width: 256, height: 256))
    ctx.setFillColor(color(0xFF9F0A))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: badge.x - 128, y: badge.y - 128, width: 256, height: 256))
    ctx.clip()
    linearGradient(ctx, [color(0xFFB340), color(0xF97316)], from: CGPoint(x: badge.x, y: badge.y + 128), to: CGPoint(x: badge.x, y: badge.y - 128))
    ctx.restoreGState()
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.setLineWidth(24)
    ctx.setLineCap(.round)
    drawArrowArc(ctx, center: badge, radius: 66, from: 30, to: 150)
    drawArrowArc(ctx, center: badge, radius: 66, from: 210, to: 330)
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(pixels: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(pixels: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try render(pixels: 1024).write(to: root.appendingPathComponent("Resources/AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
