// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Zeiterfassung

@MainActor
@Suite("Beim Anmelden am Mac öffnen")
struct LoginItemTests {
    @Test("gilt nur für eine App im Programme-Ordner", arguments: [
        ("/Applications/Zeiterfassung.app", true),
        ("/Users/erika/Applications/Zeiterfassung.app", true),
        ("/Volumes/Zeiterfassung für Odoo/Zeiterfassung.app", false),
        ("/private/var/folders/ab/T/AppTranslocation/1A2B/d/Zeiterfassung.app", false),
        ("/Users/erika/Library/Developer/Xcode/DerivedData/Build/Products/Debug/Zeiterfassung.app", false),
        ("/Users/erika/Downloads/Zeiterfassung.app", false),
    ])
    func installedLocation(path: String, installed: Bool) {
        #expect(LoginItem.isInstalled(URL(fileURLWithPath: path), home: "/Users/erika") == installed)
    }

    @Test("außerhalb des Programme-Ordners bleibt alles, wie es ist")
    func skipsOutsideApplications() {
        let preferences = Preferences(defaults: ScratchDefaults.make("zeiterfassung-tests"))
        LoginItem.applyDefault(preferences, bundleURL: URL(fileURLWithPath: "/Volumes/Zeiterfassung für Odoo/Zeiterfassung.app"))
        #expect(!preferences.loginItemDefaultApplied)
    }
}
