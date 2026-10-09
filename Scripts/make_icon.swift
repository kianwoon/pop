#!/usr/bin/env swift
//
// make_icon.swift — renders the Pop macOS app icon (1024x1024 PNG) with AppKit.
//
// WHY a script and not a binary asset: the icon is part of the SOURCE, so it can
// be regenerated deterministically (same output every run) and reviewed as code.
// The rendered PNG is committed as Resources/AppIcon.icns; regenerate with:
//   swift Scripts/make_icon.swift /tmp/AppIcon.png
//   # then the iconset + iconutil steps (see after the script).
//
// Drawing model: every shape is authored on a 512-unit design grid measured from
// the TOP-LEFT, then all coordinates are multiplied by S=2 into the 1024px canvas
// so strokes land on crisp pixel boundaries. Deterministic: no randomness.
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: swift Scripts/make_icon.swift <output.png>\n".data(using: .utf8)!)
    exit(2)
}
let outPath = args[1]

func srgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: a)
}

let topBlue = srgb(0x5B9BFF)
let botBlue = srgb(0x3D6FE8)
let navy = srgb(0x14213F)
let lightBlue = srgb(0x8FB4F0)
let white = srgb(0xFFFFFF)

// Design grid -> canvas: S=2 scaling. Y() flips top-left design space into
// AppKit's bottom-left bitmap space.
let S: CGFloat = 2
let W: CGFloat = 1024
func X(_ v: CGFloat) -> CGFloat { v * S }
func Y(_ v: CGFloat) -> CGFloat { W - v * S }
func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
    NSRect(x: X(x), y: Y(y + h), width: X(w), height: X(h))
}
func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: X(x), y: Y(y)) }

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(W),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: W)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.shouldAntialias = true

// 1) Standard macOS tile: rounded rect inset 100px (50 design), blue gradient.
let tile = rect(50, 50, 412, 412)
let tileRadius = X(92.5)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: tileRadius, yRadius: tileRadius)
tilePath.addClip()
NSGradient(starting: topBlue, ending: botBlue)!.draw(in: tilePath, angle: -90)

// 2) Subtle 1px white top-edge highlight (inner stroke, ~0.25 alpha).
let hlInset: CGFloat = 1
let hl = NSBezierPath(roundedRect: tile.insetBy(dx: hlInset, dy: hlInset),
                      xRadius: tileRadius - hlInset, yRadius: tileRadius - hlInset)
hl.lineWidth = 1
white.withAlphaComponent(0.25).setStroke()
hl.stroke()

// 3) Antennae (drawn first so their stems tuck behind the face screen).
lightBlue.setStroke()
lightBlue.setFill()
for ax in [CGFloat(211), CGFloat(301)] {
    let stem = NSBezierPath()
    stem.move(to: pt(ax, 205))
    stem.line(to: pt(ax, 124))
    stem.lineWidth = X(9)
    stem.lineCapStyle = .round
    stem.stroke()
    let ball = NSBezierPath(ovalIn: NSRect(x: X(ax) - X(9), y: Y(114) - X(9),
                                           width: X(18), height: X(18)))
    ball.fill()
}

// 4) Mascot face: dark navy rounded-rect "screen" (~46% of tile width, 3:2).
let face = NSBezierPath(roundedRect: rect(138.25, 191.5, 235.5, 157),
                        xRadius: X(12), yRadius: X(12))
navy.setFill()
face.fill()

// 5) White chevron eyes `>_<` (round caps/joins).
white.setStroke()
let eyeWidth = X(16)
let leftEye = NSBezierPath()
leftEye.move(to: pt(196, 228))
leftEye.line(to: pt(226, 250))
leftEye.line(to: pt(196, 272))
leftEye.lineWidth = eyeWidth
leftEye.lineCapStyle = .round
leftEye.lineJoinStyle = .round
leftEye.stroke()

let rightEye = NSBezierPath()
rightEye.move(to: pt(316, 228))
rightEye.line(to: pt(286, 250))
rightEye.line(to: pt(316, 272))
rightEye.lineWidth = eyeWidth
rightEye.lineCapStyle = .round
rightEye.lineJoinStyle = .round
rightEye.stroke()

// 6) Small white rounded mouth bar below the eyes.
white.setFill()
NSBezierPath(roundedRect: rect(236, 296, 40, 10), xRadius: X(5), yRadius: X(5)).fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("make_icon.swift: PNG encoding failed\n".data(using: .utf8)!)
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: outPath))
} catch {
    FileHandle.standardError.write("make_icon.swift: \(error)\n".data(using: .utf8)!)
    exit(1)
}
print("wrote \(outPath) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
