// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Zeiterfassung

@Suite("Dauer eingeben")
struct DurationInputTests {
    @Test("liest übliche Schreibweisen", arguments: [
        ("1:30", 90), ("0:15", 15), ("1,5", 90), ("1.5", 90), ("2", 120), ("0,25", 15),
        ("90m", 90), ("90 min", 90), ("45min", 45), ("2h", 120), ("1h30", 90), ("1 h 30 min", 90),
        ("1,5h", 90), ("8 Std", 480), (" 1:05 ", 65),
        ("2 hours", 120), ("1 hr 30 min", 90), ("1.5 hrs", 90), ("45 mins", 45), ("90 minutes", 90),
        ("2 heures", 120), ("1 heure 30", 90), ("30 mn", 30),
    ])
    func parses(text: String, minutes: Int) {
        #expect(DurationInput.parse(text) == .minutes(minutes))
    }

    @Test("erkennt Leeres, Unlesbares und zu Langes")
    func rejects() {
        #expect(DurationInput.parse("") == .empty)
        #expect(DurationInput.parse("   ") == .empty)
        #expect(DurationInput.parse("abc") == .unreadable)
        #expect(DurationInput.parse("1:75") == .unreadable)
        #expect(DurationInput.parse("1;30") == .unreadable)
        #expect(DurationInput.parse("25") == .tooLong)
        #expect(DurationInput.parse("24:01") == .tooLong)
        #expect(DurationInput.parse("24:00") == .minutes(1440))
    }

    @Test("sehr lange Zahlen sind zu lang, ohne dass die App abstürzt", arguments: [
        "99999999999999999999", "99999999999999999999999999999999999999,5", "1h99999999999999999999",
        "99999999999999999999h", "9999999999999999999999999 min", "\(String(repeating: "9", count: 400))",
    ])
    func hugeNumbers(text: String) {
        #expect(DurationInput.parse(text) == .tooLong)
    }

    @Test("rundet zur nächsten Einheit, aber nie auf null")
    func rounds() {
        #expect(DurationInput.rounded(0, toNearest: 15) == 0)
        #expect(DurationInput.rounded(5, toNearest: 15) == 15)
        #expect(DurationInput.rounded(7, toNearest: 15) == 15)
        #expect(DurationInput.rounded(22, toNearest: 15) == 15)
        #expect(DurationInput.rounded(23, toNearest: 15) == 30)
        #expect(DurationInput.rounded(80, toNearest: 15) == 75)
        #expect(DurationInput.rounded(90, toNearest: 15) == 90)
        #expect(DurationInput.rounded(10, toNearest: 30) == 30)
        #expect(DurationInput.rounded(44, toNearest: 30) == 30)
        #expect(DurationInput.rounded(45, toNearest: 30) == 60)
        #expect(DurationInput.rounded(20, toNearest: 60) == 60)
        #expect(DurationInput.rounded(89, toNearest: 60) == 60)
        #expect(DurationInput.rounded(90, toNearest: 60) == 120)
    }

    @Test("−/+ geht zur nächsten Stufe, nie unter null")
    func steps() {
        #expect(DurationInput.stepped(20, by: 1, unit: 15) == 30)
        #expect(DurationInput.stepped(30, by: 1, unit: 15) == 45)
        #expect(DurationInput.stepped(20, by: -1, unit: 15) == 15)
        #expect(DurationInput.stepped(15, by: -1, unit: 15) == 0)
        #expect(DurationInput.stepped(0, by: -1, unit: 15) == 0)
        #expect(DurationInput.stepped(50, by: 1, unit: 30) == 60)
        #expect(DurationInput.stepped(20, by: 1, unit: 60) == 60)
        #expect(DurationInput.stepped(80, by: -1, unit: 60) == 60)
    }

    @Test("schreibt Stunden:Minuten und gesprochenen Text")
    func formats() {
        #expect(DurationInput.format(0) == "0:00")
        #expect(DurationInput.format(65) == "1:05")
        #expect(DurationInput.format(600) == "10:00")
        #expect(DurationInput.spoken(0) == "0 Minuten")
        #expect(DurationInput.spoken(60) == "1 Stunde")
        #expect(DurationInput.spoken(61) == "1 Stunde 1 Minute")
        #expect(DurationInput.spoken(315) == "5 Stunden 15 Minuten")
    }
}

@Suite("Tage und Zeitpunkte")
struct CalendarTests {
    let calendar = TestClock.calendar

    @Test("rechnet Tage über Monats- und Jahresgrenzen")
    func addsDays() {
        let day = CalendarDay(year: 2026, month: 12, day: 31)
        #expect(day.adding(days: 1, calendar: calendar) == CalendarDay(year: 2027, month: 1, day: 1))
        #expect(CalendarDay(year: 2026, month: 3, day: 1).adding(days: -1, calendar: calendar) == CalendarDay(year: 2026, month: 2, day: 28))
        #expect(day.odooString == "2026-12-31")
        #expect(CalendarDay(year: 2026, month: 1, day: 2) < CalendarDay(year: 2026, month: 1, day: 10))
    }

    @Test("Tagesbeginn und Sommerzeit in Berlin")
    func startOfDay() {
        // Am 25.10.2026 endet die Sommerzeit; der Tag hat 25 Stunden.
        let day = CalendarDay(year: 2026, month: 10, day: 25)
        let start = day.startDate(calendar: calendar)
        let next = day.adding(days: 1, calendar: calendar).startDate(calendar: calendar)
        #expect(next.timeIntervalSince(start) == 25 * 3600)
        #expect(OdooDateTime.string(from: start) == "2026-10-24 22:00:00")
    }

    @Test("Odoo-Zeitpunkte sind UTC")
    func odooDateTime() {
        let date = OdooDateTime.date(from: "2026-10-23 06:12:00")
        #expect(date != nil)
        #expect(OdooDateTime.string(from: date!) == "2026-10-23 06:12:00")
        #expect(OdooDateTime.date(from: "2026-10-23T06:12:30") == date!.addingTimeInterval(30))
        #expect(OdooDateTime.date(from: "kein Datum") == nil)
    }

    @Test("Datum und Uhrzeit je Sprache und Region", arguments: [
        ("de_DE", "Freitag, 23. Oktober 2026", "Fr. 23.10.", "Freitag", "20:12", "08:05"),
        ("de_AT", "Freitag, 23. Oktober 2026", "Fr. 23.10.", "Freitag", "20:12", "08:05"),
        ("en_US", "Friday, October 23, 2026", "Fri, Oct 23", "Friday", "8:12\u{202F}PM", "8:05\u{202F}AM"),
        ("en_GB", "Friday, 23 October 2026", "Fri 23 Oct", "Friday", "20:12", "08:05"),
        ("fr_FR", "Vendredi 23 octobre 2026", "ven. 23 oct.", "Vendredi", "20:12", "08:05"),
    ])
    func formatsDates(identifier: String, long: String, short: String, weekday: String, evening: String, morning: String) {
        let locale = Locale(identifier: identifier)
        let day = CalendarDay(year: 2026, month: 10, day: 23)
        #expect(Formatting.longDate(day, locale: locale) == long)
        #expect(Formatting.shortDate(day, locale: locale) == short)
        #expect(Formatting.weekday(day, locale: locale) == weekday)
        let at = { (hour: Int, minute: Int) in
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: hour, minute: minute))!
        }
        #expect(Formatting.time(at(20, 12), calendar: calendar, locale: locale) == evening)
        #expect(Formatting.time(at(8, 5), calendar: calendar, locale: locale) == morning)
    }

    @Test("Sprache von der App, Region vom Mac")
    func appLocale() {
        let english = Formatting.appLocale(language: "en", current: Locale(identifier: "de_DE"))
        #expect(english.language.languageCode == .english && english.region == .germany)
        let french = Formatting.appLocale(language: "fr", current: Locale(identifier: "en_US"))
        #expect(french.language.languageCode == .french && french.region == .unitedStates)
        #expect(Formatting.appLocale(language: "de", current: Locale(identifier: "de_AT")).identifier == "de_AT")
        #expect(Formatting.locale.language.languageCode?.identifier == Bundle.main.preferredLocalizations.first)
    }
}

@Suite("Serveradresse")
struct ServerAddressTests {
    @Test("ergänzt https und kürzt auf den Server", arguments: [
        ("odoo.example.de", "https://odoo.example.de"),
        ("https://Odoo.Example.de/", "https://odoo.example.de"),
        ("https://odoo.example.de/odoo/timesheets?debug=1#x", "https://odoo.example.de"),
        ("https://odoo.example.de:8443/web", "https://odoo.example.de:8443"),
        ("http://localhost:8069", "http://localhost:8069"),
        ("  https://firma.odoo.com  ", "https://firma.odoo.com"),
    ])
    func normalizes(input: String, expected: String) {
        #expect(ServerAddress.normalize(input)?.absoluteString == expected)
    }

    @Test("lehnt Unsinn ab")
    func rejects() {
        #expect(ServerAddress.normalize("") == nil)
        #expect(ServerAddress.normalize("ftp://odoo.example.de") == nil)
        #expect(ServerAddress.normalize("https://") == nil)
    }

    @Test("http nur auf dem eigenen Rechner")
    func security() {
        #expect(ServerAddress.isSecure(URL(string: "https://odoo.example.de")!))
        #expect(ServerAddress.isSecure(URL(string: "http://localhost:8069")!))
        #expect(ServerAddress.isSecure(URL(string: "http://127.0.0.1:8069")!))
        #expect(!ServerAddress.isSecure(URL(string: "http://odoo.example.de")!))
        #expect(!ServerAddress.isSecure(URL(string: "http://192.168.1.10:8069")!))
    }
}

@Suite("JSON-Werte")
struct JSONValueTests {
    @Test("liest Verweise, false und Zahlen")
    func reads() throws {
        let data = Data(#"{"project_id":[7,"Interne Arbeiten"],"task_id":false,"unit_amount":1.5,"id":42,"name":"x"}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value["project_id"]?.reference == Reference(id: 7, name: "Interne Arbeiten"))
        #expect(value["task_id"]?.reference == nil)
        #expect(value["task_id"]?.boolValue == false)
        #expect(value["unit_amount"]?.doubleValue == 1.5)
        #expect(value["id"]?.intValue == 42)
        #expect(value["unit_amount"]?.intValue == nil)
    }

    @Test("schreibt IDs als Ganzzahl")
    func writesIntegers() throws {
        let value: JSONValue = ["ids": .ints([1, 2]), "amount": 0.25, "flag": false, "none": nil]
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        #expect(text.contains(#""ids":[1,2]"#))
        #expect(text.contains(#""amount":0.25"#))
        #expect(text.contains(#""flag":false"#))
        #expect(text.contains(#""none":null"#))
    }
}
