// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var updates: Updates?
    private var statusBar: StatusBarController?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit-Tests laufen im Prozess der App; dann keine Oberfläche aufbauen.
        guard !RuntimeEnvironment.isRunningTests else { return }
        #if DEBUG
        if ScreenshotRenderer.isRequested {
            ScreenshotRenderer.run()
            return
        }
        if AppStoreScreenshots.isRequested {
            AppStoreScreenshots.run()
            return
        }
        if SelfCheck.isRequested {
            SelfCheck.run()
            return
        }
        if PanelCheck.isRequested {
            PanelCheck.run()
            return
        }
        #endif

        #if DEBUG
        // Für Tests mit Bedienungshilfen und Bildschirmfotos auch mit Dock-Symbol:
        // open Zeiterfassung.app --args -regularActivation YES
        NSApp.setActivationPolicy(UserDefaults.standard.bool(forKey: "regularActivation") ? .regular : .accessory)
        #else
        NSApp.setActivationPolicy(.accessory)
        #endif
        NSApp.mainMenu = MainMenu.make(delegate: self)

        let model = AppModel(preferences: Preferences(), http: DemoRoutingHTTPClient(network: URLSessionHTTPClient.makeDefault()),
                             secrets: KeychainStore(service: AppInfo.bundleIdentifier))
        LoginItem.applyDefault(model.preferences)
        let updates = Self.makeUpdates()
        let settingsWindow = SettingsWindowController(model: model, updates: updates)
        let statusBar = StatusBarController(model: model, updates: updates) { [weak settingsWindow] in settingsWindow?.show() }
        updates?.willPresent = { [weak statusBar] in statusBar?.closePanel(deactivating: false) }
        self.model = model
        self.updates = updates
        self.settingsWindow = settingsWindow
        self.statusBar = statusBar
        Task { await model.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Die Fassung aus dem App Store aktualisiert der App Store; eine eigene Update-Suche erlaubt Apple dort nicht.
    private static func makeUpdates() -> Updates? {
        #if APP_STORE
        nil
        #else
        Updates()
        #endif
    }

    @objc func showSettings(_ sender: Any?) {
        statusBar?.closePanel(deactivating: false)
        settingsWindow?.show()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updates?.checkForUpdates()
    }

    @objc func showAbout(_ sender: Any?) {
        statusBar?.closePanel(deactivating: false)
        NSApp.activate()
        let credits = NSMutableAttributedString(
            string: AppInfo.legalNotice + "\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]
        )
        credits.append(NSAttributedString(
            string: String(localized: "Quellcode und Lizenz"),
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .link: AppInfo.sourceURL]
        ))
        if let notice = AppInfo.thirdPartyNotice {
            credits.append(NSAttributedString(
                string: "\n" + notice,
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]
            ))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppInfo.name,
            .credits: credits,
        ])
    }
}
