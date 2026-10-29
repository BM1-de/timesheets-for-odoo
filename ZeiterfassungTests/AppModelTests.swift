// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Zeiterfassung

@MainActor
@Suite("Abläufe der App")
struct AppModelTests {
    private func makeModel(_ odoo: FakeOdoo, secrets: MemorySecretStore = MemorySecretStore(),
                           http: (any HTTPClient)? = nil, clock: MovingClock? = nil) -> AppModel {
        let defaults = ScratchDefaults.make("zeiterfassung-tests")
        return AppModel(preferences: Preferences(defaults: defaults), http: http ?? odoo.client(), secrets: secrets,
                        calendar: TestClock.calendar, clock: { clock?.now ?? TestClock.now })
    }

    private func signedIn(_ odoo: FakeOdoo, http: (any HTTPClient)? = nil, clock: MovingClock? = nil) async throws -> AppModel {
        let model = makeModel(odoo, http: http, clock: clock)
        try await model.signIn(server: "odoo.example.de", apiKey: odoo.apiKey,
                               login: odoo.mode == .odoo19 ? nil : odoo.login, database: nil)
        model.finishSignIn()
        await model.refresh(force: true)
        return model
    }

    /// Projekt „Website-Betreuung“ mit seiner einzigen Aufgabe, Beschreibung und Dauer.
    private func fillDraft(_ model: AppModel) async throws {
        model.selectProject(try #require(model.projects.first { $0.id == 2 }))
        await model.loadTasks(projectID: 2)
        model.draft.description = "Plugin-Updates"
        model.draft.durationText = "0:15"
    }

    @Test("Anmeldung legt den Schlüssel ab und zeigt erst nach „Fertig“ den Tag")
    func signIn() async throws {
        let odoo = FakeOdoo()
        let secrets = MemorySecretStore()
        let model = makeModel(odoo, secrets: secrets)
        await model.start()
        defer { model.stop() }
        #expect(model.screen == .login)

        let found = try await model.signIn(server: "odoo.example.de", apiKey: "  \(odoo.apiKey)  ", login: nil, database: nil)
        #expect(found.timesheets == .available)
        #expect(model.screen == .login)
        #expect(secrets.count == 1)
        #expect(model.preferences.session?.serverURL.absoluteString == "https://odoo.example.de")
        #expect(model.preferences.timesheetsEnabled && model.preferences.attendanceEnabled)

        model.finishSignIn()
        #expect(model.screen == .main)
        #expect(model.menuBarContent.isSignedIn)
    }

    @Test("unverschlüsselte Adresse wird abgelehnt")
    func insecureServer() async {
        let model = makeModel(FakeOdoo())
        await #expect(throws: OdooError.insecureServerAddress) {
            try await model.signIn(server: "http://odoo.example.de", apiKey: "x", login: nil, database: nil)
        }
    }

    @Test("Neustart: Sitzung aus den Einstellungen, Schlüssel aus dem Schlüsselbund")
    func restoresSession() async throws {
        let odoo = FakeOdoo()
        let secrets = MemorySecretStore()
        let defaults = ScratchDefaults.make("zeiterfassung-tests")
        let first = AppModel(preferences: Preferences(defaults: defaults), http: odoo.client(), secrets: secrets,
                             calendar: TestClock.calendar, clock: { TestClock.now })
        try await first.signIn(server: "odoo.example.de", apiKey: odoo.apiKey, login: nil, database: nil)

        let second = AppModel(preferences: Preferences(defaults: defaults), http: odoo.client(), secrets: secrets,
                              calendar: TestClock.calendar, clock: { TestClock.now })
        await second.start()
        defer { second.stop() }
        #expect(second.screen == .main)
        #expect(second.capabilities?.userName == "Erika Mustermann")
    }

    @Test("bucht einen Eintrag: Projekt, Aufgabe, Dauer, Summe", arguments: [FakeOdoo.Mode.odoo19, .odoo18, .odoo17])
    func booksEntry(mode: FakeOdoo.Mode) async throws {
        let odoo = FakeOdoo(mode: mode)
        let model = try await signedIn(odoo)
        #expect(model.entries.isEmpty)
        #expect(model.isDayLoaded)
        #expect(!model.canSave)

        let project = try #require(model.projects.first { $0.id == 3 })
        model.selectProject(project)
        await model.loadTasks(projectID: 3)
        #expect(model.taskChoice == .tasks([ProjectTask(id: 31, name: "Text"), ProjectTask(id: 32, name: "Layout")]))
        #expect(model.draft.taskID == nil)
        model.draft.taskID = 32
        model.draft.description = "Korrekturen eingearbeitet"
        model.draft.durationText = "1,5"
        #expect(model.canSave)

        await model.save()
        #expect(model.saveError == nil)
        #expect(model.draft.description.isEmpty && model.draft.durationText.isEmpty)
        #expect(model.draft.projectID == 3 && model.draft.taskID == 32)
        #expect(model.entries.map(\.minutes) == [90])
        #expect(model.bookedMinutes == 90)
        #expect(model.menuBarContent.text == "1:30")
        #expect(model.recentProjectIDs.first == 3)
        #expect(odoo.withLock { odoo.lines.first?.date } == "2026-10-23")
    }

    @Test("Projekt mit nur einer Aufgabe wählt sie vor; ohne Aufgaben aufs Projekt")
    func taskPreselection() async throws {
        let odoo = FakeOdoo()
        let model = try await signedIn(odoo)
        model.selectProject(try #require(model.projects.first { $0.id == 2 }))
        await model.loadTasks(projectID: 2)
        #expect(model.draft.taskID == 21)

        model.selectProject(try #require(model.projects.first { $0.id == 4 }))
        await model.loadTasks(projectID: 4)
        #expect(model.taskChoice == .noTasks)
        #expect(!model.taskIsRequired)
        model.draft.durationText = "0:30"
        #expect(model.canSave)
    }

    @Test("ohne Netz bleibt das Formular stehen")
    func saveOffline() async throws {
        let odoo = FakeOdoo()
        let model = try await signedIn(odoo)
        model.selectProject(try #require(model.projects.first { $0.id == 2 }))
        await model.loadTasks(projectID: 2)
        model.draft.description = "Plugin-Updates"
        model.draft.durationText = "0:15"

        odoo.withLock { odoo.offline = true }
        await model.save()
        #expect(model.saveError == "Keine Verbindung zu Odoo. Deine Angaben bleiben erhalten.")
        #expect(model.draft.description == "Plugin-Updates")
        #expect(model.draft.durationText == "0:15")

        odoo.withLock { odoo.offline = false }
        await model.save()
        #expect(model.saveError == nil)
        #expect(model.entries.count == 1)
    }

    @Test("Dauer: Rundung, Hinweise, −/+")
    func duration() async throws {
        let model = try await signedIn(FakeOdoo())
        #expect(model.preferences.durationRounding == .quarterHour)
        model.preferences.durationRounding = .off
        model.draft.durationText = "1:20"
        #expect(model.draftMinutes == 80)
        #expect(model.durationHint == nil)
        model.preferences.durationRounding = .quarterHour
        #expect(model.draftMinutes == 75)
        #expect(model.durationHint == AppModel.Hint(text: "Wird als 1:15 Std. gebucht.", isProblem: false))
        model.preferences.durationRounding = .hour
        #expect(model.draftMinutes == 60)
        #expect(model.durationHint == AppModel.Hint(text: "Wird als 1:00 Std. gebucht.", isProblem: false))

        model.draft.durationText = "abc"
        #expect(model.durationHint?.isProblem == true)
        #expect(model.draftMinutes == nil)

        model.draft.durationText = "0:20"
        model.adjustDuration(by: 1)
        #expect(model.draft.durationText == "1:00")
        model.adjustDuration(by: -1)
        #expect(model.draft.durationText == "")

        model.preferences.durationRounding = .off
        model.draft.durationText = "0:20"
        model.adjustDuration(by: 1)
        #expect(model.draft.durationText == "0:30")
        model.adjustDuration(by: -1)
        model.adjustDuration(by: -1)
        #expect(model.draft.durationText == "")
        model.adjustDuration(by: -1)
        #expect(model.draft.durationText == "")
    }

    @Test("Anwesenheit: stempeln und Zusammenfassung, in der Menüleiste auf Wunsch")
    func attendance() async throws {
        let odoo = FakeOdoo()
        // Heute 08:12–12:05 (Ortszeit), seit 12:47 wieder anwesend.
        odoo.withLock {
            odoo.attendances = [
                .init(id: 1, checkIn: "2026-10-23 06:12:00", checkOut: "2026-10-23 10:05:00"),
                .init(id: 2, checkIn: "2026-10-23 10:47:00", checkOut: nil),
            ]
        }
        let model = try await signedIn(odoo)
        var summary = model.attendanceSummary
        #expect(summary.isRunning)
        #expect(summary.title == "Anwesend seit 12:47")
        #expect(summary.subtitle == "Heute 5:58 Std. · Pause 0:42")
        #expect(summary.buttonTitle == "Ausstempeln")
        #expect(summary.unbookedText == "5:58 Std.")
        #expect(model.menuBarContent.text.isEmpty)
        #expect(model.menuBarContent.showsDot)
        #expect(model.menuBarContent.accessibilityLabel == "\(AppInfo.name), eingestempelt")
        #expect(model.menuBarContent.toolTip == "Projektzeit heute 0:00 Std.\nAnwesend seit 12:47 · heute 5:58 Std.")
        model.preferences.menuBarTime = .attendanceToday
        #expect(model.menuBarContent.text == "5:58")
        #expect(model.menuBarContent.symbol == .person)
        #expect(model.menuBarContent.showsDot)
        #expect(model.menuBarContent.accessibilityLabel == "\(AppInfo.name), Anwesenheit heute 5 Stunden 58 Minuten, eingestempelt")
        model.preferences.menuBarTime = .symbolOnly
        #expect(model.menuBarContent.showsDot)

        await model.toggleAttendance()
        #expect(model.stampError == nil)
        summary = model.attendanceSummary
        #expect(!summary.isRunning)
        #expect(summary.title == "Ausgestempelt um 14:52")
        #expect(summary.buttonTitle == "Einstempeln")
        #expect(!model.menuBarContent.showsDot)
        model.preferences.menuBarTime = .attendanceToday
        #expect(model.menuBarContent.text == "5:58")
        #expect(model.menuBarContent.accessibilityLabel == "\(AppInfo.name), Anwesenheit heute 5 Stunden 58 Minuten")
        #expect(model.menuBarContent.toolTip == "Projektzeit heute 0:00 Std.\nAnwesend heute 5:58 Std.")
    }

    @Test("ohne Recht zum Stempeln nur Anzeige mit Hinweis")
    func attendanceReadOnly() async throws {
        let odoo = FakeOdoo()
        odoo.canStamp = false
        let model = try await signedIn(odoo)
        let summary = model.attendanceSummary
        #expect(summary.buttonTitle == nil)
        #expect(summary.note?.contains("„Sachbearbeiter: Alle Anwesenheiten verwalten“") == true)
        #expect(summary.note?.hasPrefix("Odoo hat") == false)
        #expect(summary.title == "Nicht eingestempelt")
    }

    @Test("nur Anwesenheit: Zeiten als Liste, in der Menüleiste die Anwesenheit")
    func attendanceOnly() async throws {
        let odoo = FakeOdoo()
        odoo.withLock {
            odoo.attendances = [.init(id: 1, checkIn: "2026-10-23 06:12:00", checkOut: "2026-10-23 10:05:00")]
        }
        let model = try await signedIn(odoo)
        #expect(model.setTimesheetsEnabled(false))
        await model.refresh(force: true)
        #expect(!model.timesheetsActive)
        #expect(model.effectiveMenuBarTime == .attendanceToday)
        #expect(model.menuBarContent.text == "3:53")
        #expect(model.menuBarContent.symbol == .person)
        #expect(model.menuBarContent.toolTip == "Anwesend heute 3:53 Std.")
        #expect(model.attendanceSummary.rows.map(\.range) == ["08:12 – 12:05"])
        // Die letzte Funktion bleibt an.
        #expect(!model.setAttendanceEnabled(false))
        #expect(model.attendanceActive)
    }

    @Test("ohne Odoo-App Anwesenheiten nur Zeiterfassung")
    func attendanceNotInstalled() async throws {
        let odoo = FakeOdoo()
        odoo.attendanceInstalled = false
        let model = try await signedIn(odoo)
        #expect(model.timesheetsActive)
        #expect(!model.attendanceActive)
        #expect(!model.preferences.attendanceEnabled)
        #expect(!model.setTimesheetsEnabled(false))
    }

    @Test("Tage blättern")
    func navigatesDays() async throws {
        let odoo = FakeOdoo()
        odoo.withLock {
            odoo.lines = [.init(id: 1, date: "2026-10-22", name: "Seitenstruktur abgestimmt", projectID: 1, taskID: 11, hours: 4)]
        }
        let model = try await signedIn(odoo)
        #expect(model.dayTitle == "Heute")
        #expect(model.entries.isEmpty)

        model.showPreviousDay()
        await model.refresh(force: true)
        #expect(model.dayTitle == "Gestern")
        #expect(model.dayLongDate == "Donnerstag, 22. Oktober 2026")
        #expect(model.entries.map(\.minutes) == [240])
        #expect(model.todayBookedMinutes == 0)
        #expect(model.attendanceSummary.title == "Keine Anwesenheit erfasst")

        model.showToday()
        #expect(model.isShowingToday)
        #expect(model.entries.isEmpty)
    }

    @Test("abgelaufener Schlüssel führt zur Anmeldung")
    func expiredKey() async throws {
        let odoo = FakeOdoo()
        let secrets = MemorySecretStore()
        let defaults = ScratchDefaults.make("zeiterfassung-tests")
        let model = AppModel(preferences: Preferences(defaults: defaults), http: odoo.client(), secrets: secrets,
                             calendar: TestClock.calendar, clock: { TestClock.now })
        try await model.signIn(server: "odoo.example.de", apiKey: odoo.apiKey, login: nil, database: nil)
        model.finishSignIn()
        // Schlüssel in Odoo widerrufen: Der gespeicherte passt nicht mehr.
        let account = try #require(model.session?.keychainAccount)
        try secrets.save("widerrufen", account: account, label: "")
        let restarted = AppModel(preferences: Preferences(defaults: defaults), http: odoo.client(), secrets: secrets,
                                 calendar: TestClock.calendar, clock: { TestClock.now })
        await restarted.start()
        defer { restarted.stop() }
        #expect(restarted.notice?.kind == .signedOut)

        restarted.showSignIn()
        #expect(restarted.screen == .login)
        restarted.cancelSignIn()
        #expect(restarted.screen == .main)
    }

    @Test("Abmelden löscht den Schlüssel")
    func signOut() async throws {
        let odoo = FakeOdoo()
        let secrets = MemorySecretStore()
        let model = makeModel(odoo, secrets: secrets)
        try await model.signIn(server: "odoo.example.de", apiKey: odoo.apiKey, login: nil, database: nil)
        model.finishSignIn()
        model.signOut()
        #expect(secrets.count == 0)
        #expect(model.screen == .login)
        #expect(model.preferences.session == nil)
        #expect(model.preferences.loginHints?.server == "https://odoo.example.de")
        #expect(!model.menuBarContent.isSignedIn)
    }

    @Test("bleibt die Antwort beim Speichern aus, legt „Erneut versuchen“ nichts doppelt an")
    func noDuplicateAfterLostResponse() async throws {
        let odoo = FakeOdoo()
        let model = try await signedIn(odoo)
        try await fillDraft(model)

        odoo.withLock { odoo.loseNextCreateResponse = true }
        await model.save()
        #expect(model.saveError == "Keine Verbindung zu Odoo. Deine Angaben bleiben erhalten.")
        #expect(model.draft.description == "Plugin-Updates")
        #expect(odoo.withLock { odoo.lines.count } == 1)

        await model.save()
        #expect(model.saveError == nil)
        #expect(odoo.withLock { odoo.lines.count } == 1)
        #expect(model.entries.map(\.minutes) == [15])
        #expect(model.draft.description.isEmpty)
    }

    @Test("lehnt Odoo ab, wird beim nächsten Versuch neu angelegt")
    func retriesRejectedSave() async throws {
        let odoo = FakeOdoo()
        let model = try await signedIn(odoo)
        try await fillDraft(model)
        odoo.withLock { odoo.failNextCreate = true }
        await model.save()
        #expect(model.saveError != nil)
        #expect(odoo.withLock { odoo.lines.count } == 0)
        await model.save()
        #expect(model.saveError == nil)
        #expect(odoo.withLock { odoo.lines.count } == 1)
    }

    @Test("was während des Speicherns getippt wird, bleibt stehen")
    func keepsTypingDuringSave() async throws {
        let odoo = FakeOdoo()
        let http = PausingHTTPClient(base: odoo.client()) { $0.url?.path().hasSuffix("/create") == true }
        let model = try await signedIn(odoo, http: http)
        try await fillDraft(model)

        async let saving: Void = model.save()
        await http.waitUntilPaused()
        model.draft.description = "Nächster Eintrag"
        http.resume()
        await saving
        #expect(model.saveError == nil)
        #expect(model.draft.description == "Nächster Eintrag")
        #expect(model.draft.durationText.isEmpty)
        #expect(odoo.withLock { odoo.lines.first?.name } == "Plugin-Updates")
    }

    @Test("Abmelden während des Speicherns: Was danach zurückkommt, wird verworfen")
    func signOutDuringSave() async throws {
        let odoo = FakeOdoo()
        let http = PausingHTTPClient(base: odoo.client()) { $0.url?.path().hasSuffix("/create") == true }
        let model = try await signedIn(odoo, http: http)
        try await fillDraft(model)

        async let saving: Void = model.save()
        await http.waitUntilPaused()
        model.signOut()
        http.resume()
        await saving
        #expect(model.screen == .login)
        #expect(!model.isSaving)
        #expect(model.saveError == nil)
        #expect(model.entries.isEmpty && model.todayEntries.isEmpty)
        #expect(model.recentProjectIDs.isEmpty)
    }

    @Test("scheitern nur die Anwesenheiten, erscheinen die Zeiteinträge trotzdem")
    func partialLoadFailure() async throws {
        let odoo = FakeOdoo()
        odoo.withLock {
            odoo.lines = [.init(id: 1, date: "2026-10-23", name: "Plugin-Updates", projectID: 2, taskID: 21, hours: 0.5)]
            odoo.failAttendanceRead = true
        }
        let model = try await signedIn(odoo)
        #expect(model.entries.map(\.minutes) == [30])
        #expect(model.todayBookedMinutes == 30)
        #expect(model.notice?.kind == .failure)
        #expect(model.notice?.message == "Anwesenheiten konnten nicht geladen werden. Kein Zugriff auf Anwesenheiten")

        odoo.withLock { odoo.failAttendanceRead = false }
        await model.refresh(force: true)
        #expect(model.notice == nil)
    }

    @Test("nach einem Fehler lädt die App selbst erneut, mit wachsendem Abstand")
    func retriesAfterFailure() async throws {
        let odoo = FakeOdoo()
        let time = MovingClock()
        let secrets = MemorySecretStore()
        let defaults = ScratchDefaults.make("zeiterfassung-tests")
        let first = AppModel(preferences: Preferences(defaults: defaults), http: odoo.client(), secrets: secrets,
                             calendar: TestClock.calendar, clock: { time.now })
        try await first.signIn(server: "odoo.example.de", apiKey: odoo.apiKey, login: nil, database: nil)

        // Start ohne Netz: erster Fehler
        odoo.withLock { odoo.offline = true }
        let http = odoo.client()
        let model = AppModel(preferences: Preferences(defaults: defaults), http: http, secrets: secrets,
                             calendar: TestClock.calendar, clock: { time.now })
        await model.start()
        defer { model.stop() }
        #expect(model.notice?.kind == .offline)

        // 20 Sekunden später der zweite Versuch …
        time.advance(by: 20)
        var sent = http.requests.count
        await model.tick()
        #expect(http.requests.count > sent)

        // … danach 40 Sekunden Abstand.
        time.advance(by: 20)
        sent = http.requests.count
        await model.tick()
        #expect(http.requests.count == sent)

        odoo.withLock { odoo.offline = false }
        time.advance(by: 20)
        await model.tick()
        #expect(model.notice == nil)
        #expect(model.isDayLoaded)
    }

    @Test("eine abgelaufene Anmeldung versucht die App nicht immer wieder")
    func noRetryWhenSignedOut() async throws {
        let odoo = FakeOdoo()
        let time = MovingClock()
        let secrets = MemorySecretStore()
        let defaults = ScratchDefaults.make("zeiterfassung-tests")
        let first = AppModel(preferences: Preferences(defaults: defaults), http: odoo.client(), secrets: secrets,
                             calendar: TestClock.calendar, clock: { time.now })
        try await first.signIn(server: "odoo.example.de", apiKey: odoo.apiKey, login: nil, database: nil)
        try secrets.save("widerrufen", account: try #require(first.session?.keychainAccount), label: "")

        let http = odoo.client()
        let model = AppModel(preferences: Preferences(defaults: defaults), http: http, secrets: secrets,
                             calendar: TestClock.calendar, clock: { time.now })
        await model.start()
        defer { model.stop() }
        #expect(model.notice?.kind == .signedOut)
        let sent = http.requests.count
        time.advance(by: 400)
        await model.tick()
        #expect(http.requests.count == sent)
    }

    @Test("lehnt Odoo das Stempeln trotz Recht ab, verschwindet der Knopf bis zur erneuten Prüfung")
    func stampRefusedByRule() async throws {
        let odoo = FakeOdoo()
        odoo.withLock { odoo.stampDeniedByRule = true }
        let model = try await signedIn(odoo)
        #expect(model.attendanceSummary.buttonTitle == "Einstempeln")

        await model.toggleAttendance()
        #expect(model.capabilities?.canStamp == false)
        #expect(model.preferences.cachedCapabilities?.canStamp == false)
        #expect(model.stampError == nil)
        #expect(model.attendanceSummary.buttonTitle == nil)
        #expect(model.attendanceSummary.note?.hasPrefix("Odoo hat das Stempeln abgelehnt.") == true)

        // Beim nächsten Start bleibt es dabei …
        await model.refreshCapabilities()
        #expect(model.capabilities?.canStamp == false)
        // … bis die Rechte in den Einstellungen erneut geprüft werden.
        odoo.withLock { odoo.stampDeniedByRule = false }
        await model.refreshCapabilities(recheck: true)
        #expect(model.capabilities?.canStamp == true)
        await model.toggleAttendance()
        #expect(model.openPeriod != nil)
    }

    @Test("Aufgaben werden nach zehn Minuten nachgeladen; erledigte fallen aus der Auswahl")
    func reloadsStaleTasks() async throws {
        let odoo = FakeOdoo()
        let time = MovingClock()
        let model = try await signedIn(odoo, clock: time)
        model.selectProject(try #require(model.projects.first { $0.id == 3 }))
        await model.loadTasks(projectID: 3)
        model.draft.taskID = 32
        odoo.withLock { odoo.tasks[3] = [(31, "Text"), (33, "Korrektur")] }

        time.advance(by: 300)
        await model.loadTasks(projectID: 3)
        #expect(model.taskChoice == .tasks([ProjectTask(id: 31, name: "Text"), ProjectTask(id: 32, name: "Layout")]))
        #expect(model.draft.taskID == 32)

        time.advance(by: 301)
        await model.loadTasks(projectID: 3)
        #expect(model.taskChoice == .tasks([ProjectTask(id: 31, name: "Text"), ProjectTask(id: 33, name: "Korrektur")]))
        #expect(model.draft.taskID == nil)
    }

    @Test("merkt sich die Datenbank nur, wenn sie eingegeben wurde")
    func remembersTypedDatabaseOnly() async throws {
        let single = FakeOdoo(mode: .odoo17)
        let first = makeModel(single)
        try await first.signIn(server: "odoo.example.de", apiKey: single.apiKey, login: single.login, database: nil)
        #expect(first.session?.database == "demo")
        #expect(first.preferences.loginHints?.database == nil)

        let several = FakeOdoo(mode: .odoo17)
        several.databases = ["demo", "test"]
        let second = makeModel(several)
        try await second.signIn(server: "odoo.example.de", apiKey: several.apiKey, login: several.login, database: " test ")
        #expect(second.preferences.loginHints?.database == "test")
    }

    @Test("Link „In Odoo öffnen“ je nach Version")
    func webLink() async throws {
        let modern = try await signedIn(FakeOdoo(mode: .odoo19))
        #expect(modern.odooWebURL?.absoluteString == "https://odoo.example.de/odoo/timesheets")
        let legacy = try await signedIn(FakeOdoo(mode: .odoo17))
        #expect(legacy.odooWebURL?.absoluteString == "https://odoo.example.de/web#action=hr_timesheet.act_hr_timesheet_line")
        #expect(legacy.interfaceDisplay == "Odoo 17 · JSON-RPC")
    }
}
