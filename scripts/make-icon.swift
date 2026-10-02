#!/usr/bin/env swift
// Draws the app icon: a winding trail cleared through dark fog, revealing a map,
// with a location dot at the end of the trail.
//
//     swift scripts/make-icon.swift Walker/Assets.xcassets/AppIcon.appiconset/AppIcon.png

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let side = CGFloat(size)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: colorSpace,
        components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha]
    )!
}

func makeContext() -> CGContext {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Draw with y pointing down, like a screen.
    context.translateBy(x: 0, y: side)
    context.scaleBy(x: 1, y: -1)
    return context
}

// The trail: from bottom-left, sweeping up to the dot near the top-right.
let trail = CGMutablePath()
trail.move(to: CGPoint(x: -60, y: 900))
trail.addCurve(to: CGPoint(x: 470, y: 600), control1: CGPoint(x: 200, y: 930), control2: CGPoint(x: 260, y: 640))
trail.addCurve(to: CGPoint(x: 700, y: 300), control1: CGPoint(x: 700, y: 555), control2: CGPoint(x: 520, y: 360))
let dot = CGPoint(x: 700, y: 300)
let trailWidth: CGFloat = 230

// MARK: Map revealed under the trail

func drawMap(in context: CGContext) {
    context.setFillColor(color(0xF4ECDB))
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))

    // Street grid, tilted.
    context.saveGState()
    context.translateBy(x: side / 2, y: side / 2)
    context.rotate(by: -0.42)
    context.setStrokeColor(color(0xFFFFFF))
    context.setLineCap(.butt)
    for (index, offset) in stride(from: -980, through: 980, by: 140).enumerated() {
        context.setLineWidth(index % 3 == 0 ? 20 : 10)
        context.move(to: CGPoint(x: CGFloat(offset) + 30, y: -900))
        context.addLine(to: CGPoint(x: CGFloat(offset) + 30, y: 900))
        context.move(to: CGPoint(x: -900, y: CGFloat(offset) + 65))
        context.addLine(to: CGPoint(x: 900, y: CGFloat(offset) + 65))
        context.strokePath()
    }
    context.restoreGState()

    // Park and water sit on top of the streets.
    context.setFillColor(color(0xB9DC9E))
    context.addPath(CGPath(roundedRect: CGRect(x: 365, y: 455, width: 175, height: 125), cornerWidth: 22, cornerHeight: 22, transform: nil))
    context.fillPath()
    context.setStrokeColor(color(0x9CCBEB))
    context.setLineWidth(50)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: 20, y: 560))
    context.addCurve(to: CGPoint(x: 440, y: 1100), control1: CGPoint(x: 220, y: 680), control2: CGPoint(x: 230, y: 930))
    context.strokePath()

    context.saveGState()
    context.translateBy(x: side / 2, y: side / 2)
    context.rotate(by: -0.42)
    // One main road in warm yellow.
    context.setStrokeColor(color(0xF6C85F))
    context.setLineWidth(26)
    context.move(to: CGPoint(x: -900, y: 135))
    context.addLine(to: CGPoint(x: 900, y: 135))
    context.strokePath()
    context.restoreGState()
}

// MARK: Soft-edged mask of the trail

func trailMask() -> CGImage {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
    )!
    context.translateBy(x: 0, y: side)
    context.scaleBy(x: 1, y: -1)
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    context.setStrokeColor(gray: 1, alpha: 1)
    context.setLineWidth(trailWidth)
    context.setLineCap(.round)
    context.addPath(trail)
    context.strokePath()
    // A wider clearing around where you are now.
    context.setFillColor(gray: 1, alpha: 1)
    context.fillEllipse(in: CGRect(x: dot.x - 175, y: dot.y - 175, width: 350, height: 350))

    let sharp = CIImage(cgImage: context.makeImage()!)
    let blurred = sharp.clampedToExtent().applyingGaussianBlur(sigma: 12).cropped(to: sharp.extent)
    return CIContext().createCGImage(blurred, from: sharp.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())!
}

// MARK: Compose

let context = makeContext()
let canvas = CGRect(x: 0, y: 0, width: side, height: side)

// Fog: deep slate with a gentle vertical gradient and a few lighter drifts.
let fog = CGGradient(colorsSpace: colorSpace, colors: [color(0x323C58), color(0x161B2B)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(fog, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: side), options: [])
for (x, y, radius, alpha) in [(180.0, 230.0, 330.0, 0.10), (860.0, 760.0, 380.0, 0.08), (520.0, 980.0, 300.0, 0.06)] {
    let drift = CGGradient(colorsSpace: colorSpace, colors: [color(0xB8C4E0, alpha), color(0xB8C4E0, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(drift, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: radius, options: [])
}

// The map, shown only through the trail mask. clip(to:mask:) works in the base (y-up) space,
// so flip the mask's rectangle back.
context.saveGState()
context.saveGState()
context.translateBy(x: 0, y: side)
context.scaleBy(x: 1, y: -1)
context.clip(to: canvas, mask: trailMask())
context.translateBy(x: 0, y: side)
context.scaleBy(x: 1, y: -1)
drawMap(in: context)
context.restoreGState()
context.restoreGState()

// Location dot: white ring with a soft shadow, blue centre.
context.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: color(0x000000, 0.35))
context.setFillColor(color(0xFFFFFF))
context.fillEllipse(in: CGRect(x: dot.x - 92, y: dot.y - 92, width: 184, height: 184))
context.setShadow(offset: .zero, blur: 0, color: nil)
context.setFillColor(color(0x0A84FF))
context.fillEllipse(in: CGRect(x: dot.x - 68, y: dot.y - 68, width: 136, height: 136))

// MARK: Write

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.png")
try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(output.path)") }
print("Wrote \(output.path)")
