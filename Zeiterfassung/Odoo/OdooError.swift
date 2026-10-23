// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Fehler beim Gespräch mit Odoo, mit Texten für die Oberfläche.
enum OdooError: Error, Equatable, Sendable {
    /// Die Adresse lässt sich nicht als Server lesen.
    case invalidServerAddress
    /// Unverschlüsselte Adresse außerhalb des eigenen Rechners.
    case insecureServerAddress
    /// Netzwerk weg, Zeitüberschreitung, Name nicht auflösbar.
    case offline(String)
    /// API-Schlüssel oder Benutzername abgelehnt, Schlüssel abgelaufen.
    case unauthorized
    /// Auf dem Server liegen mehrere Datenbanken, keine ist angegeben.
    case databaseRequired
    /// Der Server kennt JSON-2 nicht (Odoo 17/18); für JSON-RPC fehlt der Benutzername.
    case loginRequired
    /// Modell, Methode oder Schnittstelle fehlt.
    case notFound(String)
    /// Odoo verweigert den Zugriff (fehlende Rechte).
    case accessDenied(String)
    /// Odoo lehnt die Eingabe ab, mit einer Meldung für den Benutzer.
    case rejected(String)
    /// Sonstiger Fehler auf dem Server.
    case server(String)
    /// Antwort ohne erwartetes Format.
    case unexpectedResponse(String)
    /// Der Server leitet auf eine andere Adresse um; die App folgt nicht, damit der API-Schlüssel
    /// nicht an eine fremde Adresse geht.
    case redirected(String)

    /// Ordnet eine Odoo-Ausnahme (`odoo.exceptions.AccessError` …) einem Fall zu.
    static func fromOdoo(name: String, message: String, status: Int?) -> OdooError {
        let shortName = name.split(separator: ".").last.map(String.init) ?? name
        switch shortName {
        case "AccessDenied", "Unauthorized", "SessionExpiredException":
            return .unauthorized
        case "AccessError":
            return .accessDenied(message)
        case "UserError" where isMissingModel(message):
            // JSON-RPC meldet ein fehlendes Modell (App nicht installiert) als UserError.
            return .notFound(message)
        case "UserError", "ValidationError", "MissingError", "RedirectWarning", "LockError", "UnprocessableEntity":
            return .rejected(message)
        case "NotFound", "KeyError":
            return .notFound(message)
        default:
            switch status {
            case 401: return .unauthorized
            case 404: return .notFound(message)
            default: return .server(message.isEmpty ? name : message)
            }
        }
    }

    /// „Object hr.attendance doesn't exist“ (Odoo 19 ohne Übersetzung; ältere Versionen übersetzten
    /// den Satz, deshalb auch deutsch und französisch).
    private static func isMissingModel(_ message: String) -> Bool {
        (message.hasPrefix("Object ") && message.hasSuffix(" doesn't exist"))
            || (message.hasPrefix("Objekt ") && message.hasSuffix(" existiert nicht"))
            || (message.hasPrefix("L'objet ") && message.contains(" n'existe pas"))
    }
}

extension OdooError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidServerAddress:
            return String(localized: "Die Serveradresse ist ungültig.")
        case .insecureServerAddress:
            return String(localized: "Bitte eine Adresse mit https verwenden. Der API-Schlüssel darf nicht unverschlüsselt übertragen werden.")
        case .offline:
            return String(localized: "Keine Verbindung zu Odoo.")
        case .unauthorized:
            return String(localized: "Odoo hat die Anmeldung abgelehnt. Der API-Schlüssel ist ungültig oder abgelaufen.")
        case .databaseRequired:
            return String(localized: "Auf diesem Server liegen mehrere Datenbanken. Bitte den Namen der Datenbank angeben.")
        case .loginRequired:
            return String(localized: "Dieses Odoo bietet die neue Schnittstelle nicht an (Odoo 17/18 oder ohne JSON-2). Bitte zusätzlich den Benutzernamen angeben.")
        case .notFound(let message):
            return message.isEmpty ? String(localized: "Odoo kennt diese Funktion nicht.") : message
        case .accessDenied(let message):
            return message.isEmpty ? String(localized: "Dafür fehlen in Odoo die Rechte.") : message
        case .rejected(let message):
            return message
        case .server(let message):
            return String(localized: "Odoo meldet einen Fehler: \(message)")
        case .unexpectedResponse(let message):
            return String(localized: "Unerwartete Antwort von Odoo. \(message)")
        case .redirected(let location):
            return location.isEmpty
                ? String(localized: "Der Server leitet auf eine andere Adresse um. Bitte die Adresse eintragen, unter der Odoo direkt erreichbar ist.")
                : String(localized: "Der Server leitet nach \(location) um. Bitte diese Adresse als Server eintragen.")
        }
    }
}
