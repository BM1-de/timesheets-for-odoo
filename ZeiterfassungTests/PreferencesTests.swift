// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Zeiterfassung

@MainActor
@Suite("Einstellungen")
struct PreferencesTests {
    @Test("neu installiert wird nicht gerundet")
    func roundingDefault() {
        let defaults = ScratchDefaults.make("zeiterfassung-tests")
        #expect(Preferences(defaults: defaults).durationRounding == .off)
        #expect(defaults.object(forKey: "duration.rounding") as? Int == 0)
    }

    @Test("der Schalter bis Version 0.2 wird zur Auswahl", arguments: [
        (true, Preferences.DurationRounding.quarterHour), (false, .off),
    ])
    func takesOverSwitch(isOn: Bool, rounding: Preferences.DurationRounding) {
        let defaults = ScratchDefaults.make("zeiterfassung-tests")
        defaults.set(isOn, forKey: "duration.roundToQuarterHour")
        #expect(Preferences(defaults: defaults).durationRounding == rounding)
        #expect(defaults.object(forKey: "duration.rounding") as? Int == rounding.rawValue)
        #expect(defaults.object(forKey: "duration.roundToQuarterHour") == nil)
    }

    @Test("wer schon angemeldet war und den Schalter nie geändert hat, rundet weiter auf 15 Minuten")
    func keepsRoundingOfExistingUsers() {
        let defaults = ScratchDefaults.make("zeiterfassung-tests")
        Preferences(defaults: defaults).loginHints = .init(server: "https://odoo.example.de", login: nil, database: nil)
        defaults.removeObject(forKey: "duration.rounding")
        #expect(Preferences(defaults: defaults).durationRounding == .quarterHour)
    }

    @Test("die Auswahl bleibt gespeichert")
    func storesRounding() {
        let defaults = ScratchDefaults.make("zeiterfassung-tests")
        Preferences(defaults: defaults).durationRounding = .hour
        #expect(Preferences(defaults: defaults).durationRounding == .hour)
    }

    @Test("Menüleiste: laufende Projektzeit ab Werk an, die Anzeige bis Version 0.2 wird entfernt")
    func menuBarDefaults() {
        let defaults = ScratchDefaults.make("zeiterfassung-tests")
        defaults.set("both", forKey: "menuBar.display")
        defaults.set(false, forKey: "menuBar.checkedInDot")
        #expect(Preferences(defaults: defaults).showsRunningTime)
        #expect(defaults.object(forKey: "menuBar.display") == nil)
        #expect(defaults.object(forKey: "menuBar.checkedInDot") == nil)
    }

    @Test("die laufende Projektzeit übersteht einen Neustart")
    func storesRunningTimer() {
        let defaults = ScratchDefaults.make("zeiterfassung-tests")
        let timer = Preferences.RunningTimer(account: "https://odoo.example.de||7", projectID: 3, projectName: "Kundenmagazin",
                                             taskID: 32, taskName: "Layout", description: "Titelseite", start: TestClock.now)
        Preferences(defaults: defaults).runningTimer = timer
        #expect(Preferences(defaults: defaults).runningTimer == timer)
        #expect(timer.path == "Kundenmagazin › Layout")
    }
}
