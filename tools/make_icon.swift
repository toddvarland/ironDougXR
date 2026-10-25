// Renders the ironDougXR app icon (1024x1024, opaque) to the path given as argv[1].
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let S = CGFloat(size)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

// Work in top-left origin coordinates
ctx.translateBy(x: 0, y: S)
ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space,
               colors: stops.map { rgb($0.0, $0.1) } as CFArray,
               locations: stops.map { $0.2 })!
}

let cx = S / 2
let floorY: CGFloat = 770      // centre of the base ring
let horizonY: CGFloat = 560
let orbY: CGFloat = 318
let orbR: CGFloat = 112

// 1. Background: deep night-blue to near black
ctx.drawLinearGradient(gradient([(0x16224A, 1, 0), (0x070B1C, 1, 0.55), (0x020308, 1, 1)]),
                       start: CGPoint(x: cx, y: 0), end: CGPoint(x: cx, y: S), options: [])

// Warm atmospheric glow behind the orb
ctx.drawRadialGradient(gradient([(0xFF7A1A, 0.38, 0), (0xFF5A00, 0.10, 0.45), (0xFF5A00, 0, 1)]),
                       startCenter: CGPoint(x: cx, y: orbY), startRadius: 0,
                       endCenter: CGPoint(x: cx, y: orbY), endRadius: 520, options: [])

// 2. Perspective floor grid, fading toward the horizon
ctx.saveGState()
ctx.clip(to: CGRect(x: 0, y: horizonY, width: S, height: S - horizonY))
ctx.setLineWidth(3)
let vanishing = CGPoint(x: cx, y: horizonY - 260)
for i in -9...9 {
    let xBottom = cx + CGFloat(i) * 150
    ctx.move(to: vanishing)
    ctx.addLine(to: CGPoint(x: xBottom, y: S + 40))
}
var y = horizonY + 8
var step: CGFloat = 14
while y < S + 20 {
    ctx.move(to: CGPoint(x: 0, y: y))
    ctx.addLine(to: CGPoint(x: S, y: y))
    y += step
    step *= 1.32
}
ctx.replacePathWithStrokedPath()
ctx.clip()
ctx.drawLinearGradient(gradient([(0x3FE0FF, 0, 0), (0x3FE0FF, 0.22, 0.45), (0x3FE0FF, 0.38, 1)]),
                       start: CGPoint(x: cx, y: horizonY), end: CGPoint(x: cx, y: S), options: [])
ctx.restoreGState()

// 3. Ripple rings on the floor (outer ones fainter)
func ellipse(rx: CGFloat, ry: CGFloat) -> CGRect {
    CGRect(x: cx - rx, y: floorY - ry, width: rx * 2, height: ry * 2)
}
for (rx, alpha, width) in [(440.0, 0.14, 8.0), (340.0, 0.30, 11.0)] as [(CGFloat, CGFloat, CGFloat)] {
    ctx.setStrokeColor(rgb(0xFF8A2A, alpha))
    ctx.setLineWidth(width)
    ctx.strokeEllipse(in: ellipse(rx: rx, ry: rx * 0.30))
}
// Glowing main ring
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 40, color: rgb(0xFF7A1A, 0.95))
ctx.setFillColor(rgb(0xFF8A2A, 0.22))
ctx.fillEllipse(in: ellipse(rx: 238, ry: 71))
ctx.setStrokeColor(rgb(0xFF9A3C))
ctx.setLineWidth(24)
ctx.strokeEllipse(in: ellipse(rx: 238, ry: 71))
ctx.restoreGState()

// 4. Pole
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 24, color: rgb(0xFFFFFF, 0.6))
let pole = CGRect(x: cx - 11, y: orbY, width: 22, height: floorY - orbY)
ctx.addPath(CGPath(roundedRect: pole, cornerWidth: 11, cornerHeight: 11, transform: nil))
ctx.clip()
ctx.drawLinearGradient(gradient([(0xB9C4D6, 1, 0), (0xFFFFFF, 1, 0.45), (0x8A96AA, 1, 1)]),
                       start: CGPoint(x: pole.minX, y: 0), end: CGPoint(x: pole.maxX, y: 0), options: [])
ctx.restoreGState()

// 5. Orb: halo, glowing body, specular highlight
ctx.drawRadialGradient(gradient([(0xFFB15C, 0.55, 0), (0xFF6A00, 0.18, 0.55), (0xFF6A00, 0, 1)]),
                       startCenter: CGPoint(x: cx, y: orbY), startRadius: orbR * 0.8,
                       endCenter: CGPoint(x: cx, y: orbY), endRadius: orbR * 2.6, options: [])
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: cx - orbR, y: orbY - orbR, width: orbR * 2, height: orbR * 2))
ctx.clip()
ctx.drawRadialGradient(gradient([(0xFFF6D8, 1, 0), (0xFFC060, 1, 0.28), (0xFF7A1A, 1, 0.68), (0xC2410C, 1, 1)]),
                       startCenter: CGPoint(x: cx - orbR * 0.32, y: orbY - orbR * 0.36), startRadius: 0,
                       endCenter: CGPoint(x: cx, y: orbY), endRadius: orbR, options: [])
ctx.restoreGState()
ctx.setFillColor(rgb(0xFFFFFF, 0.85))
ctx.fillEllipse(in: CGRect(x: cx - orbR * 0.52, y: orbY - orbR * 0.62, width: orbR * 0.42, height: orbR * 0.26))

// Pulse ring around the orb
ctx.setStrokeColor(rgb(0xFFB15C, 0.55))
ctx.setLineWidth(6)
ctx.strokeEllipse(in: CGRect(x: cx - orbR * 1.45, y: orbY - orbR * 1.45, width: orbR * 2.9, height: orbR * 2.9))
ctx.setStrokeColor(rgb(0xFFB15C, 0.22))
ctx.setLineWidth(4)
ctx.strokeEllipse(in: CGRect(x: cx - orbR * 1.9, y: orbY - orbR * 1.9, width: orbR * 3.8, height: orbR * 3.8))

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
precondition(CGImageDestinationFinalize(dest), "failed to write PNG")
print("wrote \(out.path)")
