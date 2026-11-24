// 给 1024 图标右下角加胶囊徽章（默认 LIVE，可传自定义文字）
// 用法: badge <输入.png> <输出.png> [文字]
// 历史：原为 make-full-badge.swift，只写死 "Full"（区分内嵌/精简两个变体）；
//       精简版已下线，唯一分发版本，徽章改为「LIVE」——对外表达「直播」而非内部变体。
import Foundation
import CoreGraphics
import CoreText
import ImageIO

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("用法: badge <输入.png> <输出.png> [文字]\n", stderr); exit(2)
}
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
let badgeText = args.count > 3 ? args[3] : "LIVE"

guard let src = CGImageSourceCreateWithURL(inURL as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    fputs("读图失败\n", stderr); exit(1)
}

let S = 1024
let CS = CGFloat(S)
let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8,
                    bytesPerRow: S * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high

// 1) 原图：用翻转坐标（左上原点）画，保持正向
ctx.saveGState()
ctx.translateBy(x: 0, y: CS)
ctx.scaleBy(x: 1, y: -1)
ctx.draw(img, in: CGRect(x: 0, y: 0, width: CS, height: CS))
ctx.restoreGState()

// 2) 徽章：回到原生坐标（左下原点、y 向上），文字才是正的
let text = badgeText as CFString
let fontSize: CGFloat = badgeText.count > 4 ? 104 : 108
let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
let attrs: [CFString: Any] = [
    kCTFontAttributeName: font,
    kCTForegroundColorAttributeName: CGColor.white,
    kCTKernAttributeName: 6.0
]
let attrStr = CFAttributedStringCreate(nil, text, attrs as CFDictionary)!
let line = CTLineCreateWithAttributedString(attrStr)
let tb = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

let pad: CGFloat = 58               // 距右/下边缘
let textW = ceil(tb.width)
let textH = ceil(tb.height)
let pillW = textW + 96
let pillH = textH + 66
let rect = CGRect(x: CS - pad - pillW, y: pad, width: pillW, height: pillH)
let radius = pillH / 2
let pillPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// 阴影 + 红色渐变填充（直播红：醒目且与品牌橙粉区分）
ctx.saveGState()
ctx.addPath(pillPath)
ctx.clip()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 30,
              color: CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(),
                             components: [0, 0, 0, 0.30])!)
let colors = [CGColor(red: 1.00, green: 0.27, blue: 0.23, alpha: 1),
              CGColor(red: 0.82, green: 0.03, blue: 0.10, alpha: 1)] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad,
                       start: CGPoint(x: rect.minX, y: rect.maxY),   // 左上 → 右下
                       end: CGPoint(x: rect.maxX, y: rect.minY),
                       options: [])
ctx.restoreGState()

// 白描边
ctx.saveGState()
ctx.addPath(pillPath)
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
ctx.setLineWidth(9)
ctx.strokePath()
ctx.restoreGState()

// 文字居中（原生 y 向上坐标，直接画就是正的）
ctx.textPosition = CGPoint(x: rect.midX - tb.width / 2 - tb.minX,
                           y: rect.midY - tb.height / 2 - tb.minY)
CTLineDraw(line, ctx)

let out = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, out, nil)
CGImageDestinationFinalize(dest)
print("badged -> \(outURL.path)")
