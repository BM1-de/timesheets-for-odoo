// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

// Nur in Entwicklungs-Builds: Hilfen für Unit-Tests, Bildschirmfotos und Selbsttests.

#if DEBUG
import Foundation

/// Benutzervorgaben zum Ausprobieren, getrennt von denen der App. Reste früherer Läufe, älter als
/// eine Stunde, räumt der erste Aufruf weg, damit sich im Container nichts ansammelt.
enum ScratchDefaults {
    static func make(_ prefix: String) -> UserDefaults {
        _ = removeLeftovers
        return UserDefaults(suiteName: "\(prefix)-\(UUID().uuidString)") ?? .standard
    }

    private static let prefixes = ["zeiterfassung-tests-", "screenshots-", "selbsttest-", "fensterpruefung-"]

    private static let removeLeftovers: Void = {
        let folder = URL.libraryDirectory.appending(path: "Preferences")
        let cutoff = Date().addingTimeInterval(-3600)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where prefixes.contains(where: file.lastPathComponent.hasPrefix) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }()
}

/// API-Schlüssel im Arbeitsspeicher statt im Schlüsselbund.
final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func read(account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    func save(_ secret: String, account: String, label: String) throws {
        lock.lock()
        values[account] = secret
        lock.unlock()
    }

    func delete(account: String) {
        lock.lock()
        values[account] = nil
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.count
    }
}
#endif
