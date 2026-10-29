// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Zeiterfassung

@MainActor
@Suite("Einstellungen")
struct PreferencesTests {
    @Test("neu installiert wird auf 15 Minuten gerundet")
    func roundingDefault() {
        let defaults = ScratchDefaults.make("zeiterfassung-tests")
        #expect(Preferences(defaults: defaults).durationRounding == .quarterHour)
        #expect(defaults.object(forKey: "duration.rounding") as? Int == 15)
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

    @Test("„Nicht runden“ aus einer Installation von 0.3 oder 0.4.0 bleibt")
    func keepsStoredOff() {
        let defaults = ScratchDefaults.make("zeiterfassung-tests")
        defaults.set(0, forKey: "duration.rounding")
        #expect(Preferences(defaults: defaults).durationRounding == .off)
    }

    @Test("die Auswahl bleibt gespeichert")
    func storesRounding() {
        let defaults = ScratchDefaults.make("zeiterfassung-tests")
        Preferences(defaults: defaults).durationRounding = .hour
        #expect(Preferences(defaults: defaults).durationRounding == .hour)
    }

    @Test("Menüleiste: ab Werk „Automatisch“, die Anzeige bis Version 0.2 wird entfernt")
    func menuBarDefaults() {
        let defaults = ScratchDefaults.make("zeiterfassung-tests")
        defaults.set("both", forKey: "menuBar.display")
        defaults.set(false, forKey: "menuBar.checkedInDot")
        #expect(Preferences(defaults: defaults).menuBarTime == .automatic)
        #expect(defaults.object(forKey: "menuBar.display") == nil)
        #expect(defaults.object(forKey: "menuBar.checkedInDot") == nil)
        Preferences(defaults: defaults).menuBarTime = .attendanceToday
        #expect(Preferences(defaults: defaults).menuBarTime == .attendanceToday)
    }

    @Test("Menüleiste: wer bis Version 0.3 die laufende Projektzeit ausgeschaltet hatte, sieht weiter nur das Symbol")
    func menuBarFromRunningTimeSwitch() {
        let off = ScratchDefaults.make("zeiterfassung-tests")
        off.set(false, forKey: "menuBar.runningTime")
        #expect(Preferences(defaults: off).menuBarTime == .symbolOnly)
        #expect(off.object(forKey: "menuBar.runningTime") == nil)
        #expect(off.string(forKey: "menuBar.time") == "symbolOnly")
        let on = ScratchDefaults.make("zeiterfassung-tests")
        on.set(true, forKey: "menuBar.runningTime")
        #expect(Preferences(defaults: on).menuBarTime == .automatic)
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
