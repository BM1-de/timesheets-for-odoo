// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

#if DEBUG
import AppKit
import SwiftUI

/// Zeichnet die Ansichten der App mit erfundenen Daten in PNG-Dateien, ohne ein Fenster auf dem
/// Bildschirm zu zeigen. Nur in Entwicklungs-Builds:
///
///     open Zeiterfassung.app --args -renderScreenshots YES
///
/// Die Bilder liegen danach im Container der App unter `tmp/screenshots`.
@MainActor
enum ScreenshotRenderer {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "renderScreenshots") }

    static func run() {
        Task {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "screenshots")
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            await renderAll(to: directory)
            print("Bildschirmfotos: \(directory.path)")
            NSApp.terminate(nil)
        }
    }

    // MARK: - Szenen

    private static func renderAll(to directory: URL) async {
        let demo = makeDemoOdoo()
        let model = makeModel(demo)
        _ = try? await model.signIn(server: "odoo.example.de", apiKey: demo.apiKey, login: nil, database: nil)
        model.finishSignIn()
        await model.refresh(force: true)
        model.stop()

        for (name, appearance) in [("hell", NSAppearance.Name.aqua), ("dunkel", .darkAqua)] {
            await renderPanel(model, appearance: appearance, to: directory.appending(path: "fenster-\(name).png"))
        }

        // Neuer Eintrag ausgefüllt, mit Rundung auf 15 Minuten
        model.preferences.durationRounding = .quarterHour
        if let project = model.projects.first(where: { $0.id == 5 }) {
            model.selectProject(project)
            await model.loadTasks(projectID: project.id)
            model.draft.taskID = 52
            model.draft.description = "Startseite: Varianten für den Kopfbereich"
            model.draft.durationText = "1:20"
        }
        await renderPanel(model, appearance: .aqua, to: directory.appending(path: "eintrag.png"))

        // Sichern ohne Netz
        demo.withLock { demo.offline = true }
        await model.save()
        await renderPanel(model, appearance: .aqua, to: directory.appending(path: "fehler.png"))
        demo.withLock { demo.offline = false }
        model.draft = AppModel.Draft()

        // Projektsuche
        let picker = ProjectPicker(projects: model.projects, recentIDs: model.recentProjectIDs, selectedID: nil,
                                   isLoading: false) { _ in }
            .background(Color(nsColor: .windowBackgroundColor))
        await render(picker, appearance: .aqua, to: directory.appending(path: "projektsuche.png"))

        await renderEditing(model, to: directory)
        await renderTimer(model, demo: demo, to: directory)

        // Nur Anwesenheit
        model.setTimesheetsEnabled(false)
        await model.refresh(force: true)
        await renderPanel(model, appearance: .aqua, to: directory.appending(path: "nur-anwesenheit.png"))
        model.setTimesheetsEnabled(true)
        await model.refresh(force: true)

        // Einstellungen; „Beim Anmelden am Mac öffnen“ wie im Standard eingeschaltet
        LoginItem.stateForScreenshots = true
        await render(SettingsView().environment(model), appearance: .aqua,
                     to: directory.appending(path: "einstellungen.png"))
        model.preferences.menuBarTime = .attendanceToday
        await render(SettingsView().environment(model), appearance: .darkAqua,
                     to: directory.appending(path: "einstellungen-anwesenheit-dunkel.png"))
        model.preferences.menuBarTime = .automatic

        // Einstellungen ohne Odoo-App Anwesenheiten
        let limited = makeDemoOdoo()
        limited.attendanceInstalled = false
        let limitedModel = makeModel(limited)
        _ = try? await limitedModel.signIn(server: "odoo.example.de", apiKey: limited.apiKey, login: nil, database: nil)
        limitedModel.finishSignIn()
        limitedModel.stop()
        await render(SettingsView().environment(limitedModel), appearance: .aqua,
                     to: directory.appending(path: "einstellungen-ohne-anwesenheit.png"))

        // Anmeldung
        let fresh = makeModel(makeDemoOdoo())
        await fresh.start()
        fresh.stop()
        await renderPanel(fresh, appearance: .aqua, to: directory.appending(path: "anmeldung.png"))

        await renderBreakModule(to: directory)
        await renderReadOnly(to: directory)
        await renderCompanies(to: directory)
    }

    /// Einträge bearbeiten und löschen, Anwesenheiten korrigieren.
    private static func renderEditing(_ model: AppModel, to directory: URL) async {
        if let entry = model.entries.first(where: { $0.id == 6 }) {
            model.beginEditing(entry)
            await model.loadTasks(projectID: 3)
            await renderPanel(model, appearance: .aqua, to: directory.appending(path: "bearbeiten.png"))
            model.askToDelete(.entry(entry))
            await renderPanel(model, appearance: .aqua, to: directory.appending(path: "loeschen.png"))
            await renderPanel(model, appearance: .darkAqua, to: directory.appending(path: "loeschen-dunkel.png"))
            model.cancelDeletion()
            model.cancelEditing()
        }

        // Mittwoch: ein abgerechneter Eintrag, Odoo hat automatisch ausgestempelt
        model.showPreviousDay()
        model.showPreviousDay()
        await model.refresh(force: true)
        if let entry = model.entries.first(where: { $0.id == 1 }) {
            model.beginEditing(entry)
            await renderPanel(model, appearance: .aqua, to: directory.appending(path: "abgerechnet.png"))
            model.cancelEditing()
        }
        await renderPanel(model, appearance: .aqua, to: directory.appending(path: "ausgestempelt.png"))
        if let period = model.periods.last {
            model.editPeriod(period)
            await renderPanel(model, appearance: .aqua, to: directory.appending(path: "ausgestempelt-korrigieren.png"))
            model.cancelAttendanceEditing()
        }
        model.showToday()
        await model.refresh(force: true)

        model.setAttendanceListExpanded(true)
        await renderPanel(model, appearance: .aqua, to: directory.appending(path: "zeiten-des-tages.png"))
        if let period = model.todayPeriods.first {
            model.editPeriod(period)
            model.attendanceEditor?.from = "8:00"
            await renderPanel(model, appearance: .aqua, to: directory.appending(path: "zeitraum-korrigieren.png"))
            await renderPanel(model, appearance: .darkAqua, to: directory.appending(path: "zeitraum-korrigieren-dunkel.png"))
            model.cancelAttendanceEditing()
        }
        model.setAttendanceListExpanded(false)
    }

    /// Projekt-Timer: läuft seit 14:10, wechseln, verwerfen, gebucht, ohne Netz nicht gebucht.
    private static func renderTimer(_ model: AppModel, demo: FakeOdoo, to directory: URL) async {
        guard let account = model.session?.keychainAccount else { return }
        let timer = Preferences.RunningTimer(account: account, projectID: 5, projectName: "Website-Relaunch (Musterhaus GmbH)",
                                             taskID: 52, taskName: "Design",
                                             description: "Startseite: Varianten für den Kopfbereich",
                                             start: now.addingTimeInterval(-42 * 60))
        model.preferences.runningTimer = timer
        await renderPanel(model, appearance: .aqua, to: directory.appending(path: "timer-laeuft.png"))
        await renderPanel(model, appearance: .darkAqua, to: directory.appending(path: "timer-laeuft-dunkel.png"))

        if let project = model.projects.first(where: { $0.id == 3 }) {
            model.selectProject(project)
            await model.loadTasks(projectID: 3)
            model.draft.taskID = 32
            model.draft.description = "Titelseite"
            await renderPanel(model, appearance: .aqua, to: directory.appending(path: "timer-wechseln.png"))
            model.draft = AppModel.Draft()
        }

        model.requestDiscardTimer()
        await renderPanel(model, appearance: .aqua, to: directory.appending(path: "timer-verwerfen.png"))
        model.cancelDeletion()

        let rounding = model.preferences.durationRounding
        model.preferences.durationRounding = .quarterHour
        await model.stopTimer()
        await renderPanel(model, appearance: .aqua, to: directory.appending(path: "timer-gebucht.png"))
        model.preferences.durationRounding = rounding

        model.preferences.runningTimer = timer
        demo.withLock { demo.offline = true }
        await model.stopTimer()
        demo.withLock { demo.offline = false }
        await renderPanel(model, appearance: .aqua, to: directory.appending(path: "timer-nicht-gebucht.png"))
        model.preferences.runningTimer = nil
        model.dismissTimerNotice()

        // Oben gestartet, ohne Projekt: Angaben ändern, beim Stoppen zuordnen
        await renderPanel(model, appearance: .aqua, to: directory.appending(path: "timer-starten.png"))
        model.preferences.runningTimer = Preferences.RunningTimer(account: account, projectID: nil, projectName: nil, taskID: nil,
                                                                  taskName: nil, description: "",
                                                                  start: now.addingTimeInterval(-42 * 60))
        await renderPanel(model, appearance: .aqua, to: directory.appending(path: "timer-ohne-projekt.png"))
        model.beginEditingTimer()
        await renderPanel(model, appearance: .aqua, to: directory.appending(path: "timer-aendern.png"))
        model.cancelEditing()
        await model.stopTimer()
        await renderPanel(model, appearance: .aqua, to: directory.appending(path: "timer-zuordnen.png"))
        model.cancelEditing()
        await renderPanel(model, appearance: .aqua, to: directory.appending(path: "timer-projekt-fehlt.png"))

        // Nach 20 Sekunden gestoppt: Die Zeit kommt ins Formular und bleibt stehen, bis sie gebucht oder verworfen ist.
        model.preferences.runningTimer = Preferences.RunningTimer(account: account, projectID: 5,
                                                                  projectName: "Website-Relaunch (Musterhaus GmbH)",
                                                                  taskID: 52, taskName: "Design", description: "Logo prüfen",
                                                                  start: now.addingTimeInterval(-20))
        await model.stopTimer()
        await renderPanel(model, appearance: .aqua, to: directory.appending(path: "timer-kurz-formular.png"))
        model.cancelEditing()
        await renderPanel(model, appearance: .aqua, to: directory.appending(path: "timer-kurz.png"))
        model.preferences.runningTimer = nil
        model.dismissTimerNotice()
        await model.refresh(force: true)
    }

    /// Modul Arbeitszeitgesetz: Am Donnerstag hat Odoo eine Pause eingefügt.
    private static func renderBreakModule(to directory: URL) async {
        let demo = makeDemoOdoo()
        demo.withLock {
            demo.breakModule = true
            // 07:45–12:00 und, von Odoo angelegt, 12:30–17:00 Ortszeit
            demo.attendances += [
                .init(id: 11, checkIn: "2026-10-22 05:45:00", checkOut: "2026-10-22 10:00:00", inMode: "manual", outMode: "manual"),
                .init(id: 12, checkIn: "2026-10-22 10:30:00", checkOut: "2026-10-22 15:00:00", inMode: "technical", outMode: "manual"),
            ]
        }
        let model = makeModel(demo)
        _ = try? await model.signIn(server: "odoo.example.de", apiKey: demo.apiKey, login: nil, database: nil)
        model.finishSignIn()
        model.stop()
        model.showPreviousDay()
        await model.refresh(force: true)
        await renderPanel(model, appearance: .aqua, to: directory.appending(path: "pause-eingefuegt.png"))
        if let row = model.attendanceSummary.rows.first(where: \.isInsertedBreak), case .gap(let before, let after) = row.kind {
            model.editGap(before: before, after: after)
            model.attendanceEditor?.from = "13:00"
            model.attendanceEditor?.to = "13:15"
            await renderPanel(model, appearance: .aqua, to: directory.appending(path: "pause-verschieben.png"))
        }
    }

    /// Ohne das Recht, Anwesenheiten zu ändern.
    private static func renderReadOnly(to directory: URL) async {
        let demo = makeDemoOdoo()
        demo.withLock { demo.canStamp = false }
        let model = makeModel(demo)
        _ = try? await model.signIn(server: "odoo.example.de", apiKey: demo.apiKey, login: nil, database: nil)
        model.finishSignIn()
        model.stop()
        await model.refresh(force: true)
        model.setAttendanceListExpanded(true)
        await renderPanel(model, appearance: .aqua, to: directory.appending(path: "nur-lesen.png"))
    }

    /// Zwei Firmen in einer Datenbank, mit je einem Mitarbeiter.
    private static func renderCompanies(to directory: URL) async {
        let demo = makeDemoOdoo()
        demo.withLock {
            demo.companies = [(1, "Nordlicht Werbeagentur GmbH"), (2, "Nordlicht Fotostudio")]
            demo.otherEmployees = [(id: 4, companyID: 2)]
            demo.projects += [(9, "Porträts (Beispiel AG)"), (10, "Produktfotos (Demo KG)"), (11, "Fortbildung")]
            demo.tasks[9] = [(91, "Shooting"), (92, "Bildbearbeitung")]
            demo.tasks[10] = [(101, "Shooting"), (102, "Freisteller")]
            demo.tasks[11] = [(111, "Kurs"), (112, "Selbststudium")]
            for id in 1...8 { demo.projectCompanies[id] = 1 }
            demo.projectCompanies[9] = 2
            demo.projectCompanies[10] = 2
            demo.lines.append(.init(id: 7, date: "2026-10-23", name: "Auswahl für die Website", projectID: 9, taskID: 92,
                                    hours: 1, companyID: 2, employeeID: 4))
        }
        let model = makeModel(demo)
        _ = try? await model.signIn(server: "odoo.example.de", apiKey: demo.apiKey, login: nil, database: nil)
        model.finishSignIn()
        model.stop()
        await model.refresh(force: true)
        await renderPanel(model, appearance: .aqua, to: directory.appending(path: "firmen.png"))
        let picker = ProjectPicker(projects: model.projects, recentIDs: model.recentProjectIDs, selectedID: 9,
                                   isLoading: false, companyName: { model.companyName(of: $0) },
                                   companyOrder: model.organization?.companies.map(\.id) ?? []) { _ in }
            .background(Color(nsColor: .windowBackgroundColor))
        await render(picker, appearance: .aqua, to: directory.appending(path: "firmen-projektsuche.png"))
        if let entry = model.entries.first(where: { $0.id == 7 }) {
            model.beginEditing(entry)
            await model.loadTasks(projectID: 9)
            await renderPanel(model, appearance: .aqua, to: directory.appending(path: "firmen-eintrag.png"))
            model.cancelEditing()
        }
        await render(SettingsView().environment(model), appearance: .aqua,
                     to: directory.appending(path: "firmen-einstellungen.png"))
    }

    // MARK: - Daten

    /// Freitag, 23. Oktober 2026, 14:52 in Berlin – passend zum Entwurf.
    nonisolated static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        return calendar
    }()

    nonisolated static let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 14, minute: 52)) ?? Date()

    static func makeModel(_ demo: FakeOdoo) -> AppModel {
        let defaults = ScratchDefaults.make("screenshots")
        return AppModel(preferences: Preferences(defaults: defaults), http: demo.client(), secrets: MemorySecretStore(),
                        calendar: calendar, clock: { now })
    }

    /// Erfundene Projekte, Aufgaben, Einträge und Anwesenheiten.
    private static func makeDemoOdoo() -> FakeOdoo {
        let demo = FakeOdoo(mode: .odoo19)
        demo.withLock {
            demo.projects = [
                (1, "Interne Arbeiten"),
                (2, "Website-Betreuung (Muster GmbH)"),
                (3, "Kundenmagazin (Beispiel AG)"),
                (4, "Online-Shop (Demo KG)"),
                (5, "Website-Relaunch (Musterhaus GmbH)"),
                (6, "Social Media (Café Beispiel)"),
                (7, "Geschäftsbericht (Stadtwerke Musterstadt)"),
                (8, "Messestand (Muster & Partner)"),
            ]
            demo.tasks = [
                1: [(11, "Verwaltung"), (12, "Weiterbildung"), (13, "Akquise")],
                2: [(21, "Wartung"), (22, "Umsetzung")],
                3: [(31, "Text"), (32, "Layout"), (33, "Korrektur")],
                4: [(41, "Umsetzung")],
                5: [(51, "Konzept"), (52, "Design"), (53, "Entwicklung")],
                6: [(61, "Redaktion"), (62, "Bildbearbeitung")],
                7: [(71, "Satz"), (72, "Lektorat")],
                8: [(81, "Entwurf"), (82, "Druckdaten")],
            ]
            demo.lines = [
                .init(id: 1, date: "2026-10-21", name: "Beiträge für November", projectID: 6, taskID: 61, hours: 2.5,
                      invoiced: true),
                .init(id: 2, date: "2026-10-22", name: "#1042 Kontaktformular angepasst", projectID: 2, taskID: 22, hours: 1.5),
                .init(id: 3, date: "2026-10-22", name: "Seitenstruktur abgestimmt", projectID: 5, taskID: 51, hours: 4),
                .init(id: 4, date: "2026-10-23", name: "Plugin-Updates", projectID: 2, taskID: 21, hours: 0.25),
                .init(id: 5, date: "2026-10-23", name: "Angebot vorbereitet", projectID: 1, taskID: 11, hours: 2),
                .init(id: 6, date: "2026-10-23", name: "Korrekturen eingearbeitet", projectID: 3, taskID: 31, hours: 3),
            ]
            // 08:12–12:05 und seit 12:47 Ortszeit (UTC zwei Stunden früher); am Mittwoch hat Odoo
            // um 18:45 automatisch ausgestempelt.
            demo.attendances = [
                .init(id: 1, checkIn: "2026-10-23 06:12:00", checkOut: "2026-10-23 10:05:00"),
                .init(id: 2, checkIn: "2026-10-23 10:47:00", checkOut: nil),
                .init(id: 3, checkIn: "2026-10-21 06:00:00", checkOut: "2026-10-21 10:30:00", inMode: "manual", outMode: "manual"),
                .init(id: 4, checkIn: "2026-10-21 11:15:00", checkOut: "2026-10-21 16:45:00", inMode: "manual",
                      outMode: "auto_check_out"),
            ]
        }
        return demo
    }

    // MARK: - Zeichnen

    private final class Measurement {
        var height: CGFloat = 0
    }

    /// Das Fenster unter der Menüleiste, mit deckendem statt durchscheinendem Hintergrund. Es wird so
    /// hoch wie sein gemessener Inhalt, wie im laufenden Programm.
    static func renderPanel(_ model: AppModel, appearance: NSAppearance.Name, to file: URL) async {
        let measurement = Measurement()
        let view = PanelRootView(onOpenSettings: {}, onHeightChange: { measurement.height = $0 })
            .environment(model)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
            }
        await render(view, appearance: appearance, to: file) {
            measurement.height > 0 ? NSSize(width: PanelMetrics.width, height: measurement.height.rounded(.up)) : nil
        }
    }

    /// Beim Zeichnen außerhalb des Bildschirms erscheinen einfache Platzhalter schwarz statt grau.
    /// Für die Bilder bekommen sie deshalb ausdrücklich die Platzhalterfarbe, wie im laufenden Programm.
    private static func tintPlaceholders(in view: NSView) {
        for subview in view.subviews {
            if let field = subview as? NSTextField, let text = field.placeholderString, field.placeholderAttributedString == nil {
                field.placeholderAttributedString = NSAttributedString(string: text, attributes: [
                    .foregroundColor: NSColor.placeholderTextColor,
                    .font: field.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                ])
            }
            tintPlaceholders(in: subview)
        }
    }

    /// - Parameter size: Größe des Bildes; ohne Angabe so groß, wie die Ansicht sein möchte.
    static func render(_ view: some View, appearance: NSAppearance.Name, to file: URL,
                               size: () -> NSSize? = { nil }) async {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 600, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(150))
        window.setContentSize(size() ?? hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(350))
        tintPlaceholders(in: hosting)
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: file)
        window.close()
    }
}
#endif
