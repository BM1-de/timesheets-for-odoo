// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Datums- und Zeitangaben in der Sprache der App, mit der Region des Mac.
enum Formatting {
    static let locale = appLocale(language: Bundle.main.preferredLocalizations.first ?? "de")

    /// Die Sprache kommt von der App, Region und 12- oder 24-Stunden-Uhr vom Mac. Spricht der Mac
    /// dieselbe Sprache, gelten auch eigene Formate aus den Systemeinstellungen.
    static func appLocale(language: String, current: Locale = .autoupdatingCurrent) -> Locale {
        var wanted = Locale.Language.Components(identifier: language)
        guard current.language.languageCode != wanted.languageCode else { return current }
        wanted.region = current.region
        var components = Locale.Components(locale: current)
        components.languageComponents = wanted
        return Locale(components: components)
    }

    /// Gregorianisch, unabhängig vom Kalender, der am Mac eingestellt ist.
    private static func style(_ locale: Locale, standalone: Bool = false) -> Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: .gregorianLocal, timeZone: .autoupdatingCurrent,
                         capitalizationContext: standalone ? .standalone : .unknown)
    }

    /// „Freitag, 23. Oktober 2026“; im Französischen groß geschrieben, weil die Zeile allein steht.
    static func longDate(_ day: CalendarDay, locale: Locale = locale) -> String {
        day.startDate().formatted(style(locale, standalone: true).weekday(.wide).day().month(.wide).year())
    }

    /// „Fr. 23.10.“ – im Deutschen stehen die Kürzel fest, weil die Systemformate je nach Version
    /// mal „Fr“, mal „Fr.“ liefern. Andere Sprachen nehmen das Format ihrer Region („Fri, Oct 23“).
    static func shortDate(_ day: CalendarDay, locale: Locale = locale) -> String {
        guard locale.language.languageCode == .german else {
            return day.startDate().formatted(style(locale).weekday(.abbreviated).day().month(.abbreviated))
        }
        let weekdays = ["So.", "Mo.", "Di.", "Mi.", "Do.", "Fr.", "Sa."]
        let index = Calendar.gregorianLocal.component(.weekday, from: day.startDate()) - 1
        return "\(weekdays[max(0, min(index, 6))]) \(day.day).\(day.month)."
    }

    /// „Freitag“ als Überschrift
    static func weekday(_ day: CalendarDay, locale: Locale = locale) -> String {
        day.startDate().formatted(style(locale, standalone: true).weekday(.wide))
    }

    /// „08:12“ oder „8:12 AM“ in der Zeitzone des Kalenders.
    static func time(_ date: Date, calendar: Calendar = .gregorianLocal, locale: Locale = locale) -> String {
        date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute())
    }
}
