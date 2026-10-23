// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import Testing
@testable import Zeiterfassung

@MainActor
@Suite("Fenster unter der Menüleiste")
struct PanelLayoutTests {
    @Test("meldet die volle Höhe des Inhalts, auch wenn das Fenster kleiner sein muss")
    func reportsFullHeightWhenClipped() async throws {
        let odoo = FakeOdoo()
        let defaults = ScratchDefaults.make("zeiterfassung-tests")
        let model = AppModel(preferences: Preferences(defaults: defaults), http: odoo.client(), secrets: MemorySecretStore(),
                             calendar: TestClock.calendar, clock: { TestClock.now })
        try await model.signIn(server: "odoo.example.de", apiKey: odoo.apiKey, login: nil, database: nil)
        model.finishSignIn()
        await model.refresh(force: true)

        var reported: CGFloat = 0
        let hosting = NSHostingView(rootView: PanelRootView(onOpenSettings: {}, onHeightChange: { reported = $0 })
            .environment(model))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: PanelMetrics.width, height: 1600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let fullHeight = reported
        #expect(fullHeight > 500)

        // Kleiner Bildschirm: Das Fenster wird niedriger, der Inhalt bleibt gleich hoch und lässt sich scrollen.
        window.setContentSize(NSSize(width: PanelMetrics.width, height: 300))
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        #expect(reported == fullHeight)
        let scrollView = try #require(Self.firstScrollView(in: hosting))
        #expect(scrollView.contentView.bounds.height <= 300)
        #expect((scrollView.documentView?.frame.height ?? 0) >= fullHeight - 1)
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }
}
