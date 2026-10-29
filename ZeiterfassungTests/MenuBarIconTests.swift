// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Testing
@testable import Zeiterfassung

@MainActor
@Suite("Symbol in der Menüleiste")
struct MenuBarIconTests {
    @Test("ohne Punkt ein Vorlagenbild, mit Punkt ein grüner Punkt links vor dem Symbol", arguments: [
        AppModel.MenuBarContent.Symbol.clock, .stopwatch, .person,
    ])
    func dotBeforeSymbol(symbol: AppModel.MenuBarContent.Symbol) throws {
        let plain = try #require(MenuBarIcon.image(symbol, isSignedIn: true))
        #expect(plain.isTemplate)

        let dotted = try #require(MenuBarIcon.image(symbol, showsDot: true, isSignedIn: true))
        #expect(!dotted.isTemplate)
        #expect(dotted.size.width == plain.size.width + 10)
        let bitmap = try #require(dotted.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let scale = CGFloat(bitmap.pixelsWide) / dotted.size.width
        let dot = try #require(bitmap.colorAt(x: Int(3 * scale), y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        #expect(dot.greenComponent > 0.6 && dot.redComponent < 0.5 && dot.alphaComponent > 0.9)
    }
}
