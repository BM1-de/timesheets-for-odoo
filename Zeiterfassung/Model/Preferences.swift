// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Observation

/// Einstellungen in den Benutzervorgaben. Der API-Schlüssel liegt nicht hier, sondern im Schlüsselbund.
@MainActor
@Observable
final class Preferences {
    /// Rundung der Dauer beim Buchen. Der Wert ist die Einheit in Minuten, 0 heißt nicht runden.
    enum DurationRounding: Int, CaseIterable, Sendable {
        case off = 0
        case quarterHour = 15
        case halfHour = 30
        case hour = 60

        /// Einheit in Minuten; `nil` ohne Rundung.
        var minutes: Int? { self == .off ? nil : rawValue }

        /// Schritt der Tasten − und +: die Einheit, ohne Rundung eine Viertelstunde.
        var step: Int { minutes ?? 15 }

        var lessLabel: String {
            switch step {
            case 30: String(localized: "30 Minuten weniger")
            case 60: String(localized: "1 Stunde weniger")
            default: String(localized: "15 Minuten weniger")
            }
        }

        var moreLabel: String {
            switch step {
            case 30: String(localized: "30 Minuten mehr")
            case 60: String(localized: "1 Stunde mehr")
            default: String(localized: "15 Minuten mehr")
            }
        }

        var stepHelp: String {
            switch step {
            case 30: String(localized: "Dauer in halben Stunden ändern")
            case 60: String(localized: "Dauer in ganzen Stunden ändern")
            default: String(localized: "Dauer in Viertelstunden ändern")
            }
        }
    }

    /// Zeit neben dem Symbol in der Menüleiste.
    enum MenuBarTime: String, CaseIterable, Sendable {
        /// Läuft eine Projektzeit, sie; sonst die Projektzeit von heute.
        case automatic
        case runningProject
        case projectToday
        case attendanceToday
        case symbolOnly
    }

    /// Laufende Projektzeit. Sie steht hier, damit sie einen Neustart der App übersteht.
    struct RunningTimer: Codable, Equatable, Sendable {
        /// Konto, zu dem die Zeit gehört (`OdooSession.keychainAccount`).
        var account: String
        /// `nil`: ohne Projekt gestartet; Projekt und Aufgabe kommen beim Stoppen dazu.
        var projectID: Int?
        var projectName: String?
        var taskID: Int?
        var taskName: String?
        var description: String
        var start: Date
        /// Gestoppt, aber noch nicht gebucht, etwa ohne Verbindung zu Odoo. Die Zeit steht dann still,
        /// bis das Buchen klappt oder die Zeit verworfen wird.
        var end: Date?

        /// „Projekt › Aufgabe“
        var path: String { [projectName, taskName].compactMap { $0 }.joined(separator: " › ") }
    }

    /// Angaben der letzten Anmeldung zum Vorausfüllen.
    struct LoginHints: Codable, Equatable, Sendable {
        var server: String
        var login: String?
        var database: String?
    }

    @ObservationIgnored private let defaults: UserDefaults

    var timesheetsEnabled: Bool { didSet { defaults.set(timesheetsEnabled, forKey: Key.timesheets) } }
    var attendanceEnabled: Bool { didSet { defaults.set(attendanceEnabled, forKey: Key.attendance) } }
    var menuBarTime: MenuBarTime { didSet { defaults.set(menuBarTime.rawValue, forKey: Key.menuBarTime) } }
    var runningTimer: RunningTimer? { didSet { store(runningTimer, forKey: Key.runningTimer) } }
    var durationRounding: DurationRounding { didSet { defaults.set(durationRounding.rawValue, forKey: Key.durationRounding) } }
    var session: OdooSession? { didSet { store(session, forKey: Key.session) } }
    var cachedCapabilities: Capabilities? { didSet { store(cachedCapabilities, forKey: Key.capabilities) } }
    var loginHints: LoginHints? { didSet { store(loginHints, forKey: Key.loginHints) } }
    /// Odoo hat das Stempeln abgelehnt, obwohl das Recht dazu vorhanden schien. Gilt bis zur nächsten
    /// Anmeldung oder bis die Rechte in den Einstellungen erneut geprüft werden.
    var stampingRefused: Bool { didSet { defaults.set(stampingRefused, forKey: Key.stampingRefused) } }
    /// „Beim Anmelden am Mac öffnen“ wurde beim ersten Start eingeschaltet.
    var loginItemDefaultApplied: Bool { didSet { defaults.set(loginItemDefaultApplied, forKey: Key.loginItemDefault) } }
    /// Mit Mitarbeitern in mehreren Firmen: der, mit dem die App stempelt. `nil` heißt Hauptfirma.
    var attendanceEmployeeID: Int? { didSet { defaults.set(attendanceEmployeeID, forKey: Key.attendanceEmployee) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        timesheetsEnabled = defaults.object(forKey: Key.timesheets) as? Bool ?? true
        attendanceEnabled = defaults.object(forKey: Key.attendance) as? Bool ?? true
        menuBarTime = Self.menuBarTime(in: defaults)
        runningTimer = Self.load(RunningTimer.self, from: defaults, forKey: Key.runningTimer)
        durationRounding = Self.durationRounding(in: defaults)
        session = Self.load(OdooSession.self, from: defaults, forKey: Key.session)
        cachedCapabilities = Self.load(Capabilities.self, from: defaults, forKey: Key.capabilities)
        loginHints = Self.load(LoginHints.self, from: defaults, forKey: Key.loginHints)
        stampingRefused = defaults.bool(forKey: Key.stampingRefused)
        loginItemDefaultApplied = defaults.bool(forKey: Key.loginItemDefault)
        attendanceEmployeeID = defaults.object(forKey: Key.attendanceEmployee) as? Int
        for key in Key.retired { defaults.removeObject(forKey: key) }
    }

    private enum Key {
        static let timesheets = "feature.timesheets"
        static let attendance = "feature.attendance"
        static let menuBarTime = "menuBar.time"
        /// Bis Version 0.3 der Schalter „Laufende Projektzeit anzeigen“, nur noch zum Übernehmen.
        static let runningTime = "menuBar.runningTime"
        static let runningTimer = "timer.running"
        static let durationRounding = "duration.rounding"
        /// Bis Version 0.2, nur noch zum Übernehmen.
        static let quarterHour = "duration.roundToQuarterHour"
        static let session = "odoo.session"
        static let capabilities = "odoo.capabilities"
        static let loginHints = "odoo.loginHints"
        static let stampingRefused = "odoo.stampingRefused"
        static let loginItemDefault = "loginItem.defaultApplied"
        static let attendanceEmployee = "attendance.employee"
        /// Bis Version 0.2: gebuchte Stunden oder Anwesenheit in der Menüleiste, grüner Punkt beim Einstempeln.
        static let retired = ["menuBar.display", "menuBar.checkedInDot"]
    }

    /// Bis Version 0.3 gab es nur den Schalter „Laufende Projektzeit anzeigen“, ab Werk an. Wer ihn
    /// ausgeschaltet hat, sieht weiter nur das Symbol; sonst gilt „Automatisch“.
    private static func menuBarTime(in defaults: UserDefaults) -> MenuBarTime {
        if let value = defaults.string(forKey: Key.menuBarTime) { return MenuBarTime(rawValue: value) ?? .automatic }
        let time: MenuBarTime = defaults.object(forKey: Key.runningTime) as? Bool == false ? .symbolOnly : .automatic
        defaults.set(time.rawValue, forKey: Key.menuBarTime)
        defaults.removeObject(forKey: Key.runningTime)
        return time
    }

    /// Bis Version 0.2 gab es nur den Schalter „Dauer auf Viertelstunden runden“, ab Werk an. Wer sich
    /// schon einmal angemeldet hat, rundet deshalb weiter auf 15 Minuten, sonst wie eingestellt; neu ist ab
    /// Werk „Nicht runden“. Das Ergebnis wird gleich gespeichert, damit eine spätere Anmeldung nichts mehr
    /// ändert.
    private static func durationRounding(in defaults: UserDefaults) -> DurationRounding {
        if let value = defaults.object(forKey: Key.durationRounding) as? Int {
            return DurationRounding(rawValue: value) ?? .off
        }
        let rounding: DurationRounding
        if let quarterHour = defaults.object(forKey: Key.quarterHour) as? Bool {
            rounding = quarterHour ? .quarterHour : .off
        } else if defaults.object(forKey: Key.loginHints) != nil {
            rounding = .quarterHour
        } else {
            rounding = .off
        }
        defaults.set(rounding.rawValue, forKey: Key.durationRounding)
        defaults.removeObject(forKey: Key.quarterHour)
        return rounding
    }

    private func store<Value: Encodable>(_ value: Value?, forKey key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func load<Value: Decodable>(_ type: Value.Type, from defaults: UserDefaults, forKey key: String) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
