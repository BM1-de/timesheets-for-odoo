// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

// Ein simuliertes Odoo: für Unit-Tests, für Bildschirmfotos mit erfundenen Daten und für den
// Demo-Modus, in dem man die App ohne eigenes Odoo ausprobiert.

import Foundation

/// HTTP-Client für Tests: beantwortet Anfragen über eine Funktion und merkt sie sich.
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    struct Reply {
        var status: Int
        var contentType: String
        var body: Data
        var headers: [String: String] = [:]
    }

    private let lock = NSLock()
    private let handler: @Sendable (URLRequest) throws -> Reply
    private var recorded: [URLRequest] = []

    init(handler: @escaping @Sendable (URLRequest) throws -> Reply) {
        self.handler = handler
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func record(_ request: URLRequest) {
        lock.lock()
        recorded.append(request)
        lock.unlock()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        record(request)
        return Self.response(to: request, with: try handler(request))
    }

    static func response(to request: URLRequest, with reply: Reply) -> (Data, HTTPURLResponse) {
        var headers = reply.headers
        headers["Content-Type"] = reply.contentType
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        return (reply.body, response)
    }

    static func json(_ value: JSONValue, status: Int = 200) -> Reply {
        Reply(status: status, contentType: "application/json; charset=utf-8", body: try! JSONEncoder().encode(value))
    }

    static func html(status: Int) -> Reply {
        Reply(status: status, contentType: "text/html; charset=utf-8", body: Data("<html>Seite nicht gefunden</html>".utf8))
    }

    static func redirect(to location: String, status: Int = 301) -> Reply {
        Reply(status: status, contentType: "text/html; charset=utf-8", body: Data(), headers: ["Location": location])
    }
}

func requestBody(of request: URLRequest) -> JSONValue? {
    request.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
}

/// Ein kleines Odoo im Arbeitsspeicher. Beantwortet JSON-2 (wie Odoo 19) oder nur JSON-RPC
/// (wie Odoo 17/18) und hält Projekte, Aufgaben, Zeiteinträge und Anwesenheiten. Dient den Tests,
/// den Bildschirmfotos und dem Demo-Modus (DemoServer). Alle Namen sind erfunden.
final class FakeOdoo: @unchecked Sendable {
    enum Mode {
        case odoo19
        case odoo17
    }

    struct Line {
        var id: Int
        var date: String
        var name: String
        var projectID: Int
        var taskID: Int?
        var hours: Double
    }

    struct Attendance {
        var id: Int
        var checkIn: String
        var checkOut: String?
    }

    private let lock = NSLock()
    var mode: Mode
    var apiKey = "test-schluessel-123"
    let login = "erika@example.com"
    var databases = ["demo"]
    var uid = 7
    var userName = "Erika Mustermann"
    var employeeID: Int? = 3
    var attendanceInstalled = true
    var canStamp = true
    /// Das Recht zu stempeln scheint da, eine Datensatzregel lehnt das Anlegen dann aber ab
    /// („Sachbearbeiter: Anwesenheiten verwalten“, ohne eigener Anwesenheitsgenehmiger zu sein).
    var stampDeniedByRule = false
    var offline = false
    var failNextCreate = false
    /// Legt den nächsten Zeiteintrag an, aber die Antwort geht unterwegs verloren.
    var loseNextCreateResponse = false
    var failAttendanceRead = false
    var projects: [(id: Int, name: String)] = [
        (1, "Interne Arbeiten"),
        (2, "Website-Betreuung (Muster GmbH)"),
        (3, "Kundenmagazin (Beispiel AG)"),
        (4, "Online-Shop (Demo KG)"),
    ]
    var tasks: [Int: [(id: Int, name: String)]] = [
        1: [(11, "Verwaltung"), (12, "Weiterbildung")],
        2: [(21, "Wartung")],
        3: [(31, "Text"), (32, "Layout")],
        4: [],
    ]
    var lines: [Line] = []
    var attendances: [Attendance] = []
    private var nextID = 1000
    private var losesResponse = false
    private(set) var log: [String] = []
    /// Die Tests prüfen anhand des Protokolls, was die App aufgerufen hat; im Demo-Modus würde es nur wachsen.
    var logsCalls = true

    init(mode: Mode = .odoo19) {
        self.mode = mode
    }

    func client() -> StubHTTPClient {
        StubHTTPClient { [self] request in try self.reply(to: request) }
    }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: - Anfragen

    func reply(to request: URLRequest) throws -> StubHTTPClient.Reply {
        try withLock {
            if offline { throw OdooError.offline("Die Netzwerkverbindung wurde unterbrochen.") }
            let reply = route(request)
            if losesResponse {
                losesResponse = false
                throw OdooError.offline("Zeitüberschreitung bei der Anfrage.")
            }
            return reply
        }
    }

    private func route(_ request: URLRequest) -> StubHTTPClient.Reply {
        let path = request.url?.path() ?? ""
        if path == "/json/version" {
            return mode == .odoo19
                ? StubHTTPClient.json(["version_info": [19, 0, 0, "final", 0, ""], "version": "19.0"])
                : StubHTTPClient.html(status: 404)
        }
        if path.hasPrefix("/json/2/") {
            guard mode == .odoo19 else { return StubHTTPClient.html(status: 404) }
            // Bei mehreren Datenbanken gibt es JSON-2 nur mit Angabe der Datenbank.
            let database = request.value(forHTTPHeaderField: "X-Odoo-Database")
            guard databases.count == 1 || databases.contains(database ?? "") else { return StubHTTPClient.html(status: 404) }
            return json2(request, path: path)
        }
        if path == "/jsonrpc" {
            return jsonRPC(request)
        }
        return StubHTTPClient.html(status: 404)
    }

    private func json2(_ request: URLRequest, path: String) -> StubHTTPClient.Reply {
        guard request.value(forHTTPHeaderField: "Authorization") == "bearer \(apiKey)" else {
            return StubHTTPClient.json(["name": "werkzeug.exceptions.Unauthorized", "message": "Invalid apikey",
                                        "arguments": ["Invalid apikey", 401]], status: 401)
        }
        let parts = path.split(separator: "/").map(String.init)
        let model = parts[2]
        let method = parts[3]
        var kwargs = requestBody(of: request)?.objectValue ?? [:]
        let ids = kwargs.removeValue(forKey: "ids")?.arrayValue?.compactMap(\.intValue)
        kwargs["context"] = nil
        switch dispatch(model: model, method: method, ids: ids, kwargs: kwargs) {
        case .success(let value):
            return StubHTTPClient.json(value)
        case .failure(let failure):
            return StubHTTPClient.json(["name": .string(failure.name), "message": .string(failure.message)],
                                       status: failure.status)
        }
    }

    private func jsonRPC(_ request: URLRequest) -> StubHTTPClient.Reply {
        let params = requestBody(of: request)?["params"]
        let service = params?["service"]?.stringValue ?? ""
        let method = params?["method"]?.stringValue ?? ""
        let args = params?["args"]?.arrayValue ?? []
        func result(_ value: JSONValue) -> StubHTTPClient.Reply {
            StubHTTPClient.json(["jsonrpc": "2.0", "id": 1, "result": value])
        }
        func error(_ name: String, _ message: String) -> StubHTTPClient.Reply {
            StubHTTPClient.json(["jsonrpc": "2.0", "id": 1,
                                 "error": ["code": 200, "message": "Odoo Server Error",
                                           "data": ["name": .string(name), "message": .string(message)]]])
        }
        switch (service, method) {
        case ("common", "version"):
            return result(["server_version": "17.0", "server_version_info": [17, 0, 0, "final", 0, ""]])
        case ("db", "list"):
            return databases.count == 1 ? result(.array(databases.map(JSONValue.string)))
                : error("odoo.exceptions.AccessDenied", "Access Denied")
        case ("common", "authenticate"):
            let ok = args.count >= 3 && databases.contains(args[0].stringValue ?? "")
                && args[1].stringValue == login && args[2].stringValue == apiKey
            return result(ok ? .int(uid) : false)
        case ("object", "execute_kw"):
            guard args.count >= 7, args[1].intValue == uid, args[2].stringValue == apiKey else {
                return error("odoo.exceptions.AccessDenied", "Access Denied")
            }
            let model = args[3].stringValue ?? ""
            let objectMethod = args[4].stringValue ?? ""
            var positional = args[5].arrayValue ?? []
            var kwargs = args[6].objectValue ?? [:]
            kwargs["context"] = nil
            var ids: [Int]?
            if ["read", "write", "has_access"].contains(objectMethod), !positional.isEmpty {
                ids = positional.removeFirst().arrayValue?.compactMap(\.intValue)
            }
            if objectMethod == "create" {
                guard let valsList = positional.first else { return error("builtins.IndexError", "tuple index out of range") }
                kwargs["vals_list"] = valsList
            }
            if objectMethod == "write", let vals = positional.first { kwargs["vals"] = vals }
            switch dispatch(model: model, method: objectMethod, ids: ids, kwargs: kwargs) {
            case .success(let value): return result(value)
            case .failure(let failure): return error(failure.name, failure.message)
            }
        default:
            return error("builtins.KeyError", service)
        }
    }

    // MARK: - Modelle

    private struct Failure: Error {
        let name: String
        let message: String
        let status: Int
    }

    private func dispatch(model: String, method: String, ids: [Int]?, kwargs: [String: JSONValue]) -> Result<JSONValue, Failure> {
        if logsCalls { log.append("\(model).\(method)") }
        let domain = kwargs["domain"]?.arrayValue ?? []
        switch (model, method) {
        case ("res.users", "context_get"):
            return .success(["lang": "de_DE", "tz": "Europe/Berlin", "uid": .int(uid)])
        case ("res.users", "read"):
            var record: [String: JSONValue] = ["id": .int(uid), "name": .string(userName)]
            if let employeeID {
                record["employee_id"] = [.int(employeeID), .string(userName)]
                record["employee_ids"] = [.int(employeeID)]
            } else {
                record["employee_id"] = false
                record["employee_ids"] = []
            }
            return .success([.object(record)])
        case ("account.analytic.line", "fields_get"):
            return .success(["project_id": ["type": "many2one"], "task_id": ["type": "many2one"], "unit_amount": ["type": "float"]])
        case ("project.project", "fields_get"):
            return .success(mode == .odoo19 ? ["allow_timesheets": ["type": "boolean"], "is_template": ["type": "boolean"]]
                                            : ["allow_timesheets": ["type": "boolean"]])
        case ("project.task", "fields_get"):
            return .success(["is_closed": ["type": "boolean"]])
        case ("hr.attendance", "fields_get"):
            // Fehlt die App, meldet JSON-2 „nicht gefunden“, JSON-RPC einen UserError (wie Odoo 17 bis 19).
            return attendanceInstalled
                ? .success(["check_in": ["type": "datetime"], "check_out": ["type": "datetime"]])
                : mode == .odoo19
                    ? .failure(Failure(name: "werkzeug.exceptions.NotFound", message: "the model 'hr.attendance' does not exist", status: 404))
                    : .failure(Failure(name: "odoo.exceptions.UserError", message: "Object hr.attendance doesn't exist", status: 200))
        case ("hr.attendance", "has_access"):
            return mode == .odoo19 ? .success(.bool(canStamp))
                : .failure(Failure(name: "builtins.AttributeError", message: "has_access", status: 404))
        case ("hr.attendance", "check_access_rights"):
            return .success(.bool(canStamp))
        case ("project.project", "search_read"):
            return .success(.array(projects.map { ["id": .int($0.id), "display_name": .string($0.name)] }))
        case ("project.task", "search_read"):
            let projectID = condition(domain, "project_id", "=")?.intValue ?? 0
            return .success(.array((tasks[projectID] ?? []).map { ["id": .int($0.id), "name": .string($0.name)] }))
        case ("account.analytic.line", "search_read"):
            var result = lines
            if let day = condition(domain, "date", "=")?.stringValue { result = result.filter { $0.date == day } }
            if let since = condition(domain, "date", ">=")?.stringValue { result = Array(result.filter { $0.date >= since }.reversed()) }
            return .success(.array(result.map(lineRecord)))
        case ("account.analytic.line", "create"):
            if failNextCreate {
                failNextCreate = false
                return .failure(Failure(name: "werkzeug.exceptions.ServiceUnavailable", message: "Wartung", status: 503))
            }
            guard let vals = kwargs["vals_list"]?.arrayValue?.first else {
                return .failure(Failure(name: "builtins.TypeError", message: "vals_list fehlt", status: 422))
            }
            nextID += 1
            lines.append(Line(id: nextID, date: vals["date"]?.stringValue ?? "", name: vals["name"]?.stringValue ?? "",
                              projectID: vals["project_id"]?.intValue ?? 0, taskID: vals["task_id"]?.intValue,
                              hours: vals["unit_amount"]?.doubleValue ?? 0))
            if loseNextCreateResponse {
                loseNextCreateResponse = false
                losesResponse = true
            }
            return .success([.int(nextID)])
        case ("hr.attendance", "search_read"):
            guard !failAttendanceRead else {
                return .failure(Failure(name: "odoo.exceptions.AccessError", message: "Kein Zugriff auf Anwesenheiten", status: 403))
            }
            var result = attendances
            if domain.contains(where: { $0.arrayValue?.first?.stringValue == "check_out" }) {
                result = result.filter { $0.checkOut == nil }
            }
            if let from = condition(domain, "check_in", ">=")?.stringValue,
               let to = condition(domain, "check_in", "<")?.stringValue {
                result = result.filter { $0.checkIn >= from && $0.checkIn < to }
            }
            return .success(.array(result.map { record in
                ["id": .int(record.id), "check_in": .string(record.checkIn),
                 "check_out": record.checkOut.map(JSONValue.string) ?? false]
            }))
        case ("hr.attendance", "create"):
            guard canStamp, !stampDeniedByRule else {
                return .failure(Failure(name: "odoo.exceptions.AccessError", message: "Keine Berechtigung", status: 403))
            }
            guard let vals = kwargs["vals_list"]?.arrayValue?.first else {
                return .failure(Failure(name: "builtins.TypeError", message: "vals_list fehlt", status: 422))
            }
            nextID += 1
            attendances.append(Attendance(id: nextID, checkIn: vals["check_in"]?.stringValue ?? "", checkOut: nil))
            return .success([.int(nextID)])
        case ("hr.attendance", "write"):
            guard let id = ids?.first, let index = attendances.firstIndex(where: { $0.id == id }) else {
                return .failure(Failure(name: "odoo.exceptions.MissingError", message: "Datensatz fehlt", status: 422))
            }
            attendances[index].checkOut = kwargs["vals"]?["check_out"]?.stringValue
            return .success(true)
        default:
            return .failure(Failure(name: "werkzeug.exceptions.NotFound", message: "\(model).\(method) gibt es nicht", status: 404))
        }
    }

    private func condition(_ domain: [JSONValue], _ field: String, _ op: String) -> JSONValue? {
        for item in domain {
            guard let triple = item.arrayValue, triple.count == 3,
                  triple[0].stringValue == field, triple[1].stringValue == op else { continue }
            return triple[2]
        }
        return nil
    }

    private func lineRecord(_ line: Line) -> JSONValue {
        let projectName = projects.first { $0.id == line.projectID }?.name ?? ""
        let taskName = tasks[line.projectID]?.first { $0.id == line.taskID }?.name ?? ""
        return [
            "id": .int(line.id),
            "name": .string(line.name),
            "date": .string(line.date),
            "project_id": [.int(line.projectID), .string(projectName)],
            "task_id": line.taskID.map { [.int($0), .string(taskName)] } ?? false,
            "unit_amount": .number(line.hours),
        ]
    }
}
