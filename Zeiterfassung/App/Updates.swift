// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Observation
#if !APP_STORE
import Sparkle
#endif

#if APP_STORE
/// Die Fassung aus dem App Store aktualisiert der App Store selbst. Sie legt kein `Updates` an,
/// die Oberfläche blendet die Update-Suche dann aus; der Typ steht nur für die Übersetzung bereit.
@MainActor
@Observable
final class Updates {
    private(set) var availableVersion: String?
    @ObservationIgnored var willPresent: (() -> Void)?
    var automaticallyChecks = false
    var lastCheck: Date? { nil }

    func checkForUpdates() {}
}
#else
/// Updates über Sparkle: Die App fragt einmal am Tag die Versionsliste auf GitHub ab, weist im Fenster
/// unter der Menüleiste dezent auf eine neue Version hin und installiert sie auf Wunsch.
///
/// Sparkle prüft jede neue Version auf die Signatur des Projekts, bevor es sie installiert.
@MainActor
@Observable
final class Updates: NSObject {
    /// Neue Version, auf die das Fenster unter der Menüleiste hinweist.
    private(set) var availableVersion: String?
    /// Vor dem Fenster von Sparkle: das Fenster unter der Menüleiste schließen, es läge sonst darüber.
    @ObservationIgnored var willPresent: (() -> Void)?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        #if DEBUG
        if Self.isSelfTest, let updater = controller?.updater {
            updater.automaticallyDownloadsUpdates = true
            updater.checkForUpdatesInBackground()
        }
        #endif
    }

    var automaticallyChecks: Bool {
        get {
            access(keyPath: \.automaticallyChecks)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyChecks) {
                controller?.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    /// Sucht sofort und zeigt das Ergebnis im Fenster von Sparkle, auch wenn alles aktuell ist.
    func checkForUpdates() {
        willPresent?()
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    #if DEBUG
    /// Ende-zu-Ende-Test: neue Version still laden und sofort installieren.
    ///
    ///     Zeiterfassung.app/Contents/MacOS/Zeiterfassung -updateSelfTest YES
    static var isSelfTest: Bool { UserDefaults.standard.bool(forKey: "updateSelfTest") }
    #endif
}

extension Updates: SPUUpdaterDelegate {
    #if DEBUG
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        guard Self.isSelfTest else { return false }
        immediateInstallHandler()
        return true
    }
    #endif
}

/// Dezente Hinweise, wie Sparkle sie für Apps ohne Dock-Symbol empfiehlt: Nur direkt nach dem Start
/// zeigt Sparkle sein Fenster selbst, sonst erscheint der Hinweis im Fenster unter der Menüleiste.
extension Updates: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        if handleShowingUpdate {
            willPresent?()
            NSApp.activate()
        } else {
            availableVersion = update.displayVersionString
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        availableVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
    }
}
#endif
