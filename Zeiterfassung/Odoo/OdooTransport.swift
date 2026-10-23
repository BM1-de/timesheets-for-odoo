// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Aufruf einer Odoo-Methode, unabhängig von der Schnittstelle.
struct OdooCall: Sendable {
    var model: String
    var method: String
    /// Datensätze, auf denen die Methode läuft; `nil` für Methoden des Modells
    /// wie `search_read` oder `create`.
    var ids: [Int]?
    /// Benannte Argumente, z. B. `domain` und `fields`.
    var arguments: [String: JSONValue]
    /// Argumente, die die ältere Schnittstelle (JSON-RPC) als Position statt als Namen braucht,
    /// in dieser Reihenfolge. Odoo verlangt das bei `create`.
    var positionalForJSONRPC: [String]

    init(model: String, method: String, ids: [Int]? = nil, arguments: [String: JSONValue] = [:],
         positionalForJSONRPC: [String] = []) {
        self.model = model
        self.method = method
        self.ids = ids
        self.arguments = arguments
        self.positionalForJSONRPC = positionalForJSONRPC
    }
}

/// Eine Schnittstelle zu Odoo: JSON-2 (ab Odoo 19) oder JSON-RPC (Odoo 17 und 18).
protocol OdooTransport: Sendable {
    func execute(_ call: OdooCall, context: [String: JSONValue]) async throws -> JSONValue
}

/// JSON-2, die Schnittstelle ab Odoo 19: `POST /json/2/<Modell>/<Methode>` mit API-Schlüssel.
struct JSON2Transport: OdooTransport {
    let baseURL: URL
    let apiKey: String
    let database: String?
    let http: any HTTPClient

    func execute(_ call: OdooCall, context: [String: JSONValue]) async throws -> JSONValue {
        var body = call.arguments
        if let ids = call.ids { body["ids"] = .ints(ids) }
        if !context.isEmpty { body["context"] = .object(context) }

        var request = URLRequest(url: baseURL.appending(path: "json/2/\(call.model)/\(call.method)"))
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let database, !database.isEmpty {
            request.setValue(database, forHTTPHeaderField: "X-Odoo-Database")
        }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))

        let (data, response) = try await http.send(request)
        return try Self.decode(data: data, response: response)
    }

    static func decode(data: Data, response: HTTPURLResponse) throws -> JSONValue {
        let status = response.statusCode
        if (300..<400).contains(status) {
            throw OdooError.redirected(response.value(forHTTPHeaderField: "Location") ?? "")
        }
        let isJSON = response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("json") ?? false
        let value = isJSON ? try? JSONDecoder().decode(JSONValue.self, from: data) : nil

        if (200..<300).contains(status) {
            guard let value else {
                throw OdooError.unexpectedResponse(String(localized: "Die Antwort war kein JSON (HTTP \(status))."))
            }
            return value
        }
        if let value, let name = value["name"]?.stringValue {
            throw OdooError.fromOdoo(name: name, message: value["message"]?.stringValue ?? "", status: status)
        }
        switch status {
        case 401: throw OdooError.unauthorized
        case 404: throw OdooError.notFound(String(localized: "Die Schnittstelle wurde nicht gefunden (HTTP 404)."))
        default: throw OdooError.server("HTTP \(status)")
        }
    }
}

/// JSON-RPC, die ältere Schnittstelle (`/jsonrpc`). Odoo 19 kündigt sie ab, entfernt
/// werden soll sie mit Odoo 22. Sie braucht Datenbank, Benutzer-ID und API-Schlüssel.
struct JSONRPCTransport: OdooTransport {
    let baseURL: URL
    let database: String
    let uid: Int
    let apiKey: String
    let http: any HTTPClient

    func execute(_ call: OdooCall, context: [String: JSONValue]) async throws -> JSONValue {
        var positional: [JSONValue] = []
        if let ids = call.ids { positional.append(.ints(ids)) }
        var keywords = call.arguments
        for name in call.positionalForJSONRPC {
            positional.append(keywords.removeValue(forKey: name) ?? .null)
        }
        if !context.isEmpty { keywords["context"] = .object(context) }

        return try await Self.call(
            baseURL: baseURL, http: http, service: "object", method: "execute_kw",
            arguments: [.string(database), .int(uid), .string(apiKey), .string(call.model), .string(call.method),
                        .array(positional), .object(keywords)]
        )
    }

    /// Ruft einen Dienst von `/jsonrpc` auf (`common`, `db` oder `object`).
    static func call(baseURL: URL, http: any HTTPClient, service: String, method: String,
                     arguments: [JSONValue]) async throws -> JSONValue {
        var request = URLRequest(url: baseURL.appending(path: "jsonrpc"))
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let payload: JSONValue = [
            "jsonrpc": "2.0",
            "method": "call",
            "id": .int(Int.random(in: 1...999_999)),
            "params": ["service": .string(service), "method": .string(method), "args": .array(arguments)],
        ]
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await http.send(request)
        if (300..<400).contains(response.statusCode) {
            throw OdooError.redirected(response.value(forHTTPHeaderField: "Location") ?? "")
        }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 404 {
                throw OdooError.notFound(String(localized: "Die Schnittstelle /jsonrpc wurde nicht gefunden."))
            }
            throw OdooError.server("HTTP \(response.statusCode)")
        }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw OdooError.unexpectedResponse(String(localized: "Die Antwort war kein JSON."))
        }
        if let error = value["error"], error != .null {
            let details = error["data"]
            let name = details?["name"]?.stringValue ?? ""
            let message = details?["message"]?.stringValue ?? error["message"]?.stringValue ?? ""
            switch error["code"]?.intValue {
            case 100: throw OdooError.unauthorized
            case 404: throw OdooError.notFound(message)
            default: throw OdooError.fromOdoo(name: name, message: message, status: nil)
            }
        }
        return value["result"] ?? .null
    }
}
