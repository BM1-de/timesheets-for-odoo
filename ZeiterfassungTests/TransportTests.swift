// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Zeiterfassung

private let server = URL(string: "https://odoo.example.de")!

@Suite("JSON-2")
struct JSON2TransportTests {
    @Test("baut die Anfrage wie in der Odoo-Dokumentation")
    func buildsRequest() async throws {
        let http = StubHTTPClient { _ in StubHTTPClient.json([["id": 1]]) }
        let transport = JSON2Transport(baseURL: server, apiKey: "geheim", database: "demo", http: http)
        _ = try await transport.execute(
            OdooCall(model: "res.users", method: "read", ids: [7], arguments: ["fields": ["name"]]),
            context: ["lang": "de_DE"]
        )
        let request = try #require(http.requests.first)
        #expect(request.url?.absoluteString == "https://odoo.example.de/json/2/res.users/read")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "bearer geheim")
        #expect(request.value(forHTTPHeaderField: "X-Odoo-Database") == "demo")
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true)
        let sent = try #require(requestBody(of: request))
        #expect(sent["ids"] == .ints([7]))
        #expect(sent["fields"] == ["name"])
        #expect(sent["context"] == ["lang": "de_DE"])
    }

    @Test("ohne Datenbank kein Kopf X-Odoo-Database, Modellmethoden ohne ids")
    func omitsOptionalParts() async throws {
        let http = StubHTTPClient { _ in StubHTTPClient.json([]) }
        let transport = JSON2Transport(baseURL: server, apiKey: "geheim", database: nil, http: http)
        _ = try await transport.execute(OdooCall(model: "project.project", method: "search_read"), context: [:])
        let request = try #require(http.requests.first)
        #expect(request.value(forHTTPHeaderField: "X-Odoo-Database") == nil)
        #expect(requestBody(of: request)?["ids"] == nil)
        #expect(requestBody(of: request)?["context"] == nil)
    }

    @Test("ordnet Fehler von Odoo zu")
    func mapsErrors() async {
        func failing(_ reply: StubHTTPClient.Reply) -> JSON2Transport {
            JSON2Transport(baseURL: server, apiKey: "k", database: nil, http: StubHTTPClient { _ in reply })
        }
        let call = OdooCall(model: "hr.attendance", method: "create")
        await #expect(throws: OdooError.unauthorized) {
            _ = try await failing(StubHTTPClient.json(["name": "werkzeug.exceptions.Unauthorized", "message": "Invalid apikey"], status: 401)).execute(call, context: [:])
        }
        await #expect(throws: OdooError.accessDenied("Keine Berechtigung")) {
            _ = try await failing(StubHTTPClient.json(["name": "odoo.exceptions.AccessError", "message": "Keine Berechtigung"], status: 403)).execute(call, context: [:])
        }
        await #expect(throws: OdooError.rejected("Bitte eine Aufgabe wählen")) {
            _ = try await failing(StubHTTPClient.json(["name": "odoo.exceptions.ValidationError", "message": "Bitte eine Aufgabe wählen"], status: 422)).execute(call, context: [:])
        }
        await #expect(throws: OdooError.notFound("Die Schnittstelle wurde nicht gefunden (HTTP 404).")) {
            _ = try await failing(StubHTTPClient.html(status: 404)).execute(call, context: [:])
        }
        await #expect(throws: OdooError.unexpectedResponse("Die Antwort war kein JSON (HTTP 200).")) {
            _ = try await failing(StubHTTPClient.html(status: 200)).execute(call, context: [:])
        }
    }

    @Test("folgt keiner Umleitung: Der API-Schlüssel geht nur an die eingetragene Adresse")
    func refusesRedirects() async {
        let target = "https://anderer-server.example.com/json/2/res.users/context_get"
        let http = StubHTTPClient { _ in StubHTTPClient.redirect(to: target) }
        let transport = JSON2Transport(baseURL: server, apiKey: "geheim", database: nil, http: http)
        await #expect(throws: OdooError.redirected(target)) {
            _ = try await transport.execute(OdooCall(model: "res.users", method: "context_get"), context: [:])
        }
        let legacy = StubHTTPClient { _ in StubHTTPClient.redirect(to: "https://anderer-server.example.com/jsonrpc", status: 307) }
        await #expect(throws: OdooError.redirected("https://anderer-server.example.com/jsonrpc")) {
            _ = try await JSONRPCTransport.call(baseURL: server, http: legacy, service: "common", method: "version", arguments: [])
        }
    }
}

@Suite("JSON-RPC")
struct JSONRPCTransportTests {
    @Test("execute_kw mit ids, benannten Argumenten und Kontext")
    func buildsExecuteKW() async throws {
        let http = StubHTTPClient { _ in StubHTTPClient.json(["jsonrpc": "2.0", "id": 1, "result": true]) }
        let transport = JSONRPCTransport(baseURL: server, database: "demo", uid: 7, apiKey: "geheim", http: http)
        _ = try await transport.execute(
            OdooCall(model: "hr.attendance", method: "write", ids: [5], arguments: ["vals": ["check_out": "2026-10-23 12:00:00"]]),
            context: ["lang": "de_DE"]
        )
        let request = try #require(http.requests.first)
        #expect(request.url?.absoluteString == "https://odoo.example.de/jsonrpc")
        let params = try #require(requestBody(of: request)?["params"])
        #expect(params["service"] == "object")
        #expect(params["method"] == "execute_kw")
        let args = try #require(params["args"]?.arrayValue)
        #expect(Array(args.prefix(5)) == ["demo", .int(7), "geheim", "hr.attendance", "write"])
        #expect(args[5] == [.ints([5])])
        #expect(args[6]["vals"] == ["check_out": "2026-10-23 12:00:00"])
        #expect(args[6]["context"] == ["lang": "de_DE"])
    }

    @Test("create übergibt die Werte als Position, wie Odoo es verlangt")
    func createIsPositional() async throws {
        let http = StubHTTPClient { _ in StubHTTPClient.json(["jsonrpc": "2.0", "id": 1, "result": [12]]) }
        let transport = JSONRPCTransport(baseURL: server, database: "demo", uid: 7, apiKey: "geheim", http: http)
        _ = try await transport.execute(
            OdooCall(model: "account.analytic.line", method: "create", arguments: ["vals_list": [["name": "x"]]],
                     positionalForJSONRPC: ["vals_list"]),
            context: [:]
        )
        let request = try #require(http.requests.first)
        let args = try #require(requestBody(of: request)?["params"]?["args"]?.arrayValue)
        #expect(args[5] == [[["name": "x"]]])
        #expect(args[6] == [:])
    }

    @Test("ordnet Fehler zu")
    func mapsErrors() async {
        func reply(_ name: String, code: Int = 200) -> StubHTTPClient {
            StubHTTPClient { _ in
                StubHTTPClient.json(["jsonrpc": "2.0", "id": 1,
                                     "error": ["code": .int(code), "message": "Odoo Server Error",
                                               "data": ["name": .string(name), "message": "Meldung"]]])
            }
        }
        let call = OdooCall(model: "res.users", method: "context_get")
        await #expect(throws: OdooError.unauthorized) {
            _ = try await JSONRPCTransport(baseURL: server, database: "d", uid: 1, apiKey: "k", http: reply("odoo.exceptions.AccessDenied")).execute(call, context: [:])
        }
        await #expect(throws: OdooError.notFound("Meldung")) {
            _ = try await JSONRPCTransport(baseURL: server, database: "d", uid: 1, apiKey: "k", http: reply("builtins.KeyError")).execute(call, context: [:])
        }
        await #expect(throws: OdooError.rejected("Meldung")) {
            _ = try await JSONRPCTransport(baseURL: server, database: "d", uid: 1, apiKey: "k", http: reply("odoo.exceptions.UserError")).execute(call, context: [:])
        }
        await #expect(throws: OdooError.unauthorized) {
            _ = try await JSONRPCTransport(baseURL: server, database: "d", uid: 1, apiKey: "k", http: reply("odoo.http.SessionExpiredException", code: 100)).execute(call, context: [:])
        }
    }

    @Test("ein fehlendes Modell ist „nicht installiert“, auch in übersetzten Meldungen", arguments: [
        "Object hr.attendance doesn't exist", "Objekt hr.attendance existiert nicht", "L'objet hr.attendance n'existe pas !",
    ])
    func missingModel(message: String) {
        #expect(OdooError.fromOdoo(name: "odoo.exceptions.UserError", message: message, status: 200) == .notFound(message))
    }
}

@Suite("Verbindung herstellen")
struct ConnectorTests {
    let url = URL(string: "https://odoo.example.de")!

    @Test("Odoo 19: API-Schlüssel genügt")
    func json2() async throws {
        let odoo = FakeOdoo(mode: .odoo19)
        let session = try await Connector(http: odoo.client()).connect(serverURL: url, apiKey: odoo.apiKey, login: nil, database: nil)
        #expect(session.interface == .json2)
        #expect(session.uid == 7)
        #expect(session.language == "de_DE")
        #expect(session.serverMajorVersion == 19)
    }

    @Test("Odoo 19: mehrere Datenbanken verlangen den Namen, statt nach dem Benutzernamen zu fragen")
    func json2NeedsDatabase() async throws {
        let odoo = FakeOdoo(mode: .odoo19)
        odoo.databases = ["demo", "test"]
        let connector = Connector(http: odoo.client())
        await #expect(throws: OdooError.databaseRequired) {
            _ = try await connector.connect(serverURL: url, apiKey: odoo.apiKey, login: nil, database: nil)
        }
        let session = try await connector.connect(serverURL: url, apiKey: odoo.apiKey, login: nil, database: "test")
        #expect(session.interface == .json2)
        #expect(session.database == "test")
    }

    @Test("Odoo 19: falscher Schlüssel")
    func json2Unauthorized() async {
        let odoo = FakeOdoo(mode: .odoo19)
        await #expect(throws: OdooError.unauthorized) {
            _ = try await Connector(http: odoo.client()).connect(serverURL: url, apiKey: "falsch", login: nil, database: nil)
        }
    }

    @Test("Odoo 17: verlangt den Benutzernamen und meldet sich per JSON-RPC an")
    func legacy() async throws {
        let odoo = FakeOdoo(mode: .odoo17)
        let connector = Connector(http: odoo.client())
        await #expect(throws: OdooError.loginRequired) {
            _ = try await connector.connect(serverURL: url, apiKey: odoo.apiKey, login: nil, database: nil)
        }
        let session = try await connector.connect(serverURL: url, apiKey: odoo.apiKey, login: odoo.login, database: nil)
        #expect(session.interface == .jsonRPC)
        #expect(session.database == "demo")
        #expect(session.login == odoo.login)
        #expect(session.serverMajorVersion == 17)
    }

    @Test("Odoo 17: mehrere Datenbanken verlangen den Namen")
    func legacyNeedsDatabase() async throws {
        let odoo = FakeOdoo(mode: .odoo17)
        odoo.databases = ["demo", "test"]
        let connector = Connector(http: odoo.client())
        await #expect(throws: OdooError.databaseRequired) {
            _ = try await connector.connect(serverURL: url, apiKey: odoo.apiKey, login: odoo.login, database: nil)
        }
        let session = try await connector.connect(serverURL: url, apiKey: odoo.apiKey, login: odoo.login, database: "test")
        #expect(session.database == "test")
    }

    @Test("Odoo 17: falsches Passwort")
    func legacyUnauthorized() async {
        let odoo = FakeOdoo(mode: .odoo17)
        await #expect(throws: OdooError.unauthorized) {
            _ = try await Connector(http: odoo.client()).connect(serverURL: url, apiKey: "falsch", login: odoo.login, database: nil)
        }
    }

    @Test("ohne Netz")
    func offline() async {
        let odoo = FakeOdoo()
        odoo.offline = true
        await #expect(throws: OdooError.offline("Die Netzwerkverbindung wurde unterbrochen.")) {
            _ = try await Connector(http: odoo.client()).connect(serverURL: url, apiKey: odoo.apiKey, login: nil, database: nil)
        }
    }
}
