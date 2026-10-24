#!/usr/bin/env swift
// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Zeichnet das App-Symbol (Stoppuhr auf einer Kachel in Odoo-Lila) in allen Größen des
// macOS-Rasters und schreibt die PNG-Dateien samt Contents.json in den Asset-Katalog.
// Eigene Zeichnung in den Odoo-Farben, bewusst kein Odoo-Logo und keine Kopie der Odoo-Symbole.
//
//   swift scripts/make-icon.swift

import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Zeiterfassung/Assets.xcassets/AppIcon.appiconset")

func color(_ hex: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func drawIcon(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let scale = size / 1024
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Kein Grafikkontext") }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.scaleBy(x: scale, y: scale)

    // Kachel im macOS-Raster: 824 × 824 auf 1024, Eckradius 185, leichter Schatten.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 22
    shadow.set()
    color(0x714B67).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    let gradient = NSGradient(starting: color(0x7E5674), ending: color(0x644260))
    gradient?.draw(in: tile, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Stoppuhr: helles Zifferblatt mit Krone, ein Segment in Petrol für die gebuchte Zeit
    // (12 bis 4 Uhr) und ein lila Zeiger auf „jetzt“.
    let center = NSPoint(x: 512, y: 476)
    color(0xF6EFF4).setFill()
    NSBezierPath(roundedRect: NSRect(x: 459, y: 762, width: 106, height: 42), xRadius: 18, yRadius: 18).fill()
    NSBezierPath(rect: NSRect(x: 493, y: 730, width: 38, height: 46)).fill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 264, y: center.y - 264, width: 528, height: 528)).fill()

    let segment = NSBezierPath()
    segment.move(to: center)
    segment.line(to: NSPoint(x: center.x, y: center.y + 208))
    segment.appendArc(withCenter: center, radius: 208, startAngle: 90, endAngle: -30, clockwise: true)
    segment.close()
    color(0x017E84).setFill()
    segment.fill()

    let hand = NSBezierPath()
    hand.lineWidth = 40
    hand.lineCapStyle = .round
    hand.move(to: center)
    hand.line(to: NSPoint(x: center.x + 133.4, y: center.y - 77))
    color(0x714B67).setStroke()
    hand.stroke()
    color(0x714B67).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 33, y: center.y - 33, width: 66, height: 66)).fill()

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG fehlgeschlagen") }
    return png
}

let variants: [(name: String, points: Int, scale: Int)] = [
    ("icon_16x16", 16, 1), ("icon_16x16@2x", 16, 2),
    ("icon_32x32", 32, 1), ("icon_32x32@2x", 32, 2),
    ("icon_128x128", 128, 1), ("icon_128x128@2x", 128, 2),
    ("icon_256x256", 256, 1), ("icon_256x256@2x", 256, 2),
    ("icon_512x512", 512, 1), ("icon_512x512@2x", 512, 2),
]

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
var images: [[String: String]] = []
for variant in variants {
    let file = "\(variant.name).png"
    try drawIcon(pixels: variant.points * variant.scale).write(to: outputDirectory.appendingPathComponent(file))
    images.append(["filename": file, "idiom": "mac", "scale": "\(variant.scale)x",
                   "size": "\(variant.points)x\(variant.points)"])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputDirectory.appendingPathComponent("Contents.json"))
print("App-Symbol geschrieben nach \(outputDirectory.path)")
