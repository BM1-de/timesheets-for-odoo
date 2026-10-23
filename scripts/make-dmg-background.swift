#!/usr/bin/env swift
// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Zeichnet den Hintergrund des DMG-Fensters: heller Verlauf, Pfeil von der App zum Ordner
// „Applications“ und ein kurzer Hinweis auf Deutsch, Englisch und Französisch. Lage und Größe
// passen zu scripts/dmg/settings.py.
//
//   swift scripts/make-dmg-background.swift

import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "scripts/dmg")
let canvas = NSSize(width: 600, height: 400)
/// Mitte der Symbole, von oben gemessen wie in settings.py.
let iconY: CGFloat = 175
let appX: CGFloat = 170
let folderX: CGFloat = 430

func draw(scale: CGFloat) -> Data {
    let pixelsWide = Int(canvas.width * scale)
    let pixelsHigh = Int(canvas.height * scale)
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Kein Grafikkontext") }
    bitmap.size = canvas

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: scale, y: scale)

    // Heller, kaum sichtbarer Verlauf wie bei Fenstern von macOS.
    NSGradient(starting: NSColor(srgbRed: 0.976, green: 0.976, blue: 0.98, alpha: 1),
               ending: NSColor(srgbRed: 0.918, green: 0.918, blue: 0.93, alpha: 1))?
        .draw(in: NSRect(origin: .zero, size: canvas), angle: -90)

    // Pfeil zwischen den Symbolen (Zeichenfläche: Ursprung unten links).
    let y = canvas.height - iconY
    let start = appX + 88
    let end = folderX - 88
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: start, y: y))
    arrow.line(to: NSPoint(x: end - 4, y: y))
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    let color = NSColor(srgbRed: 0.56, green: 0.56, blue: 0.58, alpha: 1)
    color.setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: end - 18, y: y + 14))
    head.line(to: NSPoint(x: end, y: y))
    head.line(to: NSPoint(x: end - 18, y: y - 14))
    head.lineWidth = 5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    // Hinweis unter den Beschriftungen der Symbole, eine Zeile je Sprache der App.
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineSpacing = 3
    let lines = [
        "Zum Installieren auf „Applications“ ziehen.",
        "Drag onto “Applications” to install.",
        "Glissez sur «\u{00A0}Applications\u{00A0}» pour installer.",
    ]
    let text = NSAttributedString(string: lines.joined(separator: "\n"), attributes: [
        .font: NSFont.systemFont(ofSize: 12),
        .foregroundColor: NSColor(srgbRed: 0.43, green: 0.43, blue: 0.45, alpha: 1),
        .paragraphStyle: paragraph,
    ])
    text.draw(in: NSRect(x: 40, y: canvas.height - 372, width: canvas.width - 80, height: 62))

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Kein PNG") }
    return png
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
try draw(scale: 1).write(to: outputDirectory.appending(path: "background.png"))
try draw(scale: 2).write(to: outputDirectory.appending(path: "background@2x.png"))
print("Hintergrund: \(outputDirectory.path)/background.png, background@2x.png")
