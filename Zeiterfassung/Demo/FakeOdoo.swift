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
        /// Ohne JSON-2: Odoo 18 leitet `/json/…` auf seine Anmeldeseite um.
        case odoo18
        case odoo17

        var major: Int {
            switch self {
            case .odoo19: 19
            case .odoo18: 18
            case .odoo17: 17
            }
        }
    }

    struct Line {
        var id: Int
        var date: String
        var name: String
        var projectID: Int
        var taskID: Int?
        var hours: Double
        /// Ohne Angabe die Hauptfirma und der Mitarbeiter darin.
        var companyID: Int?
        var employeeID: Int?
        /// Abgerechnet: Dauer, Datum, Projekt und Aufgabe stehen fest, löschen geht nicht.
        var invoiced = false
    }

    struct Attendance {
        var id: Int
        var checkIn: String
        var checkOut: String?
        var inMode: String?
        var outMode: String?
        /// Ohne Angabe der Mitarbeiter der Hauptfirma.
        var employeeID: Int?
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
    var failNextWrite = false
    /// Firmen, die der Benutzer sehen darf; die erste ist seine Hauptfirma.
    var companies: [(id: Int, name: String)] = [(1, "Muster Agentur GmbH")]
    /// Mitarbeiter des Benutzers in weiteren Firmen; `employeeID` ist der in der Hauptfirma.
    var otherEmployees: [(id: Int, companyID: Int)] = []
    /// Firma je Projekt; Projekte ohne Eintrag gehören allen Firmen.
    var projectCompanies: [Int: Int] = [:]
    /// Wie das Modul Arbeitszeitgesetz: Fehlt Pause, fügt Odoo sie beim Sichern ein.
    var breakModule = false
    var breakRules = BreakRules()
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
    /// Erledigte Aufgaben: Sie stehen nicht mehr zur Auswahl, aber noch in alten Einträgen.
    var closedTasks: [Int: String] = [:]
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
        if mode == .odoo18, path.hasPrefix("/json/") {
            let target = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            return StubHTTPClient.redirect(to: "/web/login?redirect=\(target)", status: 303)
        }
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
            return result(["server_version": .string("\(mode.major).0"),
                           "server_version_info": [.int(mode.major), 0, 0, "final", 0, ""]])
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
            if ["read", "write", "unlink", "has_access"].contains(objectMethod), !positional.isEmpty {
                ids = positional.removeFirst().arrayValue?.compactMap(\.intValue)
            }
            if objectMethod == "create" {
                guard let valsList = positional.first else { return error("builtins.IndexError", "tuple index out of range") }
                kwargs["vals_list"] = valsList
            }
            // Bis Odoo 18 heißt der Parameter von `write` bei Zeiteinträgen `values`; nur als Position passt er.
            if objectMethod == "write", model == "account.analytic.line", mode != .odoo19, kwargs["vals"] != nil {
                return error("builtins.TypeError", "AccountAnalyticLine.write() got an unexpected keyword argument 'vals'")
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
            var record: [String: JSONValue] = ["id": .int(uid), "name": .string(userName),
                                               "company_id": companyReference(mainCompanyID),
                                               "company_ids": .array(companies.map { .int($0.id) })]
            // Wie Odoo: `employee_ids` nennt nur den Mitarbeiter der Hauptfirma.
            if let employeeID {
                record["employee_id"] = [.int(employeeID), .string(userName)]
                record["employee_ids"] = [.int(employeeID)]
            } else {
                record["employee_id"] = false
                record["employee_ids"] = []
            }
            return .success([.object(record)])
        case ("res.company", "read"):
            let wanted = ids ?? []
            return .success(.array(companies.filter { wanted.contains($0.id) }.map { company in
                var record: [String: JSONValue] = ["id": .int(company.id), "name": .string(company.name)]
                if breakModule {
                    record["arbzg_break_hours_1"] = .number(Double(breakRules.firstThreshold) / 60)
                    record["arbzg_break_minutes_1"] = .int(breakRules.firstBreak)
                    record["arbzg_break_hours_2"] = .number(Double(breakRules.secondThreshold) / 60)
                    record["arbzg_break_minutes_2"] = .int(breakRules.secondBreak)
                    record["arbzg_min_break_minutes"] = .int(breakRules.minimumGap)
                    record["arbzg_max_hours"] = .number(Double(breakRules.maximumWork) / 60)
                }
                return .object(record)
            }))
        case ("hr.employee", "search_read"):
            return .success(.array(allEmployees.map { ["id": .int($0.id), "company_id": companyReference($0.companyID)] }))
        case ("account.analytic.line", "fields_get"):
            return .success(["project_id": ["type": "many2one"], "task_id": ["type": "many2one"], "unit_amount": ["type": "float"],
                             "company_id": ["type": "many2one"], "employee_id": ["type": "many2one"],
                             "timesheet_invoice_id": ["type": "many2one"]])
        case ("project.project", "fields_get"):
            return .success(mode != .odoo17 ? ["allow_timesheets": ["type": "boolean"], "is_template": ["type": "boolean"]]
                                            : ["allow_timesheets": ["type": "boolean"]])
        case ("project.task", "fields_get"):
            return .success(["is_closed": ["type": "boolean"]])
        case ("hr.attendance", "fields_get"):
            // Fehlt die App, meldet JSON-2 „nicht gefunden“, JSON-RPC einen UserError (wie Odoo 17 bis 19).
            var fields: [String: JSONValue] = ["check_in": ["type": "datetime"], "check_out": ["type": "datetime"],
                                               "in_mode": ["type": "selection"], "out_mode": ["type": "selection"]]
            if breakModule { fields["arbzg_missing_break"] = ["type": "float"] }
            return attendanceInstalled
                ? .success(.object(fields))
                : mode == .odoo19
                    ? .failure(Failure(name: "werkzeug.exceptions.NotFound", message: "the model 'hr.attendance' does not exist", status: 404))
                    : .failure(Failure(name: "odoo.exceptions.UserError", message: "Object hr.attendance doesn't exist", status: 200))
        case ("hr.attendance", "has_access"):
            return mode != .odoo17 ? .success(.bool(canStamp))
                : .failure(Failure(name: "builtins.AttributeError", message: "has_access", status: 404))
        case ("hr.attendance", "check_access_rights"):
            return .success(.bool(canStamp))
        case ("project.project", "search_read"):
            return .success(.array(projects.map { project in
                ["id": .int(project.id), "display_name": .string(project.name),
                 "company_id": projectCompanies[project.id].map(companyReference) ?? false]
            }))
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
            // Wie Odoo: die Firma des Projekts und der Mitarbeiter darin; mit nur einem Mitarbeiter dieser.
            let projectID = vals["project_id"]?.intValue ?? 0
            let projectCompany = projectCompanies[projectID]
            let employees = allEmployees
            guard let employee = employees.count == 1 ? employees.first
                    : employees.first(where: { $0.companyID == (projectCompany ?? mainCompanyID) }) else {
                return .failure(Failure(name: "odoo.exceptions.ValidationError",
                                        message: "Timesheets must be created with an active employee in the selected companies.",
                                        status: 422))
            }
            nextID += 1
            lines.append(Line(id: nextID, date: vals["date"]?.stringValue ?? "", name: vals["name"]?.stringValue ?? "",
                              projectID: projectID, taskID: vals["task_id"]?.intValue,
                              hours: vals["unit_amount"]?.doubleValue ?? 0,
                              companyID: projectCompany ?? employee.companyID, employeeID: employee.id))
            if loseNextCreateResponse {
                loseNextCreateResponse = false
                losesResponse = true
            }
            return .success([.int(nextID)])
        case ("account.analytic.line", "write"):
            if let failure = takeWriteFailure() { return .failure(failure) }
            guard let id = ids?.first, let index = lines.firstIndex(where: { $0.id == id }) else {
                return .failure(Failure(name: "odoo.exceptions.MissingError", message: "Datensatz fehlt", status: 422))
            }
            let vals = kwargs["vals"]?.objectValue ?? [:]
            if lines[index].invoiced, vals.keys.contains(where: ["unit_amount", "employee_id", "project_id", "task_id", "date"].contains) {
                return .failure(Failure(name: "odoo.exceptions.UserError",
                                        message: "You cannot modify timesheets that are already invoiced.", status: 422))
            }
            if let name = vals["name"]?.stringValue { lines[index].name = name }
            // Wie Odoo: Das Projekt bringt seine Firma mit, der Mitarbeiter bleibt, wenn er nicht mitkommt.
            if let projectID = vals["project_id"]?.intValue {
                lines[index].projectID = projectID
                if let companyID = projectCompanies[projectID] { lines[index].companyID = companyID }
            }
            if let task = vals["task_id"] { lines[index].taskID = task.intValue }
            if let hours = vals["unit_amount"]?.doubleValue { lines[index].hours = hours }
            if let date = vals["date"]?.stringValue { lines[index].date = date }
            if let employeeID = vals["employee_id"]?.intValue { lines[index].employeeID = employeeID }
            return .success(true)
        case ("account.analytic.line", "unlink"):
            let wanted = ids ?? []
            if lines.contains(where: { wanted.contains($0.id) && $0.invoiced }) {
                return .failure(Failure(name: "odoo.exceptions.UserError",
                                        message: "You cannot remove a timesheet that has already been invoiced.", status: 422))
            }
            lines.removeAll { wanted.contains($0.id) }
            return .success(true)
        case ("hr.attendance", "search_read"):
            guard !failAttendanceRead else {
                return .failure(Failure(name: "odoo.exceptions.AccessError", message: "Kein Zugriff auf Anwesenheiten", status: 403))
            }
            var result = attendances
            if let employee = condition(domain, "employee_id", "=")?.intValue {
                result = result.filter { owner(of: $0) == employee }
            }
            if domain.contains(where: { $0.arrayValue?.first?.stringValue == "check_out" }) {
                result = result.filter { $0.checkOut == nil }
            }
            if let from = condition(domain, "check_in", ">=")?.stringValue,
               let to = condition(domain, "check_in", "<")?.stringValue {
                result = result.filter { $0.checkIn >= from && $0.checkIn < to }
            }
            return .success(.array(result.sorted { $0.checkIn < $1.checkIn }.map { record in
                ["id": .int(record.id), "check_in": .string(record.checkIn),
                 "check_out": record.checkOut.map(JSONValue.string) ?? false,
                 "in_mode": record.inMode.map(JSONValue.string) ?? false,
                 "out_mode": record.outMode.map(JSONValue.string) ?? false]
            }))
        case ("hr.attendance", "create"):
            guard canStamp, !stampDeniedByRule else {
                return .failure(Failure(name: "odoo.exceptions.AccessError", message: "Keine Berechtigung", status: 403))
            }
            guard let vals = kwargs["vals_list"]?.arrayValue?.first else {
                return .failure(Failure(name: "builtins.TypeError", message: "vals_list fehlt", status: 422))
            }
            let employee = vals["employee_id"]?.intValue
            let record = Attendance(id: nextID + 1, checkIn: vals["check_in"]?.stringValue ?? "",
                                    checkOut: vals["check_out"]?.stringValue, inMode: "manual",
                                    outMode: vals["check_out"]?.stringValue == nil ? nil : "manual",
                                    employeeID: employee == employeeID ? nil : employee)
            if let failure = attendanceProblem(record) { return .failure(failure) }
            nextID += 1
            attendances.append(record)
            insertMissingBreak(after: record)
            return .success([.int(nextID)])
        case ("hr.attendance", "write"):
            guard canStamp, !stampDeniedByRule else {
                return .failure(Failure(name: "odoo.exceptions.AccessError", message: "Keine Berechtigung", status: 403))
            }
            if let failure = takeWriteFailure() { return .failure(failure) }
            guard let id = ids?.first, let index = attendances.firstIndex(where: { $0.id == id }) else {
                return .failure(Failure(name: "odoo.exceptions.MissingError", message: "Datensatz fehlt", status: 422))
            }
            let vals = kwargs["vals"]?.objectValue ?? [:]
            var record = attendances[index]
            if let checkIn = vals["check_in"]?.stringValue { record.checkIn = checkIn }
            if vals.keys.contains("check_out") { record.checkOut = vals["check_out"]?.stringValue }
            if let mode = vals["in_mode"]?.stringValue { record.inMode = mode }
            if let mode = vals["out_mode"]?.stringValue { record.outMode = mode }
            if let failure = attendanceProblem(record) { return .failure(failure) }
            attendances[index] = record
            insertMissingBreak(after: record)
            return .success(true)
        case ("hr.attendance", "unlink"):
            guard canStamp, !stampDeniedByRule else {
                return .failure(Failure(name: "odoo.exceptions.AccessError", message: "Keine Berechtigung", status: 403))
            }
            let wanted = ids ?? []
            attendances.removeAll { wanted.contains($0.id) }
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
        let taskName = tasks[line.projectID]?.first { $0.id == line.taskID }?.name
            ?? line.taskID.flatMap { closedTasks[$0] } ?? ""
        let employee = line.employeeID ?? employeeID
        return [
            "id": .int(line.id),
            "name": .string(line.name),
            "date": .string(line.date),
            "project_id": [.int(line.projectID), .string(projectName)],
            "task_id": line.taskID.map { [.int($0), .string(taskName)] } ?? false,
            "unit_amount": .number(line.hours),
            "company_id": companyReference(line.companyID ?? mainCompanyID),
            "employee_id": employee.map { [.int($0), .string(userName)] } ?? false,
            "timesheet_invoice_id": line.invoiced ? [.int(9001), "RE/2026/0042"] : false,
        ]
    }

    // MARK: - Firmen und Mitarbeiter

    private var mainCompanyID: Int { companies.first?.id ?? 1 }

    private func companyReference(_ id: Int) -> JSONValue {
        [.int(id), .string(companies.first { $0.id == id }?.name ?? "Firma \(id)")]
    }

    /// Alle Mitarbeiter des Benutzers, der der Hauptfirma zuerst.
    private var allEmployees: [(id: Int, companyID: Int)] {
        (employeeID.map { [(id: $0, companyID: mainCompanyID)] } ?? []) + otherEmployees
    }

    private func owner(of attendance: Attendance) -> Int? {
        attendance.employeeID ?? employeeID
    }

    private func takeWriteFailure() -> Failure? {
        guard failNextWrite else { return nil }
        failNextWrite = false
        return Failure(name: "werkzeug.exceptions.ServiceUnavailable", message: "Wartung", status: 503)
    }

    // MARK: - Anwesenheiten prüfen wie Odoo

    /// Ende vor Beginn oder Überschneidung mit einer anderen Anwesenheit desselben Mitarbeiters.
    private func attendanceProblem(_ record: Attendance) -> Failure? {
        if let checkOut = record.checkOut, checkOut < record.checkIn {
            return Failure(name: "odoo.exceptions.ValidationError",
                           message: "\"Check Out\" time cannot be earlier than \"Check In\" time.", status: 422)
        }
        let end = record.checkOut ?? "9999-12-31 23:59:59"
        let clash = attendances.first { other in
            other.id != record.id && owner(of: other) == owner(of: record)
                && record.checkIn < (other.checkOut ?? "9999-12-31 23:59:59") && end > other.checkIn
        }
        guard let clash else { return nil }
        return Failure(name: "odoo.exceptions.ValidationError",
                       message: "Cannot create new attendance record for \(userName), the employee was already checked in on \(clash.checkIn)",
                       status: 422)
    }

    /// Wie das Modul Arbeitszeitgesetz: Fehlt an einem Tag Pause, teilt Odoo die längste Anwesenheit
    /// und legt die Pause in ihre Mitte; der zweite Teil ist „technical“ angelegt.
    private func insertMissingBreak(after changed: Attendance) {
        guard breakModule else { return }
        let day = String(changed.checkIn.prefix(10))
        let list = attendances.filter { owner(of: $0) == owner(of: changed) && $0.checkIn.hasPrefix(day) }
            .sorted { $0.checkIn < $1.checkIn }
        guard !list.isEmpty, list.allSatisfy({ $0.checkOut != nil }) else { return }
        func date(_ text: String?) -> Date { text.flatMap(OdooDateTime.date(from:)) ?? .distantPast }
        func minutes(_ item: Attendance) -> Int { Int(date(item.checkOut).timeIntervalSince(date(item.checkIn)) / 60) }
        let work = list.reduce(0) { $0 + minutes($1) }
        var breaks = 0
        for (before, after) in zip(list, list.dropFirst()) {
            let gap = Int(date(after.checkIn).timeIntervalSince(date(before.checkOut)) / 60)
            if gap >= breakRules.minimumGap || after.inMode == "technical" { breaks += max(0, gap) }
        }
        let missing = breakRules.missingBreak(work: work, breaks: breaks).missing
        guard missing > 0, let longest = list.max(by: { minutes($0) < minutes($1) }), minutes(longest) > missing + 2,
              let index = attendances.firstIndex(where: { $0.id == longest.id }) else { return }
        let start = date(longest.checkIn).addingTimeInterval(TimeInterval((minutes(longest) - missing) / 2 * 60))
        let end = start.addingTimeInterval(TimeInterval(missing * 60))
        let originalCheckOut = attendances[index].checkOut
        attendances[index].checkOut = OdooDateTime.string(from: start)
        nextID += 1
        attendances.append(Attendance(id: nextID, checkIn: OdooDateTime.string(from: end), checkOut: originalCheckOut,
                                      inMode: "technical", outMode: longest.outMode, employeeID: longest.employeeID))
    }
}
