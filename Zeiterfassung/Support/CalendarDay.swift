// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Ein Kalendertag ohne Uhrzeit, wie das Feld `date` eines Zeiteintrags in Odoo.
struct CalendarDay: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(date: Date, calendar: Calendar = .gregorianLocal) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
    }

    static func today(calendar: Calendar = .gregorianLocal) -> CalendarDay { CalendarDay(date: Date(), calendar: calendar) }

    /// Beginn des Tages in der Zeitzone des Kalenders.
    func startDate(calendar: Calendar = .gregorianLocal) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date(timeIntervalSince1970: 0)
    }

    func adding(days: Int, calendar: Calendar = .gregorianLocal) -> CalendarDay {
        let start = startDate(calendar: calendar)
        let date = calendar.date(byAdding: .day, value: days, to: start) ?? start
        return CalendarDay(date: date, calendar: calendar)
    }

    /// `2026-10-23`
    var odooString: String { String(format: "%04d-%02d-%02d", year, month, day) }

    var description: String { odooString }

    static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

extension Calendar {
    /// Gregorianisch in der jeweils aktuellen Zeitzone des Mac. Odoo rechnet immer gregorianisch,
    /// auch wenn am Mac etwa der japanische Kalender eingestellt ist; auf Reisen folgt die Zeitzone mit.
    static var gregorianLocal: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        calendar.locale = Locale(identifier: "de_DE")
        return calendar
    }
}

/// Zeitpunkte in Odoo: `2026-10-23 06:12:00`, immer UTC.
enum OdooDateTime {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    static func string(from date: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d",
                      c.year ?? 1970, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    static func date(from string: String) -> Date? {
        let parts = string.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == ":" || $0 == "T" }).compactMap { Int($0) }
        guard parts.count >= 5 else { return nil }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4],
                                        second: parts.count > 5 ? parts[5] : 0)
        return utc.date(from: components)
    }
}
