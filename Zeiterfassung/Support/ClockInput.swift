// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Liest Uhrzeiten in den Feldern „von“ und „bis“: `8:30`, `08.30`, `8h30`, `830`, `8`, auch mit
/// `AM` und `PM`, so wie die App sie in Regionen mit 12-Stunden-Uhr vorausfüllt.
enum ClockInput {
    /// Minuten seit Mitternacht; `nil`, wenn sich keine Uhrzeit lesen lässt.
    static func minutes(from text: String) -> Int? {
        var compact = text.lowercased().filter { !$0.isWhitespace }
        var meridiem: Character?
        for (suffix, mark) in [("a.m.", "a"), ("p.m.", "p"), ("am", "a"), ("pm", "p")] where compact.hasSuffix(suffix) {
            compact.removeLast(suffix.count)
            meridiem = mark.first
            break
        }
        let hour: Int
        let minute: Int
        if let match = compact.wholeMatch(of: /(\d{1,2})[:.h](\d{2})/) {
            hour = Int(match.1) ?? -1
            minute = Int(match.2) ?? -1
        } else if let match = compact.wholeMatch(of: /(\d{1,2})(\d{2})/) {
            hour = Int(match.1) ?? -1
            minute = Int(match.2) ?? -1
        } else if let match = compact.wholeMatch(of: /(\d{1,2})h?/) {
            hour = Int(match.1) ?? -1
            minute = 0
        } else {
            return nil
        }
        guard (0..<60).contains(minute) else { return nil }
        switch meridiem {
        case "a"?:
            guard (1...12).contains(hour) else { return nil }
            return (hour % 12) * 60 + minute
        case "p"?:
            guard (1...12).contains(hour) else { return nil }
            return (hour % 12 + 12) * 60 + minute
        default:
            guard (0..<24).contains(hour) else { return nil }
            return hour * 60 + minute
        }
    }
}
