// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

#if DEBUG
import AppKit

/// Prüft im echten App-Prozess (Sandbox, Schlüsselbund, Netzwerk) die ganze Kette gegen ein
/// Test-Odoo, ohne Fenster. Nur in Entwicklungs-Builds:
///
///     ZEITERFASSUNG_SELFCHECK_URL=http://localhost:8079 ZEITERFASSUNG_SELFCHECK_KEY=… \
///     Zeiterfassung.app/Contents/MacOS/Zeiterfassung -selfCheck YES
///
/// Schreibt einen Zeiteintrag in das Test-Odoo. Nie gegen eine Datenbank mit echten Daten.
@MainActor
enum SelfCheck {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "selfCheck") }

    static func run() {
        Task {
            let passed = await check()
            print(passed ? "SELBSTTEST BESTANDEN" : "SELBSTTEST FEHLGESCHLAGEN")
            NSApp.terminate(nil)
        }
    }

    private static func report(_ ok: Bool, _ text: String) -> Bool {
        print("\(ok ? "✔" : "✘") \(text)")
        return ok
    }

    private static func check() async -> Bool {
        var passed = true

        // Schlüsselbund in der Sandbox
        let keychain = KeychainStore(service: AppInfo.bundleIdentifier + ".selbsttest")
        do {
            try keychain.save("geheim-123", account: "selbsttest", label: "Zeiterfassung Selbsttest")
            passed = report(keychain.read(account: "selbsttest") == "geheim-123", "Schlüsselbund: sichern und lesen") && passed
        } catch {
            passed = report(false, "Schlüsselbund: \(error.localizedDescription)") && passed
        }
        keychain.delete(account: "selbsttest")
        passed = report(keychain.read(account: "selbsttest") == nil, "Schlüsselbund: löschen") && passed

        // Ganze Kette gegen ein Test-Odoo
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["ZEITERFASSUNG_SELFCHECK_URL"], let apiKey = environment["ZEITERFASSUNG_SELFCHECK_KEY"] else {
            print("– Ohne ZEITERFASSUNG_SELFCHECK_URL/_KEY kein Test gegen Odoo.")
            return passed
        }
        let defaults = ScratchDefaults.make("selbsttest")
        let model = AppModel(preferences: Preferences(defaults: defaults), http: URLSessionHTTPClient.makeDefault(),
                             secrets: KeychainStore(service: AppInfo.bundleIdentifier + ".selbsttest"))
        do {
            let found = try await model.signIn(server: server, apiKey: apiKey, login: nil, database: nil)
            passed = report(true, "Anmeldung über \(model.interfaceDisplay) als \(found.userName)") && passed
            passed = report(found.timesheets == .available, "Zeiterfassung verfügbar") && passed
            print("  Anwesenheit: \(found.attendance.rawValue), stempeln erlaubt: \(found.canStamp)")
        } catch {
            return report(false, "Anmeldung: \(error.localizedDescription)")
        }
        model.finishSignIn()
        await model.refresh(force: true)
        passed = report(model.notice == nil, "Tag geladen (\(model.entries.count) Einträge, \(model.projects.count) Projekte)") && passed

        if let project = model.projects.first {
            model.selectProject(project)
            await model.loadTasks(projectID: project.id)
            if case .tasks(let tasks) = model.taskChoice { model.draft.taskID = tasks.first?.id }
            let before = model.entries.count
            model.draft.description = "Selbsttest der Mac-App"
            model.draft.durationText = "0:15"
            await model.save()
            passed = report(model.saveError == nil && model.entries.count == before + 1,
                            "Eintrag gebucht und in der Liste (\(model.menuBarContent.text) in der Menüleiste)") && passed
        }

        // Stempeln: ein und wieder aus, oder Odoo lehnt ab und die App blendet den Knopf aus.
        // Ein- und Ausstempeln in derselben Sekunde verwirrt Odoos Prüfung auf Überschneidungen.
        if model.attendanceActive, model.capabilities?.canStamp == true {
            if model.openPeriod != nil {
                await model.toggleAttendance()
                try? await Task.sleep(for: .seconds(1.1))
            }
            await model.toggleAttendance()
            if model.preferences.stampingRefused {
                passed = report(model.capabilities?.canStamp == false && model.attendanceSummary.buttonTitle == nil,
                                "Stempeln von Odoo abgelehnt, Knopf ausgeblendet, Hinweis: \(model.attendanceSummary.note ?? "–")") && passed
            } else {
                let checkedIn = model.openPeriod != nil
                try? await Task.sleep(for: .seconds(1.1))
                await model.toggleAttendance()
                passed = report(checkedIn && model.openPeriod == nil && model.stampError == nil,
                                "Ein- und ausgestempelt") && passed
            }
        }

        model.signOut()
        passed = report(model.preferences.session == nil, "Abgemeldet, Schlüssel gelöscht") && passed
        model.stop()
        return passed
    }
}
#endif
