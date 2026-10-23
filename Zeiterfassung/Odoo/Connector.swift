// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Gespeicherte Verbindung zu Odoo, ohne den API-Schlüssel (der liegt im Schlüsselbund).
struct OdooSession: Codable, Sendable, Equatable {
    enum Interface: String, Codable, Sendable {
        /// JSON-2, ab Odoo 19.
        case json2
        /// JSON-RPC, Odoo 17 und 18 sowie Odoo Online ohne JSON-2.
        case jsonRPC
    }

    var serverURL: URL
    var database: String?
    var login: String?
    var interface: Interface
    var uid: Int
    var language: String?
    var serverMajorVersion: Int?

    /// Konto, unter dem der API-Schlüssel im Schlüsselbund liegt.
    var keychainAccount: String { "\(serverURL.absoluteString)|\(database ?? "")|\(uid)" }

    func makeTransport(apiKey: String, http: any HTTPClient) -> any OdooTransport {
        switch interface {
        case .json2:
            return JSON2Transport(baseURL: serverURL, apiKey: apiKey, database: database, http: http)
        case .jsonRPC:
            return JSONRPCTransport(baseURL: serverURL, database: database ?? "", uid: uid, apiKey: apiKey, http: http)
        }
    }
}

/// Stellt die Verbindung her: erst JSON-2, sonst JSON-RPC.
struct Connector {
    let http: any HTTPClient

    func connect(serverURL: URL, apiKey: String, login: String?, database: String?) async throws -> OdooSession {
        let database = database.flatMap { $0.trimmed.isEmpty ? nil : $0.trimmed }

        // 1. JSON-2 (Odoo 19 und neuer): Der API-Schlüssel genügt.
        let json2 = JSON2Transport(baseURL: serverURL, apiKey: apiKey, database: database, http: http)
        do {
            let context = try await json2.execute(OdooCall(model: "res.users", method: "context_get"), context: [:])
            guard let uid = context["uid"]?.intValue else {
                throw OdooError.unexpectedResponse(String(localized: "Odoo hat keine Benutzer-ID geliefert."))
            }
            return OdooSession(serverURL: serverURL, database: database, login: nil, interface: .json2, uid: uid,
                               language: context["lang"]?.stringValue,
                               serverMajorVersion: await json2MajorVersion(serverURL: serverURL) ?? 19)
        } catch OdooError.unauthorized {
            throw OdooError.unauthorized
        } catch let error as OdooError where error.meansNoJSON2 {
            // Odoo 19 mit mehreren Datenbanken findet ohne Datenbankangabe keine JSON-2-Schnittstelle.
            // Odoo Online ausgenommen: Dort fehlt JSON-2 ohne Custom-Tarif, weiter mit JSON-RPC.
            let isOdooOnline = serverURL.host()?.hasSuffix(".odoo.com") ?? false
            if database == nil, !isOdooOnline, let major = await json2MajorVersion(serverURL: serverURL), major >= 19 {
                throw OdooError.databaseRequired
            }
        }

        // 2. JSON-RPC (Odoo 17 und 18, Odoo Online ohne JSON-2): braucht Benutzername und Datenbank.
        guard let login = login?.trimmed, !login.isEmpty else { throw OdooError.loginRequired }
        let resolvedDatabase = try await resolveDatabase(serverURL: serverURL, given: database)
        let uidValue = try await JSONRPCTransport.call(
            baseURL: serverURL, http: http, service: "common", method: "authenticate",
            arguments: [.string(resolvedDatabase), .string(login), .string(apiKey), .object([:])]
        )
        guard let uid = uidValue.intValue, uid > 0 else { throw OdooError.unauthorized }

        let transport = JSONRPCTransport(baseURL: serverURL, database: resolvedDatabase, uid: uid, apiKey: apiKey, http: http)
        let context = try await transport.execute(OdooCall(model: "res.users", method: "context_get"), context: [:])
        let version = try? await JSONRPCTransport.call(baseURL: serverURL, http: http, service: "common",
                                                       method: "version", arguments: [])
        return OdooSession(serverURL: serverURL, database: resolvedDatabase, login: login, interface: .jsonRPC, uid: uid,
                           language: context["lang"]?.stringValue,
                           serverMajorVersion: version?["server_version_info"]?.arrayValue?.first?.intValue)
    }

    /// Datenbank für JSON-RPC: angegeben, einzige auf dem Server, oder bei Odoo Online die Subdomain.
    private func resolveDatabase(serverURL: URL, given: String?) async throws -> String {
        if let given { return given }
        if let list = try? await JSONRPCTransport.call(baseURL: serverURL, http: http, service: "db", method: "list", arguments: []),
           let names = list.arrayValue?.compactMap(\.stringValue), names.count == 1 {
            return names[0]
        }
        if let host = serverURL.host(), host.hasSuffix(".odoo.com"), let subdomain = host.split(separator: ".").first {
            return String(subdomain)
        }
        throw OdooError.databaseRequired
    }

    /// Hauptversion über `/json/version` (gibt es ab Odoo 19).
    private func json2MajorVersion(serverURL: URL) async -> Int? {
        var request = URLRequest(url: serverURL.appending(path: "json/version"))
        request.httpMethod = "GET"
        guard let (data, response) = try? await http.send(request), response.statusCode == 200,
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return value["version_info"]?.arrayValue?.first?.intValue
    }
}

private extension OdooError {
    /// Fehler, bei denen der Server JSON-2 offenbar nicht anbietet.
    var meansNoJSON2: Bool {
        switch self {
        case .notFound, .unexpectedResponse, .server, .accessDenied: return true
        default: return false
        }
    }
}

/// Liest die Serveradresse so, wie Benutzer sie eingeben oder aus dem Browser kopieren.
enum ServerAddress {
    /// `odoo.example.de`, `https://odoo.example.de/odoo/timesheets` → `https://odoo.example.de`
    static func normalize(_ input: String) -> URL? {
        var text = input.trimmed
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty, !host.contains(" ") else { return nil }
        components.scheme = scheme
        components.host = host.lowercased()
        components.user = nil
        components.password = nil
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// https, oder http nur auf dem eigenen Rechner (lokale Testumgebung).
    static func isSecure(_ url: URL) -> Bool {
        if url.scheme == "https" { return true }
        guard let host = url.host()?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".localhost")
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
