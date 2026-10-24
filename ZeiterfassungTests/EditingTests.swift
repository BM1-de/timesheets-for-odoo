// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Zeiterfassung

@MainActor
@Suite("Bearbeiten und Löschen")
struct EditingTests {
    private func signedIn(_ odoo: FakeOdoo) async throws -> AppModel {
        let defaults = ScratchDefaults.make("zeiterfassung-tests")
        let model = AppModel(preferences: Preferences(defaults: defaults), http: odoo.client(), secrets: MemorySecretStore(),
                             calendar: TestClock.calendar, clock: { TestClock.now })
        try await model.signIn(server: "odoo.example.de", apiKey: odoo.apiKey,
                               login: odoo.mode == .odoo19 ? nil : odoo.login, database: nil)
        model.finishSignIn()
        await model.refresh(force: true)
        return model
    }

    private func line(_ odoo: FakeOdoo, _ id: Int) -> FakeOdoo.Line? {
        odoo.withLock { odoo.lines.first { $0.id == id } }
    }

    private func attendance(_ odoo: FakeOdoo, _ id: Int) -> FakeOdoo.Attendance? {
        odoo.withLock { odoo.attendances.first { $0.id == id } }
    }

    // MARK: - Zeiteinträge

    @Test("ein Eintrag öffnet sich im Formular; danach kommt der angefangene neue zurück", arguments: [FakeOdoo.Mode.odoo19, .odoo18, .odoo17])
    func editsEntry(mode: FakeOdoo.Mode) async throws {
        let odoo = FakeOdoo(mode: mode)
        odoo.withLock { odoo.lines = [.init(id: 1, date: "2026-10-23", name: "Plugin-Updates", projectID: 2, taskID: 21, hours: 0.25)] }
        let model = try await signedIn(odoo)
        model.draft.description = "angefangen"

        let entry = try #require(model.entries.first)
        model.beginEditing(entry)
        await model.loadTasks(projectID: 2)
        #expect(model.editingEntry?.id == 1)
        #expect(model.draft == AppModel.Draft(projectID: 2, taskID: 21, description: "Plugin-Updates", durationText: "0:15"))
        #expect(model.editDay == CalendarDay(year: 2026, month: 10, day: 23))

        model.draft.description = "Plugin-Updates und Sicherung"
        model.draft.durationText = "0:45"
        await model.save()
        #expect(model.saveError == nil)
        #expect(model.editingEntry == nil)
        #expect(model.draft.description == "angefangen")
        #expect(line(odoo, 1)?.name == "Plugin-Updates und Sicherung")
        #expect(line(odoo, 1)?.hours == 0.75)
        #expect(model.entries.map(\.minutes) == [45])
        #expect(odoo.log.contains("account.analytic.line.write"))
    }

    @Test("Abbrechen lässt den Eintrag, wie er ist")
    func cancelsEditing() async throws {
        let odoo = FakeOdoo()
        odoo.withLock { odoo.lines = [.init(id: 1, date: "2026-10-23", name: "Plugin-Updates", projectID: 2, taskID: 21, hours: 0.25)] }
        let model = try await signedIn(odoo)
        model.beginEditing(try #require(model.entries.first))
        model.draft.description = "verworfen"
        model.cancelEditing()
        #expect(model.editingEntry == nil)
        #expect(model.draft == AppModel.Draft())
        #expect(line(odoo, 1)?.name == "Plugin-Updates")
        #expect(!odoo.log.contains("account.analytic.line.write"))
    }

    @Test("eine unveränderte Dauer bleibt minutengenau, eine geänderte wird gerundet")
    func keepsExactDuration() async throws {
        let odoo = FakeOdoo()
        odoo.withLock { odoo.lines = [.init(id: 1, date: "2026-10-23", name: "Telefonat", projectID: 2, taskID: 21, hours: 47.0 / 60)] }
        let model = try await signedIn(odoo)
        model.beginEditing(try #require(model.entries.first))
        await model.loadTasks(projectID: 2)
        #expect(model.draft.durationText == "0:47")
        #expect(model.draftMinutes == 47)
        #expect(model.durationHint == nil)
        model.draft.durationText = "0:50"
        #expect(model.draftMinutes == 45)
        model.draft.durationText = "0:47"
        await model.save()
        #expect(abs((line(odoo, 1)?.hours ?? 0) - 47.0 / 60) < 0.0001)
    }

    @Test("mit neuem Datum wandert der Eintrag auf den anderen Tag")
    func movesToAnotherDay() async throws {
        let odoo = FakeOdoo()
        odoo.withLock { odoo.lines = [.init(id: 1, date: "2026-10-23", name: "Plugin-Updates", projectID: 2, taskID: 21, hours: 0.25)] }
        let model = try await signedIn(odoo)
        model.beginEditing(try #require(model.entries.first))
        await model.loadTasks(projectID: 2)
        #expect(model.editDayChoices.count == 7)
        model.editDay = CalendarDay(year: 2026, month: 10, day: 22)
        #expect(model.dayChoiceTitle(model.editDay) == "Gestern, Do. 22.10.")
        await model.save()
        #expect(line(odoo, 1)?.date == "2026-10-22")
        #expect(model.entries.isEmpty)
        model.showPreviousDay()
        await model.refresh(force: true)
        #expect(model.entries.map(\.id) == [1])
    }

    @Test("die erledigte Aufgabe eines Eintrags bleibt wählbar; ohne Aufgabe gebucht darf er so bleiben")
    func keepsClosedTaskAndMissingTask() async throws {
        let odoo = FakeOdoo()
        odoo.withLock {
            odoo.closedTasks = [33: "Korrektur"]
            odoo.lines = [
                .init(id: 1, date: "2026-10-23", name: "Satzfehler", projectID: 3, taskID: 33, hours: 1),
                .init(id: 2, date: "2026-10-23", name: "Abstimmung", projectID: 3, taskID: nil, hours: 0.5),
            ]
        }
        let model = try await signedIn(odoo)
        model.beginEditing(try #require(model.entries.first { $0.id == 1 }))
        await model.loadTasks(projectID: 3)
        guard case .tasks(let tasks) = model.taskChoice else { Issue.record("keine Aufgaben"); return }
        #expect(tasks.map(\.name) == ["Korrektur", "Text", "Layout"])
        #expect(model.draft.taskID == 33)
        #expect(model.selectedTaskName == "Korrektur")
        #expect(model.canSave)

        model.beginEditing(try #require(model.entries.first { $0.id == 2 }))
        await model.loadTasks(projectID: 3)
        #expect(model.draft.taskID == nil)
        #expect(!model.taskIsRequired)
        #expect(model.canSave)
        model.draft.description = "Abstimmung mit dem Verlag"
        await model.save()
        #expect(model.saveError == nil)
        #expect(line(odoo, 2)?.taskID == nil)
        #expect(line(odoo, 2)?.name == "Abstimmung mit dem Verlag")
    }

    @Test("abgerechnet: nur die Beschreibung lässt sich ändern, löschen nicht", arguments: [FakeOdoo.Mode.odoo19, .odoo18, .odoo17])
    func invoicedEntry(mode: FakeOdoo.Mode) async throws {
        let odoo = FakeOdoo(mode: mode)
        odoo.withLock {
            odoo.lines = [.init(id: 1, date: "2026-10-23", name: "Beiträge", projectID: 2, taskID: 21, hours: 2.5, invoiced: true)]
        }
        let model = try await signedIn(odoo)
        let entry = try #require(model.entries.first)
        #expect(entry.lock == .invoiced)
        model.beginEditing(entry)
        #expect(model.editingIsLimited)
        #expect(model.canSave)
        model.draft.description = "Beiträge für November"
        model.draft.durationText = "1:00"
        await model.save()
        #expect(model.saveError == nil)
        #expect(line(odoo, 1)?.name == "Beiträge für November")
        #expect(line(odoo, 1)?.hours == 2.5)

        model.askToDelete(.entry(try #require(model.entries.first)))
        #expect(model.pendingDeletion == nil)
    }

    @Test("Löschen erst nach der Rückfrage", arguments: [FakeOdoo.Mode.odoo19, .odoo18, .odoo17])
    func deletesEntry(mode: FakeOdoo.Mode) async throws {
        let odoo = FakeOdoo(mode: mode)
        odoo.withLock { odoo.lines = [.init(id: 1, date: "2026-10-23", name: "Plugin-Updates", projectID: 2, taskID: 21, hours: 0.25)] }
        let model = try await signedIn(odoo)
        let entry = try #require(model.entries.first)
        model.beginEditing(entry)
        model.askToDelete(.entry(entry))
        #expect(model.deletionTitle == "Eintrag löschen?")
        #expect(model.deletionMessage == "„Plugin-Updates“ (0:15 Std.) wird in Odoo gelöscht.")
        model.cancelDeletion()
        #expect(line(odoo, 1) != nil)

        model.askToDelete(.entry(entry))
        await model.confirmDeletion()
        #expect(model.pendingDeletion == nil)
        #expect(line(odoo, 1) == nil)
        #expect(model.entries.isEmpty)
        #expect(model.editingEntry == nil)
    }

    @Test("ein anderer Tag beendet das Bearbeiten")
    func navigationCancelsEditing() async throws {
        let odoo = FakeOdoo()
        odoo.withLock { odoo.lines = [.init(id: 1, date: "2026-10-23", name: "Plugin-Updates", projectID: 2, taskID: 21, hours: 0.25)] }
        let model = try await signedIn(odoo)
        model.draft.durationText = "1:00"
        model.beginEditing(try #require(model.entries.first))
        model.showPreviousDay()
        #expect(model.editingEntry == nil)
        #expect(model.draft.durationText == "1:00")
    }

    @Test("lehnt Odoo die Änderung ab, bleibt das Formular mit Fehler offen")
    func editFailure() async throws {
        let odoo = FakeOdoo()
        odoo.withLock { odoo.lines = [.init(id: 1, date: "2026-10-23", name: "Plugin-Updates", projectID: 2, taskID: 21, hours: 0.25)] }
        let model = try await signedIn(odoo)
        model.beginEditing(try #require(model.entries.first))
        await model.loadTasks(projectID: 2)
        model.draft.description = "neu"
        odoo.withLock { odoo.failNextWrite = true }
        await model.save()
        #expect(model.saveError != nil)
        #expect(model.editingEntry?.id == 1)
        await model.save()
        #expect(model.saveError == nil)
        #expect(line(odoo, 1)?.name == "neu")
    }

    // MARK: - Anwesenheiten

    /// Heute 08:12–12:05 und seit 12:47 (Ortszeit).
    private func today(_ odoo: FakeOdoo) {
        odoo.withLock {
            odoo.attendances = [
                .init(id: 1, checkIn: "2026-10-23 06:12:00", checkOut: "2026-10-23 10:05:00"),
                .init(id: 2, checkIn: "2026-10-23 10:47:00", checkOut: nil),
            ]
        }
    }

    private func period(_ model: AppModel, _ id: Int) throws -> AttendancePeriod {
        try #require(model.shownPeriods.first { $0.id == id })
    }

    @Test("Zeiten des Tages mit Pausen dazwischen")
    func listsPeriodsAndGaps() async throws {
        let odoo = FakeOdoo()
        today(odoo)
        let model = try await signedIn(odoo)
        let summary = model.attendanceSummary
        #expect(summary.rows.map(\.range) == ["08:12 – 12:05", "Pause 12:05 – 12:47", "12:47 – jetzt"])
        #expect(summary.rows.map(\.duration) == ["3:53", "0:42", "2:05"])
        #expect(summary.canEdit)
        #expect(summary.attention == nil)
        #expect(!model.showsAttendanceList)
        model.setAttendanceListExpanded(true)
        #expect(model.showsAttendanceList)
    }

    @Test("Beginn korrigieren", arguments: [FakeOdoo.Mode.odoo19, .odoo18, .odoo17])
    func correctsStart(mode: FakeOdoo.Mode) async throws {
        let odoo = FakeOdoo(mode: mode)
        today(odoo)
        let model = try await signedIn(odoo)
        model.editPeriod(try period(model, 1))
        #expect(model.attendanceEditor?.from == "08:12")
        #expect(model.attendanceEditor?.to == "12:05")
        model.attendanceEditor?.from = "800"
        #expect(model.attendanceEditorDuration == "4:05 Std.")
        await model.saveAttendance()
        #expect(model.attendanceEditor == nil)
        #expect(attendance(odoo, 1)?.checkIn == "2026-10-23 06:00:00")
        #expect(attendance(odoo, 1)?.checkOut == "2026-10-23 10:05:00")
        #expect(model.attendanceNotice == AppModel.AttendanceNotice(kind: .done, text: "Zeitraum gesichert."))
        #expect(model.attendanceSummary.rows.first?.range == "08:00 – 12:05")
    }

    @Test("prüft Eingaben wie Odoo, bevor etwas gesendet wird")
    func validatesInput() async throws {
        let odoo = FakeOdoo()
        today(odoo)
        let model = try await signedIn(odoo)
        let checks: [(from: String, to: String, error: String)] = [
            ("acht", "12:05", "Bitte Uhrzeiten wie 8:30 oder 830 eingeben."),
            ("08:12", "7:00", "Das Ende muss nach dem Beginn liegen."),
            ("08:12", "13:00", "Überschneidet sich mit 12:47 – jetzt."),
            ("08:12", "15:30", "Die Zeit liegt in der Zukunft."),
        ]
        for check in checks {
            model.editPeriod(try period(model, 1))
            model.attendanceEditor?.from = check.from
            model.attendanceEditor?.to = check.to
            await model.saveAttendance()
            #expect(model.attendanceEditor?.error == check.error)
            model.cancelAttendanceEditing()
        }
        #expect(!odoo.log.contains("hr.attendance.write"))
    }

    @Test("eine Pause nach hinten schieben: erst der spätere Teil, sonst überschnitte sich das")
    func movesBreakLater() async throws {
        let odoo = FakeOdoo()
        today(odoo)
        let model = try await signedIn(odoo)
        let gap = try #require(model.attendanceSummary.rows.first { if case .gap = $0.kind { true } else { false } })
        guard case .gap(let before, let after) = gap.kind else { return }
        model.editGap(before: before, after: after)
        #expect(model.attendanceEditor?.from == "12:05")
        #expect(model.attendanceEditor?.to == "12:47")
        #expect(model.attendanceEditorHint?.text == "Sichern ändert das Ende des Zeitraums davor und den Beginn des Zeitraums danach.")
        model.attendanceEditor?.from = "13:00"
        model.attendanceEditor?.to = "13:30"
        #expect(model.attendanceEditorDuration == "30 Min.")
        await model.saveAttendance()
        #expect(model.attendanceEditor == nil)
        #expect(attendance(odoo, 1)?.checkOut == "2026-10-23 11:00:00")
        #expect(attendance(odoo, 2)?.checkIn == "2026-10-23 11:30:00")
        #expect(model.attendanceNotice?.text == "Pause verschoben.")
    }

    @Test("eine Pause nach vorn schieben: erst der frühere Teil")
    func movesBreakEarlier() async throws {
        let odoo = FakeOdoo()
        today(odoo)
        let model = try await signedIn(odoo)
        model.editGap(before: try period(model, 1), after: try period(model, 2))
        model.attendanceEditor?.from = "11:30"
        model.attendanceEditor?.to = "12:00"
        await model.saveAttendance()
        #expect(model.attendanceEditor == nil)
        #expect(attendance(odoo, 1)?.checkOut == "2026-10-23 09:30:00")
        #expect(attendance(odoo, 2)?.checkIn == "2026-10-23 10:00:00")

        model.editGap(before: try period(model, 1), after: try period(model, 2))
        model.attendanceEditor?.from = "7:00"
        model.attendanceEditor?.to = "12:00"
        await model.saveAttendance()
        #expect(model.attendanceEditor?.error == "Die Pause muss zwischen 08:12 und jetzt liegen.")
    }

    @Test("an einem Tag ohne Anwesenheit nachtragen", arguments: [FakeOdoo.Mode.odoo19, .odoo18, .odoo17])
    func addsMissingDay(mode: FakeOdoo.Mode) async throws {
        let odoo = FakeOdoo(mode: mode)
        let model = try await signedIn(odoo)
        model.showPreviousDay()
        await model.refresh(force: true)
        #expect(model.attendanceSummary.offersAdding)
        model.addAttendancePeriod()
        model.attendanceEditor?.from = "8"
        model.attendanceEditor?.to = "12:30"
        await model.saveAttendance()
        #expect(model.attendanceEditor == nil)
        let added = try #require(odoo.withLock { odoo.attendances.first })
        #expect(added.checkIn == "2026-10-22 06:00:00")
        #expect(added.checkOut == "2026-10-22 10:30:00")
        #expect(model.attendanceNotice?.text == "Zeitraum nachgetragen.")
        #expect(model.attendanceSummary.title == "Anwesend 08:00 – 12:30")
    }

    @Test("Zeitraum löschen nach Rückfrage", arguments: [FakeOdoo.Mode.odoo19, .odoo18, .odoo17])
    func deletesPeriod(mode: FakeOdoo.Mode) async throws {
        let odoo = FakeOdoo(mode: mode)
        today(odoo)
        let model = try await signedIn(odoo)
        let first = try period(model, 1)
        model.editPeriod(first)
        model.askToDelete(.period(first))
        #expect(model.deletionTitle == "Zeitraum löschen?")
        #expect(model.deletionMessage == "08:12 – 12:05 wird in Odoo gelöscht.")
        await model.confirmDeletion()
        #expect(attendance(odoo, 1) == nil)
        #expect(model.attendanceEditor == nil)
        #expect(model.attendanceNotice?.text == "Zeitraum gelöscht.")
        #expect(model.shownPeriods.map(\.id) == [2])
    }

    @Test("automatisch ausgestempelt: aufgeklappt, nach dem Korrigieren bestätigt")
    func correctsAutomaticCheckOut() async throws {
        let odoo = FakeOdoo()
        odoo.withLock {
            odoo.attendances = [.init(id: 5, checkIn: "2026-10-22 06:00:00", checkOut: "2026-10-22 16:00:00",
                                      inMode: "manual", outMode: "auto_check_out")]
        }
        let model = try await signedIn(odoo)
        model.showPreviousDay()
        await model.refresh(force: true)
        #expect(model.attendanceSummary.attention == "Automatisch beendet")
        #expect(model.showsAttendanceList)
        model.editPeriod(try period(model, 5))
        model.attendanceEditor?.to = "16:30"
        await model.saveAttendance()
        #expect(attendance(odoo, 5)?.checkOut == "2026-10-22 14:30:00")
        #expect(attendance(odoo, 5)?.outMode == "manual")
        #expect(model.attendanceSummary.attention == nil)
    }

    @Test("ohne das Recht dazu nur Anzeige, mit Hinweis")
    func readOnlyAttendance() async throws {
        let odoo = FakeOdoo()
        odoo.canStamp = false
        odoo.withLock {
            odoo.attendances = [.init(id: 5, checkIn: "2026-10-22 06:00:00", checkOut: "2026-10-22 14:00:00")]
        }
        let model = try await signedIn(odoo)
        model.showPreviousDay()
        await model.refresh(force: true)
        let summary = model.attendanceSummary
        #expect(!summary.canEdit)
        #expect(summary.note == "Deine Anwesenheiten kannst du hier nicht ändern. Korrekturen trägt die für Anwesenheiten zuständige Person in Odoo ein.")
        model.editPeriod(try period(model, 5))
        #expect(model.attendanceEditor == nil)
        model.addAttendancePeriod()
        #expect(model.attendanceEditor == nil)
    }

    @Test("lehnt Odoo die Korrektur ab, verschwindet das Bearbeiten bis zur erneuten Prüfung")
    func refusedCorrection() async throws {
        let odoo = FakeOdoo()
        today(odoo)
        let model = try await signedIn(odoo)
        odoo.withLock { odoo.stampDeniedByRule = true }
        model.editPeriod(try period(model, 1))
        model.attendanceEditor?.from = "8:00"
        await model.saveAttendance()
        #expect(model.capabilities?.canStamp == false)
        #expect(model.preferences.stampingRefused)
        #expect(model.attendanceEditor == nil)
        #expect(model.attendanceNotice?.kind == .warning)
        #expect(!model.canEditAttendance)
    }

    // MARK: - Modul Arbeitszeitgesetz

    @Test("Modul Arbeitszeitgesetz: eingefügte Pause erkennen, verschieben, Odoo ergänzt den Rest")
    func breakModule() async throws {
        let odoo = FakeOdoo()
        odoo.withLock {
            odoo.breakModule = true
            // Donnerstag 07:45–12:00 und, von Odoo angelegt, 12:30–17:00
            odoo.attendances = [
                .init(id: 11, checkIn: "2026-10-22 05:45:00", checkOut: "2026-10-22 10:00:00", inMode: "manual", outMode: "manual"),
                .init(id: 12, checkIn: "2026-10-22 10:30:00", checkOut: "2026-10-22 15:00:00", inMode: "technical", outMode: "manual"),
            ]
        }
        let model = try await signedIn(odoo)
        #expect(model.capabilities?.schema.breakRules == BreakRules())
        model.showPreviousDay()
        await model.refresh(force: true)
        let summary = model.attendanceSummary
        #expect(summary.attention == "Pause eingefügt")
        let gap = try #require(summary.rows.first { $0.isInsertedBreak })
        guard case .gap(let before, let after) = gap.kind else { return }

        model.editGap(before: before, after: after)
        #expect(model.attendanceEditorHint == AppModel.Hint(text: "Passt: Bei 8:45 Std. Arbeit sind 30 Min. Pause nötig.", isProblem: false))
        model.attendanceEditor?.from = "13:00"
        model.attendanceEditor?.to = "13:15"
        #expect(model.attendanceEditorHint == AppModel.Hint(
            text: "Bei 9:00 Std. Arbeit sind 30 Min. Pause nötig. Odoo ergänzt beim Sichern 15 Min.", isProblem: true))
        await model.saveAttendance()
        #expect(model.attendanceEditor == nil)
        #expect(attendance(odoo, 12)?.inMode == "manual")
        #expect(model.attendanceNotice == AppModel.AttendanceNotice(
            kind: .info, text: "Gesichert. Odoo hat 15 Min. Pause eingefügt (10:15 – 10:30)."))
    }

    @Test("Uhrzeiten in den Feldern „von“ und „bis“")
    func readsClockTimes() {
        let cases: [(String, Int?)] = [
            ("8:30", 510), ("08.30", 510), ("8h30", 510), ("830", 510), ("8", 480), ("17", 1020), (" 7:05 ", 425),
            ("8:30 AM", 510), ("12 pm", 720), ("12am", 0), ("5:15 p.m.", 1035),
            ("24:00", nil), ("8:60", nil), ("13 pm", nil), ("acht", nil), ("", nil),
        ]
        for (text, minutes) in cases {
            #expect(ClockInput.minutes(from: text) == minutes, "\(text)")
        }
    }
}
