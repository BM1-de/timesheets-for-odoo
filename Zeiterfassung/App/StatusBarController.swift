// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Observation
import SwiftUI

/// Symbol in der Menüleiste und das Fenster direkt darunter.
///
/// Statt `MenuBarExtra` steuert die App Symbol und Fenster selbst: Nur so öffnet ein Linksklick das
/// Fenster und ein Rechtsklick die üblichen Befehle.
@MainActor
final class StatusBarController: NSObject {
    private let model: AppModel
    private let updates: Updates?
    private let openSettings: () -> Void
    private let statusItem: NSStatusItem
    private var panel: StatusPanel?
    private var contentHeight: CGFloat = 480
    private var resignObserver: (any NSObjectProtocol)?
    private var symbolObservers: [any NSObjectProtocol] = []
    private var keyMonitor: Any?

    init(model: AppModel, updates: Updates? = nil, openSettings: @escaping () -> Void) {
        self.model = model
        self.updates = updates
        self.openSettings = openSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        observeModel()
    }

    // MARK: - Symbol

    private func observeModel() {
        withObservationTracking {
            updateStatusItem()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeModel() }
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let content = model.menuBarContent
        button.image = MenuBarIcon.image(content.symbol, isSignedIn: content.isSignedIn)
        button.title = content.text.isEmpty ? "" : " " + content.text
        button.setAccessibilityLabel(content.accessibilityLabel)
        button.toolTip = content.isSignedIn ? content.toolTip : String(localized: "\(AppInfo.name): bitte anmelden")
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    /// Rechtsklick: die üblichen Befehle eines Menüleistensymbols.
    private func showContextMenu() {
        closePanel()
        let menu = NSMenu()
        let refresh = NSMenuItem(title: String(localized: "Aktualisieren"), action: #selector(refreshFromMenu), keyEquivalent: "")
        refresh.target = self
        refresh.isEnabled = model.session != nil
        menu.addItem(refresh)
        let settings = NSMenuItem(title: String(localized: "Einstellungen …"), action: #selector(settingsFromMenu), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        if updates != nil {
            let check = NSMenuItem(title: String(localized: "Nach Updates suchen …"), action: #selector(checkForUpdatesFromMenu), keyEquivalent: "")
            check.target = self
            menu.addItem(check)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "\(AppInfo.name) beenden"), action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshFromMenu() {
        Task { await model.refresh(force: true) }
    }

    @objc private func settingsFromMenu() {
        openSettings()
    }

    @objc private func checkForUpdatesFromMenu() {
        updates?.checkForUpdates()
    }

    // MARK: - Fenster

    func togglePanel() {
        if panel?.isVisible == true {
            closePanel()
        } else {
            openPanel()
        }
    }

    func openPanel() {
        let panel = self.panel ?? makePanel()
        NSApp.activate()
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            let handled = MainActor.assumeIsolated { self?.handleEscape(from: event) ?? false }
            return handled ? nil : event
        }
        // Wird das Symbol breiter oder rückt die Menüleiste es zur Seite, wandert das Fenster mit.
        if let buttonWindow = statusItem.button?.window {
            symbolObservers = [NSWindow.didMoveNotification, NSWindow.didResizeNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: buttonWindow, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let panel = self.panel, panel.isVisible else { return }
                        self.position(panel)
                    }
                }
            }
        }
        Task { await model.panelDidOpen() }
    }

    /// Esc schließt das Fenster; in der Anmeldung wirkt es wie „Abbrechen“, solange es zurück geht.
    /// Offene Menüs und die Projektsuche liegen in eigenen Fenstern und schließen sich vorher selbst.
    private func handleEscape(from event: NSEvent) -> Bool {
        guard let panel, event.window === panel else { return false }
        if model.screen == .login, model.canCancelSignIn {
            model.cancelSignIn()
        } else {
            closePanel()
        }
        return true
    }

    /// - Parameter deactivating: Fokus an die vorige App zurückgeben; nicht, wenn gleich ein
    ///   anderes Fenster der App erscheint (Einstellungen).
    func closePanel(deactivating: Bool = true) {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        symbolObservers.forEach(NotificationCenter.default.removeObserver)
        symbolObservers = []
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        model.panelDidClose()
        // Ohne weiteres Fenster den Fokus an die vorige App zurückgeben.
        if deactivating, !NSApp.windows.contains(where: { $0.isVisible && $0 !== panel && $0.canBecomeMain }) {
            NSApp.deactivate()
        }
    }

    private func makePanel() -> StatusPanel {
        let root = PanelRootView(
            onOpenSettings: { [weak self] in
                self?.closePanel(deactivating: false)
                self?.openSettings()
            },
            onHeightChange: { [weak self] height in
                self?.contentHeightChanged(height)
            }
        )
        .environment(model)
        .environment(updates)
        let hostingView = NSHostingView(rootView: root)
        hostingView.sizingOptions = []
        let panel = StatusPanel(content: hostingView)
        self.panel = panel
        return panel
    }

    private func contentHeightChanged(_ height: CGFloat) {
        guard height > 0, abs(height - contentHeight) > 0.5 else { return }
        contentHeight = height
        // Erst nach dem laufenden Layout: Ändert sich die Fenstergröße mittendrin, verkleinert AppKit
        // den Inhalt doppelt, und oben im Fenster bleibt ein leerer Streifen.
        Task { @MainActor [weak self] in
            guard let self, let panel = self.panel else { return }
            self.position(panel)
        }
    }

    #if DEBUG
    struct PanelGeometry {
        let button: NSRect
        let panel: NSRect
        let content: NSRect
        let visible: NSRect
        let measured: CGFloat
    }

    /// Lage von Symbol, Fenster und Inhalt, für die Fensterprüfung (`-panelCheck YES`).
    var panelGeometry: PanelGeometry? {
        guard let panel, let content = panel.contentView, let button = statusItem.button,
              let buttonWindow = button.window else { return nil }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        return PanelGeometry(button: buttonFrame, panel: panel.frame, content: content.frame, visible: visible,
                             measured: contentHeight)
    }
    #endif

    /// Unter das Symbol, waagerecht mittig, innerhalb des Bildschirms.
    private func position(_ panel: NSPanel) {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? buttonFrame
        let width = PanelMetrics.width
        let height = min(contentHeight, visible.height - 16).rounded()
        let x = min(max(buttonFrame.midX - width / 2, visible.minX + 8), visible.maxX - width - 8).rounded()
        let top = buttonFrame.minY - PanelMetrics.gapBelowMenuBar
        panel.setFrame(NSRect(x: x, y: top - height, width: width, height: height), display: true)
        panel.invalidateShadow()
    }
}

/// Randloses Fenster mit dem Material eines Popovers und runden Ecken.
final class StatusPanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: 480),
                   styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: PanelMetrics.cornerRadius)

        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        contentView = background
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

enum PanelMetrics {
    static let width: CGFloat = 372
    static let cornerRadius: CGFloat = 12
    static let gapBelowMenuBar: CGFloat = 5
}

/// Uhr, Stoppuhr oder Person als Vorlagenbild, das sich wie jedes Menüleistensymbol an hell und dunkel anpasst.
enum MenuBarIcon {
    @MainActor
    static func image(_ symbol: AppModel.MenuBarContent.Symbol = .clock, isSignedIn: Bool) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let symbolName = switch symbol {
        case _ where !isSignedIn: "clock.badge.questionmark"
        case .clock: "clock"
        case .stopwatch: "stopwatch"
        case .person: "person"
        }
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: AppInfo.name)?
            .withSymbolConfiguration(configuration)
        symbol?.isTemplate = true
        return symbol
    }
}
