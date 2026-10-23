// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Lesen und Schreiben der Daten, die die App braucht. Alles läuft mit den Rechten des
/// angemeldeten Benutzers; die App fordert keine erweiterten Rechte an.
struct OdooService: Sendable {
    let transport: any OdooTransport
    let uid: Int
    /// Sprache für Meldungen aus Odoo.
    var context: [String: JSONValue] = [:]
    var schema = Schema()

    private func call(_ model: String, _ method: String, ids: [Int]? = nil, _ arguments: [String: JSONValue] = [:],
                      positional: [String] = []) async throws -> JSONValue {
        try await transport.execute(
            OdooCall(model: model, method: method, ids: ids, arguments: arguments, positionalForJSONRPC: positional),
            context: context
        )
    }

    // MARK: - Was gibt es?

    func discoverCapabilities() async throws -> Capabilities {
        let user = try await call("res.users", "read", ids: [uid], ["fields": ["name"]])
        let userName = user.arrayValue?.first?["name"]?.stringValue ?? ""

        // Mitarbeiter: Felder aus der Odoo-App „Mitarbeiter“, auf die Zeiterfassung und Anwesenheiten aufbauen.
        var employeeID: Int?
        var hasEmployee = false
        if let employee = try? await call("res.users", "read", ids: [uid], ["fields": ["employee_id", "employee_ids"]]),
           let record = employee.arrayValue?.first {
            employeeID = record["employee_id"]?.reference?.id
            hasEmployee = employeeID != nil || !(record["employee_ids"]?.arrayValue?.isEmpty ?? true)
        }

        let lineFields = try await fieldNames(of: "account.analytic.line")
        let timesheets: Capabilities.Status
        switch lineFields {
        case .some(let fields) where fields.contains("project_id"):
            timesheets = hasEmployee ? .available : .noEmployee
        case .some:
            timesheets = .notInstalled
        case .none:
            timesheets = .notInstalled
        }

        let attendanceFields = try await fieldNames(of: "hr.attendance")
        let attendance: Capabilities.Status = attendanceFields == nil ? .notInstalled : (hasEmployee ? .available : .noEmployee)
        let canStamp = attendance == .available ? await canCreate("hr.attendance") : false

        var schema = Schema()
        if timesheets == .available {
            schema.projectHasTemplates = try await fieldNames(of: "project.project")?.contains("is_template") ?? false
            schema.taskHasIsClosed = try await fieldNames(of: "project.task")?.contains("is_closed") ?? false
        }

        return Capabilities(userName: userName, timesheets: timesheets, attendance: attendance, canStamp: canStamp,
                            employeeID: employeeID, schema: schema)
    }

    /// Feldnamen eines Modells; `nil`, wenn es das Modell nicht gibt (App nicht installiert).
    func fieldNames(of model: String) async throws -> Set<String>? {
        do {
            let fields = try await call(model, "fields_get", ["attributes": ["type"]])
            return Set(fields.objectValue?.keys.map { $0 } ?? [])
        } catch OdooError.notFound {
            return nil
        }
    }

    /// Darf der Benutzer Datensätze dieses Modells anlegen? `has_access` gibt es ab Odoo 18,
    /// davor `check_access_rights`.
    private func canCreate(_ model: String) async -> Bool {
        if let allowed = try? await call(model, "has_access", ids: [], ["operation": "create"]).boolValue {
            return allowed
        }
        if let allowed = try? await call(model, "check_access_rights",
                                         ["operation": "create", "raise_exception": false]).boolValue {
            return allowed
        }
        return false
    }

    // MARK: - Projekte und Aufgaben

    func projects() async throws -> [Project] {
        var domain: [JSONValue] = [["allow_timesheets", "=", true]]
        if schema.projectHasTemplates { domain.append(["is_template", "=", false]) }
        let rows = try await call("project.project", "search_read",
                                  ["domain": .array(domain), "fields": ["display_name"], "order": "name asc, id asc"])
        return rows.arrayValue?.compactMap { row in
            guard let id = row["id"]?.intValue else { return nil }
            return Project(id: id, name: row["display_name"]?.stringValue ?? "")
        } ?? []
    }

    /// Offene Aufgaben eines Projekts.
    func tasks(projectID: Int) async throws -> [ProjectTask] {
        var domain: [JSONValue] = [["project_id", "=", .int(projectID)]]
        if schema.taskHasIsClosed { domain.append(["is_closed", "=", false]) }
        let rows = try await call("project.task", "search_read",
                                  ["domain": .array(domain), "fields": ["name"], "order": "sequence asc, id asc"])
        return rows.arrayValue?.compactMap { row in
            guard let id = row["id"]?.intValue else { return nil }
            return ProjectTask(id: id, name: row["name"]?.stringValue ?? "")
        } ?? []
    }

    /// Projekte der eigenen Zeiteinträge seit `day`, zuletzt verwendete zuerst.
    func recentProjectIDs(since day: CalendarDay, limit: Int = 5) async throws -> [Int] {
        let rows = try await call("account.analytic.line", "search_read", [
            "domain": [["user_id", "=", .int(uid)], ["project_id", "!=", false], ["date", ">=", .string(day.odooString)]],
            "fields": ["project_id"],
            "order": "date desc, id desc",
            "limit": 200,
        ])
        var seen = Set<Int>()
        var ids: [Int] = []
        for row in rows.arrayValue ?? [] {
            guard let id = row["project_id"]?.reference?.id, seen.insert(id).inserted else { continue }
            ids.append(id)
            if ids.count == limit { break }
        }
        return ids
    }

    // MARK: - Zeiteinträge

    func timesheets(on day: CalendarDay) async throws -> [TimesheetEntry] {
        let rows = try await call("account.analytic.line", "search_read", [
            "domain": [["user_id", "=", .int(uid)], ["project_id", "!=", false], ["date", "=", .string(day.odooString)]],
            "fields": ["name", "project_id", "task_id", "unit_amount"],
            "order": "id asc",
        ])
        return rows.arrayValue?.compactMap { row in
            guard let id = row["id"]?.intValue else { return nil }
            let name = row["name"]?.stringValue ?? ""
            return TimesheetEntry(
                id: id,
                description: name == "/" ? "" : name,
                project: row["project_id"]?.reference,
                task: row["task_id"]?.reference,
                minutes: Int(((row["unit_amount"]?.doubleValue ?? 0) * 60).rounded())
            )
        } ?? []
    }

    /// Legt einen Zeiteintrag an. Den Mitarbeiter wählt Odoo selbst passend zur Firma des Projekts.
    @discardableResult
    func createTimesheet(_ draft: TimesheetDraft) async throws -> Int {
        var values: [String: JSONValue] = [
            "project_id": .int(draft.projectID),
            "name": .string(draft.description.isEmpty ? "/" : draft.description),
            "unit_amount": .number(Double(draft.minutes) / 60),
            "date": .string(draft.day.odooString),
        ]
        if let taskID = draft.taskID { values["task_id"] = .int(taskID) }
        let result = try await call("account.analytic.line", "create", ["vals_list": [.object(values)]],
                                    positional: ["vals_list"])
        return result.arrayValue?.first?.intValue ?? result.intValue ?? 0
    }

    // MARK: - Anwesenheit

    /// Eigene Anwesenheiten, die an diesem Tag (Ortszeit) begonnen haben.
    func attendances(on day: CalendarDay, calendar: Calendar = .gregorianLocal) async throws -> [AttendancePeriod] {
        let start = day.startDate(calendar: calendar)
        let end = day.adding(days: 1, calendar: calendar).startDate(calendar: calendar)
        let rows = try await call("hr.attendance", "search_read", [
            "domain": [
                ["employee_id.user_id", "=", .int(uid)],
                ["check_in", ">=", .string(OdooDateTime.string(from: start))],
                ["check_in", "<", .string(OdooDateTime.string(from: end))],
            ],
            "fields": ["check_in", "check_out"],
            "order": "check_in asc",
        ])
        return Self.periods(from: rows)
    }

    /// Die laufende Anwesenheit, falls eingestempelt.
    func openAttendance() async throws -> AttendancePeriod? {
        let rows = try await call("hr.attendance", "search_read", [
            "domain": [["employee_id.user_id", "=", .int(uid)], ["check_out", "=", false]],
            "fields": ["check_in", "check_out"],
            "order": "check_in desc",
            "limit": 1,
        ])
        return Self.periods(from: rows).first
    }

    func checkIn(employeeID: Int, at date: Date) async throws {
        let values: JSONValue = ["employee_id": .int(employeeID), "check_in": .string(OdooDateTime.string(from: date))]
        _ = try await call("hr.attendance", "create", ["vals_list": [values]], positional: ["vals_list"])
    }

    func checkOut(attendanceID: Int, at date: Date) async throws {
        _ = try await call("hr.attendance", "write", ids: [attendanceID],
                           ["vals": ["check_out": .string(OdooDateTime.string(from: date))]])
    }

    private static func periods(from rows: JSONValue) -> [AttendancePeriod] {
        rows.arrayValue?.compactMap { row in
            guard let id = row["id"]?.intValue,
                  let checkIn = row["check_in"]?.stringValue.flatMap(OdooDateTime.date(from:)) else { return nil }
            return AttendancePeriod(id: id, checkIn: checkIn,
                                    checkOut: row["check_out"]?.stringValue.flatMap(OdooDateTime.date(from:)))
        } ?? []
    }
}
