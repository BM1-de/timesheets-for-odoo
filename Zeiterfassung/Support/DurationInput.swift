// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Liest und schreibt Dauern im Feld „Dauer“.
///
/// Erlaubt sind `1:30`, `1,5`, `1.5`, `90 min`, `90m`, `2h`, `1h30` und `1 h 30 min`, die Einheiten
/// auch englisch und französisch (`2 hours`, `1 heure 30`). Eine Zahl ohne Einheit sind Stunden,
/// wie in Odoo selbst.
enum DurationInput {
    enum Result: Equatable {
        case empty
        case minutes(Int)
        case unreadable
        case tooLong
    }

    static let maximumMinutes = 24 * 60

    static func parse(_ text: String) -> Result {
        let compact = text.lowercased().replacingOccurrences(of: " ", with: "")
        guard !compact.isEmpty else { return .empty }
        guard let minutes = minutes(in: compact) else { return .unreadable }
        return minutes > maximumMinutes ? .tooLong : .minutes(minutes)
    }

    /// Rundet zur nächsten Einheit von `unit` Minuten, aber nie auf null.
    static func rounded(_ minutes: Int, toNearest unit: Int) -> Int {
        guard minutes > 0 else { return 0 }
        guard unit > 1 else { return minutes }
        return max(unit, Int((Double(minutes) / Double(unit)).rounded()) * unit)
    }

    /// −/+: von `minutes` zur nächsten Stufe von `unit` Minuten in diese Richtung, nie unter null.
    static func stepped(_ minutes: Int, by direction: Int, unit: Int) -> Int {
        let steps = direction > 0 ? minutes / unit + 1 : (minutes + unit - 1) / unit - 1
        return max(0, steps * unit)
    }

    /// `1:05`
    static func format(_ minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    /// „1 Stunde 5 Minuten“ für VoiceOver; Einzahl und Mehrzahl stehen im Übersetzungskatalog.
    static func spoken(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        var parts: [String] = []
        if hours > 0 { parts.append(String(localized: "\(hours) Stunden")) }
        if rest > 0 || hours == 0 { parts.append(String(localized: "\(rest) Minuten")) }
        return parts.joined(separator: " ")
    }

    private static func minutes(in text: String) -> Int? {
        if let match = text.wholeMatch(of: /(\d{1,2}):(\d{1,2})/) {
            guard let hours = Int(match.1), let minutes = Int(match.2), minutes < 60 else { return nil }
            return hours * 60 + minutes
        }
        if let match = text.wholeMatch(of: /(\d+(?:[.,]\d+)?)/) {
            return decimalHours(String(match.1)).map(minutes(fromHours:))
        }
        if let match = text.wholeMatch(of: /(?:(\d+(?:[.,]\d+)?)(?:h|std|stunden?|hrs?|hours?|heures?))?(?:(\d+)(?:m|mn|mins?|minuten?|minutes?)?)?/),
           match.1 != nil || match.2 != nil {
            // „1h30“ ohne Einheit hinter der 30 sind Minuten; „30“ allein wurde oben als Stunden gelesen.
            let hours = match.1.flatMap { decimalHours(String($0)) } ?? 0
            // Ziffern, die nicht in `Int` passen, sind auf jeden Fall zu viel.
            let extraMinutes = match.2.map { Int($0) ?? cap } ?? 0
            return min(minutes(fromHours: hours) + min(extraMinutes, cap), cap)
        }
        return nil
    }

    private static func decimalHours(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }

    /// Obergrenze beim Umrechnen: Sehr lange Zahlen würden sonst beim Umwandeln in `Int` überlaufen.
    private static let cap = maximumMinutes + 1

    private static func minutes(fromHours hours: Double) -> Int {
        guard hours.isFinite else { return cap }
        return Int(min(hours * 60, Double(cap)).rounded())
    }
}
