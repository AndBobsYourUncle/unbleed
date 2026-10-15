// Draws Unbleed's artwork in code (so every size is crisp): the app icon set, the menu bar template
// icon, and the installer background.  usage: make_branding <outdir>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/branding"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

let cyan: UInt32 = 0x2BE4FF, violet: UInt32 = 0x9B5CFF, pink: UInt32 = 0xFF4FD8

func render(_ px: Int, _ draw: (CGContext, CGFloat) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    draw(ctx, CGFloat(px) / 1024)  // everything is designed on a 1024 grid
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

// Deterministic jitter so the particles look organic but identical on every build.
struct Rng {
    var state: UInt64
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((state >> 33) & 0xffffff) / CGFloat(0xffffff)
    }
}

// The waveform: speech-like envelope, 9 bars. Bars 0-3 are "bleed" (dissolving), 4-8 are clean voice.
let heights: [CGFloat] = [0.30, 0.48, 0.66, 0.84, 1.00, 0.74, 0.54, 0.38, 0.24]
let barW: CGFloat = 50, gap: CGFloat = 28, maxH: CGFloat = 470
let firstX = 512 - (CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap) / 2

func drawIcon(_ ctx: CGContext, _ s: CGFloat) {
    ctx.scaleBy(x: s, y: s)
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // drop shadow under the tile
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.45))
    ctx.addPath(shape); ctx.setFillColor(color(0x0B0A1A)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    // deep night background
    let bg = CGGradient(colorsSpace: nil, colors: [color(0x231247), color(0x0C0B1E)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // glow behind the clean half
    let glow = CGGradient(colorsSpace: nil, colors: [color(violet, 0.55), color(cyan, 0.12), color(cyan, 0)] as CFArray,
                          locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 600, y: 512), startRadius: 0,
                           endCenter: CGPoint(x: 600, y: 512), endRadius: 430, options: [])

    // bleed: bars dissolving into particles that drift left and fade
    var rng = Rng(state: 0x5EED)
    for i in 0..<4 {
        let h = heights[i] * maxH
        let cx = firstX + CGFloat(i) * (barW + gap) + barW / 2
        let solidness = CGFloat(i) / 4  // nearer the seam = more intact
        let dots = Int(10 + 10 * solidness)
        for d in 0..<dots {
            let t = (CGFloat(d) + 0.5) / CGFloat(dots)
            let y = 512 - h / 2 + t * h
            let drift = (1 - solidness) * 70 * rng.next()
            let x = cx - drift + (rng.next() - 0.5) * 18
            let r = (barW / 2) * (0.30 + 0.45 * solidness) * (0.6 + 0.4 * rng.next())
            let a = 0.18 + 0.42 * solidness * (0.5 + 0.5 * rng.next())
            ctx.setFillColor(color(0xB9A8FF, a))
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        }
    }

    // seam of light between bleed and voice
    let seamX = firstX + 4 * (barW + gap) - gap / 2
    let seam = CGGradient(colorsSpace: nil, colors: [color(0xFFFFFF, 0), color(0xFFFFFF, 0.55), color(0xFFFFFF, 0)] as CFArray,
                          locations: [0, 0.5, 1])!
    ctx.saveGState()
    ctx.clip(to: CGRect(x: seamX - 2.5, y: 230, width: 5, height: 564))
    ctx.drawLinearGradient(seam, start: CGPoint(x: seamX, y: 230), end: CGPoint(x: seamX, y: 794), options: [])
    ctx.restoreGState()

    // voice: clean gradient capsules with a neon glow
    let voice = CGGradient(colorsSpace: nil, colors: [color(cyan), color(violet), color(pink)] as CFArray,
                           locations: [0, 0.55, 1])!
    for i in 4..<heights.count {
        let h = heights[i] * maxH
        let x = firstX + CGFloat(i) * (barW + gap)
        let bar = CGPath(roundedRect: CGRect(x: x, y: 512 - h / 2, width: barW, height: h),
                         cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 34, color: color(cyan, 0.65))
        ctx.addPath(bar); ctx.setFillColor(color(violet)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(bar); ctx.clip()
        ctx.drawLinearGradient(voice, start: CGPoint(x: 0, y: 512 + maxH / 2), end: CGPoint(x: 0, y: 512 - maxH / 2), options: [])
        ctx.restoreGState()
    }

    // glassy top sheen
    let sheen = CGGradient(colorsSpace: nil, colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
    ctx.restoreGState()

    // hairline edge
    ctx.addPath(shape); ctx.setStrokeColor(color(0xFFFFFF, 0.08)); ctx.setLineWidth(3); ctx.strokePath()
}

// Menu bar template: same idea in miniature — two dotted bars, three solid ones. Black + alpha only.
func drawMenuIcon(_ ctx: CGContext, _ px: CGFloat) {
    let u = px / 18  // 18 pt grid
    let hs: [CGFloat] = [7, 10, 14, 10, 6]
    let w: CGFloat = 2.2 * u, step: CGFloat = 3.4 * u
    let x0 = (px - (4 * step + w)) / 2
    ctx.setFillColor(color(0x000000))
    for (i, h) in hs.enumerated() {
        let x = x0 + CGFloat(i) * step, hh = h * u, y = (px - hh) / 2
        if i < 2 {  // bleed: dotted
            let n = i == 0 ? 2 : 3
            for d in 0..<n {
                let cy = y + (CGFloat(d) + 0.5) * hh / CGFloat(n)
                let r = w * (i == 0 ? 0.38 : 0.45)
                ctx.setAlpha(i == 0 ? 0.55 : 0.8)
                ctx.fillEllipse(in: CGRect(x: x + w / 2 - r, y: cy - r, width: 2 * r, height: 2 * r))
            }
            ctx.setAlpha(1)
        } else {
            ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: hh), cornerWidth: w / 2,
                               cornerHeight: w / 2, transform: nil))
            ctx.fillPath()
        }
    }
}

// --- app icon set ---
let iconset = "\(out)/Unbleed.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    save(render(size, drawIcon), "\(iconset)/icon_\(size)x\(size).png")
    save(render(size * 2, drawIcon), "\(iconset)/icon_\(size)x\(size)@2x.png")
}
save(render(1024, drawIcon), "\(out)/Unbleed-1024.png")

// --- menu bar template (18 pt) ---
for (scale, name) in [(1, "MenuBarIcon.png"), (2, "MenuBarIcon@2x.png")] {
    let px = 18 * scale
    let rep = render(px) { ctx, _ in drawMenuIcon(ctx, CGFloat(px)) }
    save(rep, "\(out)/\(name)")
}

// --- installer background (bottom-left aligned in the Installer window) ---
let bgW = 620, bgH = 418
let bgRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: bgW * 2, pixelsHigh: bgH * 2, bitsPerSample: 8,
                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                             bytesPerRow: 0, bitsPerPixel: 0)!
bgRep.size = NSSize(width: bgW, height: bgH)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bgRep)
do {
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: 2, y: 2)
    // a faint, oversized icon peeking in from the bottom-left corner
    ctx.saveGState()
    ctx.setAlpha(0.22)
    ctx.translateBy(x: -60, y: -70)
    drawIcon(ctx, 0.30)
    ctx.restoreGState()
}
NSGraphicsContext.restoreGraphicsState()
save(bgRep, "\(out)/installer-background.png")

print("artwork written to \(out)")
