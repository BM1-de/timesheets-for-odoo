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

        // Neuer Eintrag ausgefüllt
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
                .init(id: 1, date: "2026-10-21", name: "Beiträge für November", projectID: 6, taskID: 61, hours: 2.5),
                .init(id: 2, date: "2026-10-22", name: "#1042 Kontaktformular angepasst", projectID: 2, taskID: 22, hours: 1.5),
                .init(id: 3, date: "2026-10-22", name: "Seitenstruktur abgestimmt", projectID: 5, taskID: 51, hours: 4),
                .init(id: 4, date: "2026-10-23", name: "Plugin-Updates", projectID: 2, taskID: 21, hours: 0.25),
                .init(id: 5, date: "2026-10-23", name: "Angebot vorbereitet", projectID: 1, taskID: 11, hours: 2),
                .init(id: 6, date: "2026-10-23", name: "Korrekturen eingearbeitet", projectID: 3, taskID: 31, hours: 3),
            ]
            // 08:12–12:05 und seit 12:47 Ortszeit (UTC zwei Stunden früher)
            demo.attendances = [
                .init(id: 1, checkIn: "2026-10-23 06:12:00", checkOut: "2026-10-23 10:05:00"),
                .init(id: 2, checkIn: "2026-10-23 10:47:00", checkOut: nil),
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
