// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Observation

/// Einstellungen in den Benutzervorgaben. Der API-Schlüssel liegt nicht hier, sondern im Schlüsselbund.
@MainActor
@Observable
final class Preferences {
    enum MenuBarDisplay: String, CaseIterable, Sendable {
        case booked
        case attendance
        case both
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
    var menuBarDisplay: MenuBarDisplay { didSet { defaults.set(menuBarDisplay.rawValue, forKey: Key.menuBarDisplay) } }
    var showsCheckedInDot: Bool { didSet { defaults.set(showsCheckedInDot, forKey: Key.checkedInDot) } }
    var roundsToQuarterHour: Bool { didSet { defaults.set(roundsToQuarterHour, forKey: Key.quarterHour) } }
    var session: OdooSession? { didSet { store(session, forKey: Key.session) } }
    var cachedCapabilities: Capabilities? { didSet { store(cachedCapabilities, forKey: Key.capabilities) } }
    var loginHints: LoginHints? { didSet { store(loginHints, forKey: Key.loginHints) } }
    /// Odoo hat das Stempeln abgelehnt, obwohl das Recht dazu vorhanden schien. Gilt bis zur nächsten
    /// Anmeldung oder bis die Rechte in den Einstellungen erneut geprüft werden.
    var stampingRefused: Bool { didSet { defaults.set(stampingRefused, forKey: Key.stampingRefused) } }
    /// „Beim Anmelden am Mac öffnen“ wurde beim ersten Start eingeschaltet.
    var loginItemDefaultApplied: Bool { didSet { defaults.set(loginItemDefaultApplied, forKey: Key.loginItemDefault) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        timesheetsEnabled = defaults.object(forKey: Key.timesheets) as? Bool ?? true
        attendanceEnabled = defaults.object(forKey: Key.attendance) as? Bool ?? true
        menuBarDisplay = defaults.string(forKey: Key.menuBarDisplay).flatMap(MenuBarDisplay.init(rawValue:)) ?? .booked
        showsCheckedInDot = defaults.object(forKey: Key.checkedInDot) as? Bool ?? true
        roundsToQuarterHour = defaults.object(forKey: Key.quarterHour) as? Bool ?? true
        session = Self.load(OdooSession.self, from: defaults, forKey: Key.session)
        cachedCapabilities = Self.load(Capabilities.self, from: defaults, forKey: Key.capabilities)
        loginHints = Self.load(LoginHints.self, from: defaults, forKey: Key.loginHints)
        stampingRefused = defaults.bool(forKey: Key.stampingRefused)
        loginItemDefaultApplied = defaults.bool(forKey: Key.loginItemDefault)
    }

    private enum Key {
        static let timesheets = "feature.timesheets"
        static let attendance = "feature.attendance"
        static let menuBarDisplay = "menuBar.display"
        static let checkedInDot = "menuBar.checkedInDot"
        static let quarterHour = "duration.roundToQuarterHour"
        static let session = "odoo.session"
        static let capabilities = "odoo.capabilities"
        static let loginHints = "odoo.loginHints"
        static let stampingRefused = "odoo.stampingRefused"
        static let loginItemDefault = "loginItem.defaultApplied"
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
