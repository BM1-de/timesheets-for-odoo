// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

/// Das Fenster „Einstellungen“. Wie bei Einstellungsfenstern üblich nur mit Schließen-Knopf.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let updates: Updates
    private var window: NSWindow?

    init(model: AppModel, updates: Updates) {
        self.model = model
        self.updates = updates
    }

    func show() {
        let window = self.window ?? makeWindow()
        NSApp.activate()
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let controller = NSHostingController(rootView: SettingsView().environment(model).environment(updates))
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.title = String(localized: "Einstellungen")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Ohne weiteres Fenster den Fokus an die vorige App zurückgeben.
        Task { @MainActor in
            if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                NSApp.deactivate()
            }
        }
    }
}
