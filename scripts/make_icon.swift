// Renders the NetCatch app icon at all required sizes.
//
//   swift scripts/make_icon.swift                -> full set into the asset catalog
//   swift scripts/make_icon.swift preview        -> single 1024 preview to /tmp
//
// Design: a Big Sur-style gradient squircle (indigo -> cyan) with Bonjour signal
// arcs and a white geometric cat face (netCATch), eyes/nose as gradient cut-outs.

import Foundation
import CoreGraphics
import ImageIO

let outputDir = "NetCatch/Resources/Assets.xcassets/AppIcon.appiconset"
let previewMode = CommandLine.arguments.contains("preview")
let sizes = previewMode ? [1024] : [16, 32, 64, 128, 256, 512, 1024]

func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!

/// Linear gradient + top highlight covering the current clip, in a `ts`-sized space.
func fillBackground(_ ctx: CGContext, _ ts: CGFloat) {
    let bg = CGGradient(colorsSpace: cs,
                        colors: [srgb(0.36, 0.26, 0.92), srgb(0.20, 0.45, 0.95), srgb(0.05, 0.78, 0.80)] as CFArray,
                        locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: ts), end: CGPoint(x: ts, y: 0), options: [])
    let hl = CGGradient(colorsSpace: cs,
                        colors: [srgb(1, 1, 1, 0.22), srgb(1, 1, 1, 0)] as CFArray,
                        locations: [0, 1])!
    ctx.drawRadialGradient(hl, startCenter: CGPoint(x: ts * 0.5, y: ts * 0.86), startRadius: 0,
                           endCenter: CGPoint(x: ts * 0.5, y: ts * 0.86), endRadius: ts * 0.7, options: [])
}

func triangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGPath {
    let p = CGMutablePath()
    p.move(to: a); p.addLine(to: b); p.addLine(to: c); p.closeSubpath()
    return p
}

/// Draws a white cat face within `box` (the full head+ears bounds), with eyes and
/// nose punched out to reveal the gradient, and whiskers.
func drawCatFace(_ ctx: CGContext, box: CGRect, ts: CGFloat) {
    let bw = box.width, bh = box.height
    let cx = box.midX

    let headBottom = box.minY + bh * 0.02
    let headTop = box.minY + bh * 0.74
    let headRect = CGRect(x: box.minX + bw * 0.08, y: headBottom,
                          width: bw * 0.84, height: headTop - headBottom)
    let headPath = CGPath(ellipseIn: headRect, transform: nil)

    let leftEar = triangle(
        CGPoint(x: box.minX + bw * 0.16, y: box.maxY),
        CGPoint(x: box.minX + bw * 0.04, y: headTop - bh * 0.22),
        CGPoint(x: box.minX + bw * 0.42, y: headTop - bh * 0.02))
    let rightEar = triangle(
        CGPoint(x: box.maxX - bw * 0.16, y: box.maxY),
        CGPoint(x: box.maxX - bw * 0.04, y: headTop - bh * 0.22),
        CGPoint(x: box.maxX - bw * 0.42, y: headTop - bh * 0.02))

    // White silhouette (head + ears) with a soft shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -ts * 0.012), blur: ts * 0.03,
                  color: srgb(0.05, 0.08, 0.20, 0.30))
    ctx.setFillColor(srgb(1, 1, 1, 1))
    let silhouette = CGMutablePath()
    silhouette.addPath(headPath)
    silhouette.addPath(leftEar)
    silhouette.addPath(rightEar)
    ctx.addPath(silhouette)
    ctx.fillPath()  // nonzero: overlapping ears+head union cleanly
    ctx.restoreGState()

    // Eyes + nose as gradient cut-outs.
    let eyeY = headBottom + headRect.height * 0.56
    let eyeDX = bw * 0.19
    let eyeRX = bw * 0.075, eyeRY = bw * 0.105
    let leftEye = CGPath(ellipseIn: CGRect(x: cx - eyeDX - eyeRX, y: eyeY - eyeRY,
                                           width: eyeRX * 2, height: eyeRY * 2), transform: nil)
    let rightEye = CGPath(ellipseIn: CGRect(x: cx + eyeDX - eyeRX, y: eyeY - eyeRY,
                                            width: eyeRX * 2, height: eyeRY * 2), transform: nil)
    let noseY = eyeY - bh * 0.17
    let nose = triangle(
        CGPoint(x: cx - bw * 0.045, y: noseY + bh * 0.03),
        CGPoint(x: cx + bw * 0.045, y: noseY + bh * 0.03),
        CGPoint(x: cx, y: noseY - bh * 0.03))

    ctx.saveGState()
    let cutouts = CGMutablePath()
    cutouts.addPath(leftEye); cutouts.addPath(rightEye); cutouts.addPath(nose)
    ctx.addPath(cutouts)
    ctx.clip()
    fillBackground(ctx, ts)
    ctx.restoreGState()

    // Whiskers — white lines from beside the nose outward over the gradient.
    ctx.setStrokeColor(srgb(1, 1, 1, 0.92))
    ctx.setLineCap(.round)
    ctx.setLineWidth(ts * 0.010)
    let whiskerStartX = bw * 0.10
    for dy in [-0.035, 0.01, 0.055] as [CGFloat] {
        // left
        ctx.move(to: CGPoint(x: cx - whiskerStartX, y: noseY + bh * dy))
        ctx.addLine(to: CGPoint(x: box.minX - bw * 0.02, y: noseY + bh * (dy + 0.06)))
        ctx.strokePath()
        // right
        ctx.move(to: CGPoint(x: cx + whiskerStartX, y: noseY + bh * dy))
        ctx.addLine(to: CGPoint(x: box.maxX + bw * 0.02, y: noseY + bh * (dy + 0.06)))
        ctx.strokePath()
    }
}

func render(size px: Int) -> CGImage? {
    let s = CGFloat(px)
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    let pad = s * 0.085
    let ts = s - 2 * pad
    let tile = CGRect(x: pad, y: pad, width: ts, height: ts)
    let radius = ts * 0.2237
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Contact shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.018), blur: s * 0.05,
                  color: srgb(0.04, 0.06, 0.15, 0.35))
    ctx.addPath(tilePath); ctx.setFillColor(srgb(0, 0, 0, 1)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    ctx.translateBy(x: tile.minX, y: tile.minY)

    fillBackground(ctx, ts)

    // Bonjour signal waves radiating behind the cat.
    ctx.setLineCap(.round)
    let arcCenter = CGPoint(x: ts * 0.5, y: ts * 0.44)
    let radii: [CGFloat] = [0.34, 0.45, 0.56, 0.67]
    for (i, r) in radii.enumerated() {
        let alpha = 0.30 - CGFloat(i) * 0.05   // fade outward
        ctx.setStrokeColor(srgb(1, 1, 1, alpha))
        ctx.setLineWidth(ts * 0.020)
        ctx.addArc(center: arcCenter, radius: ts * r,
                   startAngle: .pi * 0.12, endAngle: .pi * 0.88, clockwise: false)
        ctx.strokePath()
    }

    // Cat face, centered, slightly low.
    let faceW = ts * 0.62
    let faceH = ts * 0.64
    let faceBox = CGRect(x: (ts - faceW) / 2, y: ts * 0.12, width: faceW, height: faceH)
    drawCatFace(ctx, box: faceBox, ts: ts)

    ctx.restoreGState()
    return ctx.makeImage()
}

func save(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

for px in sizes {
    guard let img = render(size: px) else { print("FAILED \(px)"); continue }
    if previewMode {
        save(img, to: "/tmp/netcatch_preview.png")
        print("wrote /tmp/netcatch_preview.png")
    } else {
        save(img, to: "\(outputDir)/icon_\(px).png")
        print("wrote icon_\(px).png")
    }
}
