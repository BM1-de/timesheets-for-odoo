// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Zeiterfassung

@MainActor
@Suite("Projekt-Timer")
struct TimerTests {
    private func signedIn(_ odoo: FakeOdoo, clock: MovingClock, defaults: UserDefaults? = nil,
                          secrets: MemorySecretStore = MemorySecretStore()) async throws -> AppModel {
        let model = AppModel(preferences: Preferences(defaults: defaults ?? ScratchDefaults.make("zeiterfassung-tests")),
                             http: odoo.client(), secrets: secrets, calendar: TestClock.calendar, clock: { clock.now })
        try await model.signIn(server: "odoo.example.de", apiKey: odoo.apiKey, login: nil, database: nil)
        model.finishSignIn()
        await model.refresh(force: true)
        return model
    }

    /// Kundenmagazin › Layout mit Beschreibung, ohne Dauer.
    private func fillDraft(_ model: AppModel) async throws {
        model.selectProject(try #require(model.projects.first { $0.id == 3 }))
        await model.loadTasks(projectID: 3)
        model.draft.taskID = 32
        model.draft.description = "Titelseite"
    }

    @Test("starten, die Menüleiste zählt mit, Stoppen bucht gerundet")
    func startAndStop() async throws {
        let odoo = FakeOdoo()
        let clock = MovingClock()
        let model = try await signedIn(odoo, clock: clock)
        model.preferences.durationRounding = .quarterHour
        try await fillDraft(model)
        model.draft.durationText = "0:30"
        #expect(!model.canStartTimer)
        model.draft.durationText = ""
        #expect(model.canStartTimer)
        #expect(model.menuBarContent.text.isEmpty)

        await model.startTimer()
        let timer = try #require(model.runningTimer)
        #expect(timer.path == "Kundenmagazin (Beispiel AG) › Layout")
        #expect(timer.description == "Titelseite")
        #expect(timer.start == TestClock.now)
        #expect(model.draft.description.isEmpty)
        #expect(model.draft.projectID == 3 && model.draft.taskID == 32)
        #expect(model.menuBarContent.text == "0:00")
        #expect(model.timerStartText == "seit 14:52")

        clock.advance(by: 42 * 60 + 17)
        await model.tick()
        #expect(model.timerSeconds() == 42 * 60 + 17)
        #expect(model.menuBarContent.text == "0:42")
        #expect(model.menuBarContent.accessibilityLabel == "\(AppInfo.name), Projektzeit läuft seit 42 Minuten")
        model.preferences.showsRunningTime = false
        #expect(model.menuBarContent.text.isEmpty)
        model.preferences.showsRunningTime = true

        model.timerDescription = "Titelseite und Inhalt"
        await model.stopTimer()
        #expect(model.runningTimer == nil)
        #expect(model.timerError == nil)
        #expect(model.timerNotice?.text == "0:45 Std. gebucht auf Kundenmagazin (Beispiel AG) › Layout, aus 0:42 gerundet.")
        let line = try #require(odoo.withLock { odoo.lines.first })
        #expect(line.name == "Titelseite und Inhalt")
        #expect(line.projectID == 3 && line.taskID == 32)
        #expect(line.hours == 0.75)
        #expect(line.date == "2026-10-23")
        #expect(model.entries.map(\.minutes) == [45])
        #expect(model.menuBarContent.text.isEmpty)
    }

    @Test("unter einer Minute bucht nichts, Verwerfen fragt erst ab einer Minute")
    func shortAndDiscarded() async throws {
        let odoo = FakeOdoo()
        let clock = MovingClock()
        let model = try await signedIn(odoo, clock: clock)
        try await fillDraft(model)

        await model.startTimer()
        clock.advance(by: 50)
        await model.stopTimer()
        #expect(model.runningTimer == nil)
        #expect(model.timerNotice?.text == "Weniger als eine Minute, nichts gebucht.")

        await model.startTimer()
        clock.advance(by: 30)
        model.requestDiscardTimer()
        #expect(model.pendingDeletion == nil)
        #expect(model.runningTimer == nil)
        #expect(model.timerNotice?.text == "Laufende Zeit verworfen, nichts gebucht.")

        model.draft.description = "Titelseite"
        await model.startTimer()
        clock.advance(by: 5 * 60)
        model.requestDiscardTimer()
        #expect(model.pendingDeletion == .runningTimer)
        #expect(model.deletionTitle == "Laufende Zeit verwerfen?")
        #expect(model.deletionMessage == "0:05 Std. für „Titelseite“ werden nicht gebucht.")
        #expect(model.deletionConfirmTitle == "Verwerfen")
        model.cancelDeletion()
        #expect(model.runningTimer != nil)
        model.requestDiscardTimer()
        await model.confirmDeletion()
        #expect(model.runningTimer == nil)
        #expect(odoo.withLock { odoo.lines.isEmpty })
    }

    @Test("ein Timer zur Zeit: erneut starten bucht die laufende Zeit bis zum neuen Start")
    func switchesTimer() async throws {
        let odoo = FakeOdoo()
        odoo.withLock {
            odoo.lines = [.init(id: 1, date: "2026-10-23", name: "Plugin-Updates", projectID: 2, taskID: 21, hours: 0.5)]
        }
        let clock = MovingClock()
        let model = try await signedIn(odoo, clock: clock)
        try await fillDraft(model)
        await model.startTimer()
        clock.advance(by: 10 * 60)

        let entry = try #require(model.entries.first)
        #expect(model.canStartTimer(like: entry))
        await model.startTimer(like: entry)
        let timer = try #require(model.runningTimer)
        #expect(timer.projectID == 2 && timer.taskID == 21 && timer.description == "Plugin-Updates")
        #expect(timer.start == clock.now)
        #expect(model.timerNotice?.text == "0:10 Std. gebucht auf Kundenmagazin (Beispiel AG) › Layout.")
        #expect(odoo.withLock { odoo.lines.map(\.hours) } == [0.5, 10.0 / 60])
        // Genau diese Zeit läuft schon.
        #expect(!model.canStartTimer(like: entry))
        #expect(model.recentProjectIDs.first == 2)
    }

    @Test("ohne Netz bleibt die Zeit gestoppt stehen; erneut versuchen bucht sie einmal")
    func stopOffline() async throws {
        let odoo = FakeOdoo()
        let clock = MovingClock()
        let model = try await signedIn(odoo, clock: clock)
        try await fillDraft(model)
        await model.startTimer()
        clock.advance(by: 20 * 60)

        odoo.withLock { odoo.offline = true }
        await model.stopTimer()
        #expect(model.timerError == "Keine Verbindung zu Odoo. Deine Angaben bleiben erhalten.")
        #expect(model.runningTimer?.end == clock.now)
        clock.advance(by: 5 * 60)
        await model.tick()
        #expect(model.timerSeconds() == 20 * 60)
        #expect(model.menuBarContent.accessibilityLabel == "\(AppInfo.name), Projektzeit 20 Minuten noch nicht gebucht")
        // Starten bucht erst die gestoppte Zeit; ohne Netz startet nichts Neues.
        let entry = TimesheetEntry(id: 9, description: "Wartung", project: Reference(id: 2, name: "Website-Betreuung"),
                                   task: Reference(id: 21, name: "Wartung"), minutes: 15)
        await model.startTimer(like: entry)
        #expect(model.runningTimer?.projectID == 3)

        odoo.withLock {
            odoo.offline = false
            odoo.loseNextCreateResponse = true
        }
        await model.stopTimer()
        #expect(model.timerError != nil)
        #expect(odoo.withLock { odoo.lines.count } == 1)
        await model.stopTimer()
        #expect(model.timerError == nil)
        #expect(model.runningTimer == nil)
        #expect(odoo.withLock { odoo.lines.map(\.hours) } == [20.0 / 60])
    }

    @Test("über Mitternacht bucht auf den Tag, an dem die Zeit begann")
    func overMidnight() async throws {
        let odoo = FakeOdoo()
        let clock = MovingClock()
        let model = try await signedIn(odoo, clock: clock)
        try await fillDraft(model)
        await model.startTimer()
        clock.advance(by: 10 * 3600)
        await model.tick()
        #expect(model.dayTitle == "Heute")
        #expect(model.timerStartText == "seit Fr. 23.10. 14:52")
        await model.stopTimer()
        #expect(odoo.withLock { odoo.lines.map(\.date) } == ["2026-10-23"])
        #expect(odoo.withLock { odoo.lines.map(\.hours) } == [10])
    }

    @Test("Starten im Formular nur heute und nicht beim Bearbeiten")
    func startOnlyToday() async throws {
        let odoo = FakeOdoo()
        odoo.withLock {
            odoo.lines = [.init(id: 1, date: "2026-10-23", name: "Plugin-Updates", projectID: 2, taskID: 21, hours: 0.5)]
        }
        let model = try await signedIn(odoo, clock: MovingClock())
        try await fillDraft(model)
        #expect(model.offersTimerStart)
        model.showPreviousDay()
        #expect(!model.offersTimerStart && !model.canStartTimer)
        model.showToday()
        model.beginEditing(try #require(model.entries.first))
        #expect(!model.offersTimerStart)
    }

    @Test("übersteht einen Neustart; Abmelden verwirft die Zeit")
    func survivesRestart() async throws {
        let odoo = FakeOdoo()
        let clock = MovingClock()
        let defaults = ScratchDefaults.make("zeiterfassung-tests")
        let secrets = MemorySecretStore()
        let first = try await signedIn(odoo, clock: clock, defaults: defaults, secrets: secrets)
        try await fillDraft(first)
        await first.startTimer()
        clock.advance(by: 3 * 60)

        let second = AppModel(preferences: Preferences(defaults: defaults), http: odoo.client(), secrets: secrets,
                              calendar: TestClock.calendar, clock: { clock.now })
        await second.start()
        defer { second.stop() }
        #expect(second.runningTimer?.description == "Titelseite")
        #expect(second.timerSeconds() == 3 * 60)
        #expect(second.menuBarContent.text == "0:03")

        second.signOut()
        #expect(second.preferences.runningTimer == nil)
    }
}
