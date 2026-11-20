// 给 1024 图标右下角加 "Full" 徽章：橙→粉渐变胶囊，呼应声波条配色
// 用法: badge <输入.png> <输出.png>
import Foundation
import CoreGraphics
import CoreText
import ImageIO

let args = CommandLine.arguments
guard args.count >= 3 else { exit(2) }
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])

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
let text = "Full" as CFString
let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 168, nil)
let attrs: [CFString: Any] = [
    kCTFontAttributeName: font,
    kCTForegroundColorAttributeName: CGColor.white
]
let attrStr = CFAttributedStringCreate(nil, text, attrs as CFDictionary)!
let line = CTLineCreateWithAttributedString(attrStr)
let tb = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

let pad: CGFloat = 64               // 距右/下边缘
let textW = ceil(tb.width)
let textH = ceil(tb.height)
let pillW = textW + 110
let pillH = textH + 80
let rect = CGRect(x: CS - pad - pillW, y: pad, width: pillW, height: pillH)
let radius = pillH / 2
let pillPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// 阴影 + 渐变填充
ctx.saveGState()
ctx.addPath(pillPath)
ctx.clip()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 30,
              color: CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(),
                             components: [0, 0, 0, 0.30])!)
let colors = [CGColor(red: 1.0, green: 0.62, blue: 0.27, alpha: 1),
              CGColor(red: 1.0, green: 0.28, blue: 0.42, alpha: 1)] as CFArray
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
