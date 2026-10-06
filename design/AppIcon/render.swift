// PDFLite 应用图标渲染器：白底 + 几行深色文字 + 一道青柠荧光笔。
// 用 CoreGraphics 按参数直接绘制，各尺寸单独取细节层级并做像素对齐，无第三方依赖。
// 用法：swift render.swift <输出目录>

import AppKit
import CoreGraphics
import Foundation

// MARK: - 设计参数（单位：图标底板的 0…100，y 向下）

struct Palette {
    static let tileTop = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    static let tileBottom = CGColor(srgbRed: 0xEE / 255, green: 0xF0 / 255, blue: 0xF3 / 255, alpha: 1)
    static let edge = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.07)
    static let text = CGColor(srgbRed: 0x3A / 255, green: 0x45 / 255, blue: 0x60 / 255, alpha: 1)
    static let textOnHighlight = CGColor(srgbRed: 0x1D / 255, green: 0x2B / 255, blue: 0x4B / 255, alpha: 1)
    static let highlight = CGColor(srgbRed: 0xC8 / 255, green: 0xF0 / 255, blue: 0x3C / 255, alpha: 1)
}

struct Bar { var x: CGFloat; var y: CGFloat; var w: CGFloat; var h: CGFloat }

struct Detail {
    var lines: [Bar]
    var highlightedLine: Bar
    // 荧光笔：上沿 y、下沿 y、左右 x 与斜切量
    var bandTop: CGFloat
    var bandBottom: CGFloat
    var bandLeft: CGFloat
    var bandRight: CGFloat
    var slant: CGFloat
    var snap: Bool

    /// ≥64px：五行文字，第三行被划过。
    static let full = Detail(
        lines: [Bar(x: 22, y: 26, w: 56, h: 3.6), Bar(x: 22, y: 35, w: 56, h: 3.6),
                Bar(x: 22, y: 62, w: 56, h: 3.6), Bar(x: 22, y: 71, w: 36, h: 3.6)],
        highlightedLine: Bar(x: 22, y: 46.2, w: 56, h: 3.6),
        bandTop: 42, bandBottom: 54, bandLeft: 15, bandRight: 86, slant: 3, snap: false)

    /// 32/48px：三行加粗。
    static let medium = Detail(
        lines: [Bar(x: 22, y: 25, w: 56, h: 6.4), Bar(x: 22, y: 68.6, w: 40, h: 6.4)],
        highlightedLine: Bar(x: 22, y: 46.8, w: 56, h: 6.4),
        bandTop: 38, bandBottom: 62, bandLeft: 14, bandRight: 87, slant: 3.5, snap: true)

    /// 16px：三道 1px 级横线，中间一道压在荧光带上。
    static let small = Detail(
        lines: [Bar(x: 21, y: 22, w: 58, h: 9), Bar(x: 21, y: 69, w: 42, h: 9)],
        highlightedLine: Bar(x: 21, y: 45.5, w: 58, h: 9),
        bandTop: 36, bandBottom: 64, bandLeft: 12, bandRight: 88, slant: 0, snap: true)

    static func forTile(pixels: CGFloat) -> Detail {
        if pixels >= 50 { return .full }
        if pixels >= 22 { return .medium }
        return .small
    }
}

enum Layout {
    /// macOS 图标网格：1024 画布中底板 824，四周留 100。
    case macOS
    /// 浏览器扩展：底板占满大部分画布，无投影。
    case browserExtension

    var tileFraction: CGFloat { self == .macOS ? 824.0 / 1024.0 : 0.875 }
    var hasShadow: Bool { self == .macOS }
}

// MARK: - 绘制

/// 连续圆角底板：直边 + 四角各一段四分之一超椭圆（曲率在与直边相接处为 0，没有圆角矩形的折点）。
/// 圆角半径取边长 22.5%，拐角延伸 1.528r，指数 3.26 使对角线处内缩与同半径圆角一致。
func squirclePath(in rect: CGRect) -> CGPath {
    let r = rect.width * 0.225
    let reach = 1.528 * r
    let n: CGFloat = 3.26
    let path = CGMutablePath()
    // 每个角：中心与朝外方向（y 向下）
    let corners: [(CGPoint, CGFloat, CGFloat, CGFloat)] = [
        (CGPoint(x: rect.maxX - reach, y: rect.minY + reach), 1, -1, -.pi / 2),  // 右上
        (CGPoint(x: rect.maxX - reach, y: rect.maxY - reach), 1, 1, 0),          // 右下
        (CGPoint(x: rect.minX + reach, y: rect.maxY - reach), -1, 1, .pi / 2),   // 左下
        (CGPoint(x: rect.minX + reach, y: rect.minY + reach), -1, -1, .pi),      // 左上
    ]
    let steps = 90
    for (index, corner) in corners.enumerated() {
        let (center, sx, sy, start) = corner
        for i in 0...steps {
            let t = start + CGFloat(i) / CGFloat(steps) * .pi / 2
            let c = abs(cos(t)), s = abs(sin(t))
            let p = CGPoint(x: center.x + sx * reach * pow(c, 2 / n), y: center.y + sy * reach * pow(s, 2 / n))
            if index == 0 && i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
    }
    path.closeSubpath()
    return path
}

func renderIcon(size: Int, layout: Layout) -> CGImage {
    let S = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // 翻转为 y 向下，与设计参数一致
    ctx.translateBy(x: 0, y: S)
    ctx.scaleBy(x: 1, y: -1)

    let tileSide = (S * layout.tileFraction).rounded()
    let origin = ((S - tileSide) / 2).rounded()
    let tile = CGRect(x: origin, y: origin, width: tileSide, height: tileSide)
    let unit = tileSide / 100
    let detail = Detail.forTile(pixels: tileSide)
    let tilePath = squirclePath(in: tile)

    func px(_ u: CGFloat) -> CGFloat { u * unit }
    func snapped(_ r: CGRect) -> CGRect {
        guard detail.snap else { return r }
        let y0 = r.minY.rounded(), h = max(1, r.height.rounded())
        return CGRect(x: r.minX.rounded(), y: y0, width: r.width.rounded(), height: h)
    }

    // 底板投影（CG 的阴影偏移不受 CTM 影响，负 y 即向下）
    if layout.hasShadow {
        ctx.saveGState()
        let k = S / 1024
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: max(1, 24 * k),
                      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: size <= 32 ? 0.18 : 0.26))
        ctx.addPath(tilePath)
        ctx.setFillColor(Palette.tileTop)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 底板：自上而下的极浅渐变
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [Palette.tileTop, Palette.tileBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])

    func bar(_ b: Bar, _ color: CGColor) {
        let r = snapped(CGRect(x: tile.minX + px(b.x), y: tile.minY + px(b.y), width: px(b.w), height: px(b.h)))
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil))
        ctx.fillPath()
    }

    for line in detail.lines { bar(line, Palette.text) }

    // 荧光笔：平行四边形，两端同向斜切；一端伸出文字行，像刚划过
    var top = tile.minY + px(detail.bandTop), bottom = tile.minY + px(detail.bandBottom)
    if detail.snap { top = top.rounded(); bottom = bottom.rounded() }
    let left = tile.minX + px(detail.bandLeft), right = tile.minX + px(detail.bandRight), slant = px(detail.slant)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: left + slant, y: top))
    ctx.addLine(to: CGPoint(x: right, y: top))
    ctx.addLine(to: CGPoint(x: right - slant, y: bottom))
    ctx.addLine(to: CGPoint(x: left, y: bottom))
    ctx.closePath()
    ctx.setFillColor(Palette.highlight)
    ctx.fillPath()

    bar(detail.highlightedLine, Palette.textOnHighlight)

    // 内描边：白底在浅色程序坞上也能看出边界
    ctx.addPath(tilePath)
    ctx.setStrokeColor(Palette.edge)
    ctx.setLineWidth(max(1, 2 * S / 1024) * 2)
    ctx.strokePath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// MARK: - 预览拼图：浅色 / 深色背景各一行

func renderPreview() -> CGImage {
    let sizes = [128, 64, 32, 16]
    let scale = 2, pad = 24, gap = 28
    let rowH = 128 + pad * 2
    let width = pad * 2 + sizes.reduce(0, +) + gap * (sizes.count - 1)
    let W = width * scale, H = rowH * 2 * scale
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let backgrounds = [CGColor(srgbRed: 0.925, green: 0.925, blue: 0.933, alpha: 1),
                       CGColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)]
    for (row, bg) in backgrounds.enumerated() {
        let y0 = (1 - row) * rowH * scale
        ctx.setFillColor(bg)
        ctx.fill(CGRect(x: 0, y: y0, width: W, height: rowH * scale))
        var x = pad
        for s in sizes {
            // 按 Retina 绘制：逻辑尺寸 s 用 2s 像素的位图
            let img = renderIcon(size: s * scale, layout: .macOS)
            ctx.draw(img, in: CGRect(x: x * scale, y: y0 + (pad + (128 - s) / 2) * scale, width: s * scale, height: s * scale))
            x += s + gap
        }
    }
    return ctx.makeImage()!
}

// MARK: - 入口

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("用法：swift render.swift <输出目录>\n".data(using: .utf8)!)
    exit(64)
}
let out = URL(fileURLWithPath: args[1], isDirectory: true)
let iconset = out.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let ext = out.appendingPathComponent("extension", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: ext, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    writePNG(renderIcon(size: base, layout: .macOS), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(renderIcon(size: base * 2, layout: .macOS), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
for s in [16, 32, 48, 128] {
    writePNG(renderIcon(size: s, layout: .browserExtension), to: ext.appendingPathComponent("icon\(s).png"))
}
writePNG(renderIcon(size: 1024, layout: .macOS), to: out.appendingPathComponent("source.png"))
writePNG(renderPreview(), to: out.appendingPathComponent("preview.png"))
print("Rendered icons into \(out.path)")
