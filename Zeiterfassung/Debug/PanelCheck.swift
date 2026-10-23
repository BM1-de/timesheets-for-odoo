// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

#if DEBUG
import AppKit

/// Öffnet das Fenster unter dem Menüleistensymbol mit erfundenen Daten und prüft, ob es direkt
/// unter dem Symbol hängt und so hoch ist wie sein Inhalt. Nur in Entwicklungs-Builds:
///
///     Zeiterfassung.app/Contents/MacOS/Zeiterfassung -panelCheck YES
///
/// Das Fenster erscheint dabei kurz auf dem Bildschirm.
@MainActor
enum PanelCheck {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "panelCheck") }

    private static var statusBar: StatusBarController?

    static func run() {
        NSApp.setActivationPolicy(.accessory)
        Task {
            let passed = await check()
            print(passed ? "FENSTERPRÜFUNG BESTANDEN" : "FENSTERPRÜFUNG FEHLGESCHLAGEN")
            NSApp.terminate(nil)
        }
    }

    private static func check() async -> Bool {
        let odoo = FakeOdoo()
        let defaults = ScratchDefaults.make("fensterpruefung")
        let model = AppModel(preferences: Preferences(defaults: defaults), http: odoo.client(), secrets: MemorySecretStore())
        await model.start()
        let controller = StatusBarController(model: model, openSettings: {})
        statusBar = controller
        // Beim ersten Start unter einer Kennung rückt die Menüleiste das Symbol erst nach einer Weile zurecht.
        try? await Task.sleep(for: .seconds(1))

        controller.openPanel()
        try? await Task.sleep(for: .seconds(1))
        var passed = report("Anmeldung", controller)

        _ = try? await model.signIn(server: "odoo.example.de", apiKey: odoo.apiKey, login: nil, database: nil)
        model.finishSignIn()
        try? await Task.sleep(for: .seconds(1))
        passed = report("Tag", controller) && passed

        // Kleiner werden, während das Fenster offen ist
        model.setTimesheetsEnabled(false)
        try? await Task.sleep(for: .seconds(1))
        passed = report("Nur Anwesenheit", controller) && passed

        // Schließen und wieder öffnen
        controller.closePanel()
        model.setTimesheetsEnabled(true)
        try? await Task.sleep(for: .milliseconds(300))
        controller.openPanel()
        try? await Task.sleep(for: .seconds(1))
        passed = report("Wieder geöffnet", controller) && passed

        controller.closePanel()
        model.stop()
        return passed
    }

    private static func report(_ title: String, _ controller: StatusBarController) -> Bool {
        guard let geometry = controller.panelGeometry else {
            print("✘ \(title): kein Fenster")
            return false
        }
        let width = PanelMetrics.width
        let expectedX = min(max(geometry.button.midX - width / 2, geometry.visible.minX + 8), geometry.visible.maxX - width - 8)
        let centered = abs(geometry.panel.minX - expectedX.rounded()) < 1
        let attached = abs(geometry.panel.maxY - (geometry.button.minY - PanelMetrics.gapBelowMenuBar)) < 1
        let filled = abs(geometry.content.height - geometry.panel.height) < 1 && geometry.content.minY == 0
        let fits = abs(geometry.panel.height - min(geometry.measured, geometry.visible.height - 16).rounded()) < 1
        let problems = [(centered, "nicht mittig"), (attached, "nicht unter dem Symbol"), (filled, "Inhalt füllt das Fenster nicht"),
                        (fits, "falsche Höhe")].filter { !$0.0 }.map(\.1)
        print("\(problems.isEmpty ? "✔" : "✘") \(title): Symbol \(geometry.button), Fenster \(geometry.panel), "
              + "Inhalt \(geometry.content), gemessen \(geometry.measured)"
              + (problems.isEmpty ? "" : " – " + problems.joined(separator: ", ")))
        return problems.isEmpty
    }
}
#endif
