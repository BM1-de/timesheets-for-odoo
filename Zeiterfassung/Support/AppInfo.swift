// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation
import ServiceManagement

enum AppInfo {
    /// „Zeiterfassung für Odoo“, „Timesheets for Odoo“ … aus `InfoPlist.strings` der jeweiligen Sprache.
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Zeiterfassung für Odoo"
    static let sourceURL = URL(string: "https://github.com/BM1-de/timesheets-for-odoo")!
    static let licenseURL = URL(string: "https://www.gnu.org/licenses/agpl-3.0.html")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var bundleIdentifier: String { Bundle.main.bundleIdentifier ?? "de.bm1.ZeiterfassungFuerOdoo" }

    /// Eigene Kennung: Manche Server hinter Cloudflare sperren unbekannte Standardkennungen.
    static var userAgent: String { "ZeiterfassungFuerOdoo/\(version) (macOS)" }

    /// Hinweise nach AGPL-3.0 § 5 d für „Über …“ und die Einstellungen.
    static let legalNotice = String(localized: """
        Copyright © 2026 Baumgärtner Marketing GmbH. Freie Software unter der GNU Affero General Public License, \
        Version 3 oder neuer, ohne jede Gewährleistung. Odoo ist eine Marke der Odoo S.A.; dieses Projekt steht \
        in keiner Verbindung zu Odoo S.A.
        """)

    /// Fremder Code in der App; der vollständige Lizenztext liegt in der App unter Resources.
    /// Die Fassung aus dem App Store enthält Sparkle nicht.
    #if APP_STORE
    static let thirdPartyNotice: String? = nil
    #else
    static let thirdPartyNotice: String? = String(localized: "Updates mit Sparkle, © Sparkle-Projekt und Mitwirkende, MIT-Lizenz.")
    #endif
}

/// Läuft der Prozess als Wirt für Unit-Tests?
enum RuntimeEnvironment {
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}

/// „Beim Anmelden am Mac öffnen“ über die Anmeldeobjekte von macOS.
@MainActor
enum LoginItem {
    #if DEBUG
    /// Für die Bildschirmfotos ein fester Zustand statt der Anmeldeobjekte dieses Mac.
    static var stateForScreenshots: Bool?
    #endif

    static var isEnabled: Bool {
        #if DEBUG
        if let stateForScreenshots { return stateForScreenshots }
        #endif
        return SMAppService.mainApp.status == .enabled
    }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Beim ersten Start aus dem Programme-Ordner ist „Beim Anmelden am Mac öffnen“ eingeschaltet.
    /// Danach entscheidet nur noch der Benutzer, in den Einstellungen der App oder von macOS.
    /// Aus dem App Store bleibt es aus: Dort darf eine App nur mit Zustimmung mit der Anmeldung starten.
    static func applyDefault(_ preferences: Preferences, bundleURL: URL = Bundle.main.bundleURL) {
        #if !APP_STORE
        guard !preferences.loginItemDefaultApplied, isInstalled(bundleURL) else { return }
        preferences.loginItemDefaultApplied = true
        try? setEnabled(true)
        #endif
    }

    /// Nur eine App im Programme-Ordner taugt als Anmeldeobjekt, nicht eine aus dem geöffneten DMG
    /// oder aus einem Build-Ordner.
    nonisolated static func isInstalled(_ bundleURL: URL, home: String = realHomeDirectory) -> Bool {
        let path = bundleURL.standardizedFileURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }

    /// Das echte Benutzerverzeichnis; in der Sandbox liefert `NSHomeDirectory()` den Container der App.
    nonisolated static var realHomeDirectory: String {
        getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    }
}
