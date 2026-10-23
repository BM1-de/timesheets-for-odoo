#!/usr/bin/env swift
// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Zeichnet das App-Symbol (blaue Kachel mit weißer Uhr) in allen Größen des macOS-Rasters
// und schreibt die PNG-Dateien samt Contents.json in den Asset-Katalog.
//
//   swift scripts/make-icon.swift

import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Zeiterfassung/Assets.xcassets/AppIcon.appiconset")

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
    NSColor(srgbRed: 0.04, green: 0.42, blue: 0.86, alpha: 1).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    let gradient = NSGradient(starting: NSColor(srgbRed: 0.25, green: 0.60, blue: 1.00, alpha: 1),
                              ending: NSColor(srgbRed: 0.00, green: 0.36, blue: 0.80, alpha: 1))
    gradient?.draw(in: tile, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Uhr: weißer Ring, zwei Zeiger, Mittelpunkt.
    let center = NSPoint(x: 512, y: 512)
    NSColor.white.setStroke()
    NSColor.white.setFill()
    let ring = NSBezierPath(ovalIn: NSRect(x: center.x - 250, y: center.y - 250, width: 500, height: 500))
    ring.lineWidth = 52
    ring.stroke()

    let hands = NSBezierPath()
    hands.lineWidth = 46
    hands.lineCapStyle = .round
    hands.lineJoinStyle = .round
    hands.move(to: NSPoint(x: center.x, y: center.y + 170))
    hands.line(to: center)
    hands.line(to: NSPoint(x: center.x + 112, y: center.y - 66))
    hands.stroke()

    NSBezierPath(ovalIn: NSRect(x: center.x - 34, y: center.y - 34, width: 68, height: 68)).fill()

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
