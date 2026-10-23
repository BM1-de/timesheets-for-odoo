// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Fester Kalender und feste Uhrzeit für Tests: Freitag, 23. Oktober 2026, 14:52 in Berlin.
enum TestClock {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "de_DE")
        return calendar
    }()

    static let now: Date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 14, minute: 52))!
}

/// Uhr, die ein Test vorstellen kann, ab Freitag, 23. Oktober 2026, 14:52.
final class MovingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = TestClock.now

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current += seconds }
    }
}
