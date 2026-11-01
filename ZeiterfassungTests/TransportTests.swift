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

@Suite("Zu viele Anfragen")
struct PacedHTTPClientTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var slept: [Duration] = []
        private var current = Date(timeIntervalSince1970: 1_000)

        var waits: [Duration] { lock.withLock { slept } }
        var now: Date { lock.withLock { current } }

        func wait(_ duration: Duration) { lock.withLock { slept.append(duration) } }
        func advance(by seconds: TimeInterval) { lock.withLock { current.addTimeInterval(seconds) } }
    }

    /// Antwortet nach kurzer Zeit und merkt sich, wie viele Anfragen gleichzeitig liefen.
    private final class ConcurrencyProbe: HTTPClient, @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private var highest = 0

        var mostAtOnce: Int { lock.withLock { highest } }

        private func change(by delta: Int) {
            lock.withLock {
                active += delta
                highest = max(highest, active)
            }
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            change(by: 1)
            defer { change(by: -1) }
            try await Task.sleep(for: .milliseconds(5))
            return StubHTTPClient.response(to: request, with: StubHTTPClient.json([]))
        }
    }

    private static func tooMany(retryAfter: String? = nil) -> StubHTTPClient.Reply {
        var reply = StubHTTPClient.html(status: 429)
        if let retryAfter { reply.headers["Retry-After"] = retryAfter }
        return reply
    }

    private func client(_ http: any HTTPClient, _ recorder: Recorder) -> PacedHTTPClient {
        PacedHTTPClient(base: http, clock: { recorder.now }, sleep: { recorder.wait($0) })
    }

    @Test("wiederholt nach HTTP 429 und beachtet Retry-After")
    func retriesAfterWaiting() async throws {
        let recorder = Recorder()
        let replies = NSLock()
        nonisolated(unsafe) var isFirst = true
        let http = StubHTTPClient { _ in
            replies.withLock {
                defer { isFirst = false }
                return isFirst ? Self.tooMany(retryAfter: "3") : StubHTTPClient.json([])
            }
        }
        let (_, response) = try await client(http, recorder).send(URLRequest(url: server))
        #expect(response.statusCode == 200)
        #expect(http.requests.count == 2)
        #expect(recorder.waits == [.seconds(3)])
    }

    @Test("gibt nach drei Wiederholungen auf und fragt eine Weile nicht mehr an")
    func pausesAfterGivingUp() async throws {
        let recorder = Recorder()
        let http = StubHTTPClient { _ in Self.tooMany() }
        let paced = client(http, recorder)
        let request = URLRequest(url: server)
        await #expect(throws: OdooError.rateLimited) { _ = try await paced.send(request) }
        #expect(http.requests.count == 4)
        #expect(recorder.waits == [.seconds(2), .seconds(4), .seconds(8)])

        await #expect(throws: OdooError.rateLimited) { _ = try await paced.send(request) }
        #expect(http.requests.count == 4)

        recorder.advance(by: 31)
        await #expect(throws: OdooError.rateLimited) { _ = try await paced.send(request) }
        #expect(http.requests.count == 8)
    }

    @Test("wartet nicht, wenn Retry-After zu lang ist")
    func longRetryAfterFailsAtOnce() async throws {
        let recorder = Recorder()
        let http = StubHTTPClient { _ in Self.tooMany(retryAfter: "120") }
        let paced = client(http, recorder)
        await #expect(throws: OdooError.rateLimited) { _ = try await paced.send(URLRequest(url: server)) }
        #expect(http.requests.count == 1)
        #expect(recorder.waits.isEmpty)
    }

    @Test("schickt gleichzeitige Anfragen nacheinander")
    func sendsOneAtATime() async throws {
        let probe = ConcurrencyProbe()
        let paced = PacedHTTPClient(base: probe)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { _ = try await paced.send(URLRequest(url: server)) }
            }
            try await group.waitForAll()
        }
        #expect(probe.mostAtOnce == 1)
    }

    @Test("Anmeldung bei Odoo Online fragt bei HTTP 429 nicht nach dem Benutzernamen")
    func connectReportsRateLimit() async throws {
        let recorder = Recorder()
        let http = StubHTTPClient { _ in Self.tooMany() }
        let connector = Connector(http: client(http, recorder))
        let url = try #require(URL(string: "https://firma.odoo.com"))
        await #expect(throws: OdooError.rateLimited) {
            _ = try await connector.connect(serverURL: url, apiKey: "geheim", login: nil, database: nil)
        }
    }
}
