// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Security

/// Ablage für den API-Schlüssel. In Tests durch einen Speicher im Arbeitsspeicher ersetzt.
protocol SecretStore: Sendable {
    func read(account: String) -> String?
    func save(_ secret: String, account: String, label: String) throws
    func delete(account: String)
}

/// Der API-Schlüssel liegt im Schlüsselbund von macOS, nie in den Einstellungen.
struct KeychainStore: SecretStore {
    let service: String

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? String(localized: "Fehler \(status)")
            return String(localized: "Der API-Schlüssel konnte nicht im Schlüsselbund gesichert werden (\(detail)).")
        }
    }

    func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ secret: String, account: String, label: String) throws {
        delete(account: account)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: label,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data(secret.utf8),
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
