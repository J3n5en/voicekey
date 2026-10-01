// 生成 App 图标：swift Scripts/icon.swift <out.png>，1024×1024
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// 圆角底板（macOS 图标网格：824 见方，四周留白 100）
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let platePath = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(platePath)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(platePath)
ctx.clip()
let bg = CGGradient(colorsSpace: nil, colors: [
    NSColor(red: 0.10, green: 0.11, blue: 0.22, alpha: 1).cgColor,
    NSColor(red: 0.04, green: 0.04, blue: 0.10, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])

// 与 HUD 一致的多层声波，青→蓝→紫→粉
let colors = [NSColor.cyan, NSColor.systemBlue, NSColor.purple, NSColor.systemPink].map(\.cgColor)
let wave = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.35, 0.7, 1])!
let layers: [(freq: CGFloat, phase: CGFloat, amp: CGFloat, width: CGFloat, alpha: CGFloat)] = [
    (1.0, 2.2, 0.45, 14, 0.35), (2.2, -1.0, 0.65, 18, 0.55), (1.5, 0.6, 1.0, 30, 1.0),
]
let left: CGFloat = 170, right: CGFloat = 854, mid: CGFloat = 512, maxAmp: CGFloat = 230
for l in layers {
    let path = CGMutablePath()
    for i in 0...400 {
        let p = CGFloat(i) / 400
        let x = left + (right - left) * p
        let env = pow(sin(.pi * p), 2)
        let y = mid + sin(p * .pi * 2 * l.freq + l.phase) * maxAmp * l.amp * env
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    ctx.saveGState()
    ctx.setAlpha(l.alpha)
    ctx.addPath(path.copy(strokingWithWidth: l.width, lineCap: .round, lineJoin: .round, miterLimit: 10))
    ctx.clip()
    ctx.drawLinearGradient(wave, start: CGPoint(x: left, y: 0), end: CGPoint(x: right, y: 0), options: [])
    ctx.restoreGState()
}

// 顶部高光
let gloss = CGGradient(colorsSpace: nil, colors: [
    NSColor.white.withAlphaComponent(0.10).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 600), options: [])
ctx.restoreGState()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
