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

    /// - Parameter attendanceEmployeeID: In den Einstellungen gewählter Mitarbeiter zum Stempeln, falls
    ///   der Benutzer in mehreren Firmen einen hat. Sonst stempelt die App mit dem der Hauptfirma.
    func discoverCapabilities(attendanceEmployeeID: Int? = nil) async throws -> Capabilities {
        let user = try await call("res.users", "read", ids: [uid], ["fields": ["name", "company_id", "company_ids"]])
        let userRecord = user.arrayValue?.first
        let userName = userRecord?["name"]?.stringValue ?? ""
        let mainCompanyID = userRecord?["company_id"]?.reference?.id
        let companyIDs = userRecord?["company_ids"]?.arrayValue?.compactMap(\.intValue) ?? []

        // Mitarbeiter: Felder aus der Odoo-App „Mitarbeiter“, auf die Zeiterfassung und Anwesenheiten aufbauen.
        // `employee_id` ist der Mitarbeiter in der Hauptfirma.
        var employeeID: Int?
        var hasEmployee = false
        if let employee = try? await call("res.users", "read", ids: [uid], ["fields": ["employee_id", "employee_ids"]]),
           let record = employee.arrayValue?.first {
            employeeID = record["employee_id"]?.reference?.id
            hasEmployee = employeeID != nil || !(record["employee_ids"]?.arrayValue?.isEmpty ?? true)
        }
        var organization: Organization?
        if hasEmployee, companyIDs.count > 1 {
            organization = await self.organization(companyIDs: companyIDs, mainCompanyID: mainCompanyID)
        }
        if let attendanceEmployeeID, organization?.employees.contains(where: { $0.id == attendanceEmployeeID }) == true {
            employeeID = attendanceEmployeeID
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
        if timesheets == .available, let lineFields {
            schema.projectHasTemplates = try await fieldNames(of: "project.project")?.contains("is_template") ?? false
            schema.taskHasIsClosed = try await fieldNames(of: "project.task")?.contains("is_closed") ?? false
            schema.lineHasInvoice = lineFields.contains("timesheet_invoice_id")
            schema.lineHasValidated = lineFields.contains("validated")
        }
        if attendance == .available, let attendanceFields {
            schema.attendanceHasModes = attendanceFields.contains("in_mode") && attendanceFields.contains("out_mode")
            if attendanceFields.contains("arbzg_missing_break") {
                // Die Regeln gelten je Firma, hier für die, in der gestempelt wird.
                let companyID = organization?.employees.first { $0.id == employeeID }?.companyID ?? mainCompanyID
                schema.breakRules = await breakRules(companyID: companyID)
            }
        }

        return Capabilities(userName: userName, timesheets: timesheets, attendance: attendance, canStamp: canStamp,
                            employeeID: employeeID, schema: schema, organization: organization)
    }

    /// Firmen und Mitarbeiter des Benutzers. Die Mitarbeiter anderer Firmen stehen nicht in
    /// `res.users.employee_ids`, deshalb die Suche über `hr.employee`; deren Felder `company_id`
    /// und `user_id` darf auch lesen, wer keine Rechte für die Personalverwaltung hat.
    private func organization(companyIDs: [Int], mainCompanyID: Int?) async -> Organization? {
        guard let companyRows = try? await call("res.company", "read", ids: companyIDs, ["fields": ["name"]]),
              let employeeRows = try? await call("hr.employee", "search_read", [
                  "domain": [["user_id", "=", .int(uid)]], "fields": ["company_id"], "order": "id asc",
              ]) else { return nil }
        var companies = companyRows.arrayValue?.compactMap { row -> Organization.Company? in
            guard let id = row["id"]?.intValue else { return nil }
            return Organization.Company(id: id, name: row["name"]?.stringValue ?? "")
        } ?? []
        if let index = companies.firstIndex(where: { $0.id == mainCompanyID }) {
            companies.insert(companies.remove(at: index), at: 0)
        }
        var employees: [Organization.Employee] = []
        for row in employeeRows.arrayValue ?? [] {
            guard let id = row["id"]?.intValue, let companyID = row["company_id"]?.reference?.id,
                  !employees.contains(where: { $0.companyID == companyID }) else { continue }
            employees.append(Organization.Employee(id: id, companyID: companyID))
        }
        guard companies.count > 1 else { return nil }
        return Organization(companies: companies, employees: employees)
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

    /// Pausenregeln einer Firma aus dem Modul Arbeitszeitgesetz. Lassen sie sich nicht lesen,
    /// gelten die gesetzlichen Werte, mit denen das Modul ausgeliefert wird.
    private func breakRules(companyID: Int?) async -> BreakRules {
        var rules = BreakRules()
        guard let companyID,
              let rows = try? await call("res.company", "read", ids: [companyID], ["fields": [
                  "arbzg_break_hours_1", "arbzg_break_minutes_1", "arbzg_break_hours_2", "arbzg_break_minutes_2",
                  "arbzg_min_break_minutes", "arbzg_max_hours",
              ]]),
              let company = rows.arrayValue?.first else { return rules }
        func minutes(fromHours key: String) -> Int? { company[key]?.doubleValue.map { Int(($0 * 60).rounded()) } }
        rules.firstThreshold = minutes(fromHours: "arbzg_break_hours_1") ?? rules.firstThreshold
        rules.firstBreak = company["arbzg_break_minutes_1"]?.intValue ?? rules.firstBreak
        rules.secondThreshold = minutes(fromHours: "arbzg_break_hours_2") ?? rules.secondThreshold
        rules.secondBreak = company["arbzg_break_minutes_2"]?.intValue ?? rules.secondBreak
        rules.minimumGap = company["arbzg_min_break_minutes"]?.intValue ?? rules.minimumGap
        rules.maximumWork = minutes(fromHours: "arbzg_max_hours") ?? rules.maximumWork
        return rules
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
                                  ["domain": .array(domain), "fields": ["display_name", "company_id"], "order": "name asc, id asc"])
        return rows.arrayValue?.compactMap { row in
            guard let id = row["id"]?.intValue else { return nil }
            return Project(id: id, name: row["display_name"]?.stringValue ?? "", companyID: row["company_id"]?.reference?.id)
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
        var fields: [JSONValue] = ["name", "project_id", "task_id", "unit_amount", "date", "company_id", "employee_id"]
        if schema.lineHasInvoice { fields.append("timesheet_invoice_id") }
        if schema.lineHasValidated { fields.append("validated") }
        let rows = try await call("account.analytic.line", "search_read", [
            "domain": [["user_id", "=", .int(uid)], ["project_id", "!=", false], ["date", "=", .string(day.odooString)]],
            "fields": .array(fields),
            "order": "id asc",
        ])
        return rows.arrayValue?.compactMap { row in
            guard let id = row["id"]?.intValue else { return nil }
            let name = row["name"]?.stringValue ?? ""
            var lock: TimesheetEntry.Lock?
            if row["validated"]?.boolValue == true {
                lock = .validated
            } else if row["timesheet_invoice_id"]?.reference != nil {
                lock = .invoiced
            }
            return TimesheetEntry(
                id: id,
                description: name == "/" ? "" : name,
                project: row["project_id"]?.reference,
                task: row["task_id"]?.reference,
                minutes: Int(((row["unit_amount"]?.doubleValue ?? 0) * 60).rounded()),
                day: row["date"]?.stringValue.flatMap(CalendarDay.init(odooString:)) ?? day,
                lock: lock,
                companyID: row["company_id"]?.reference?.id,
                employeeID: row["employee_id"]?.reference?.id
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

    /// Ändert einen Zeiteintrag. Bei einem abgerechneten nur die Beschreibung; den Rest lehnt Odoo ab.
    /// - Parameter employeeID: Neuer Mitarbeiter, wenn das Projekt in eine andere Firma wechselt. Odoo
    ///   übernimmt dann die Firma des Projekts, behält aber sonst den Mitarbeiter der alten Firma.
    func updateTimesheet(id: Int, to draft: TimesheetDraft, descriptionOnly: Bool = false,
                         employeeID: Int? = nil) async throws {
        var values: [String: JSONValue] = ["name": .string(draft.description.isEmpty ? "/" : draft.description)]
        if !descriptionOnly {
            values["project_id"] = .int(draft.projectID)
            values["task_id"] = draft.taskID.map(JSONValue.int) ?? false
            values["unit_amount"] = .number(Double(draft.minutes) / 60)
            values["date"] = .string(draft.day.odooString)
            if let employeeID { values["employee_id"] = .int(employeeID) }
        }
        _ = try await write("account.analytic.line", id: id, values)
    }

    /// `write` mit den Werten als Position: Bis Odoo 18 heißt der Parameter in manchen Modellen nicht
    /// `vals`, sondern `values` (etwa bei Zeiteinträgen), über JSON-2 dagegen immer `vals`.
    private func write(_ model: String, id: Int, _ values: [String: JSONValue]) async throws -> JSONValue {
        try await call(model, "write", ids: [id], ["vals": .object(values)], positional: ["vals"])
    }

    func deleteTimesheet(id: Int) async throws {
        _ = try await call("account.analytic.line", "unlink", ids: [id])
    }

    // MARK: - Anwesenheit

    /// Eigene Anwesenheiten, die an diesem Tag (Ortszeit) begonnen haben.
    /// - Parameter employeeID: Der Mitarbeiter, mit dem gestempelt wird; ohne ihn alle des Benutzers.
    func attendances(on day: CalendarDay, employeeID: Int? = nil,
                     calendar: Calendar = .gregorianLocal) async throws -> [AttendancePeriod] {
        let start = day.startDate(calendar: calendar)
        let end = day.adding(days: 1, calendar: calendar).startDate(calendar: calendar)
        let rows = try await call("hr.attendance", "search_read", [
            "domain": [
                attendanceOwner(employeeID),
                ["check_in", ">=", .string(OdooDateTime.string(from: start))],
                ["check_in", "<", .string(OdooDateTime.string(from: end))],
            ],
            "fields": attendanceFields,
            "order": "check_in asc",
        ])
        return Self.periods(from: rows)
    }

    /// Die laufende Anwesenheit, falls eingestempelt.
    func openAttendance(employeeID: Int? = nil) async throws -> AttendancePeriod? {
        let rows = try await call("hr.attendance", "search_read", [
            "domain": [attendanceOwner(employeeID), ["check_out", "=", false]],
            "fields": attendanceFields,
            "order": "check_in desc",
            "limit": 1,
        ])
        return Self.periods(from: rows).first
    }

    private func attendanceOwner(_ employeeID: Int?) -> JSONValue {
        employeeID.map { ["employee_id", "=", .int($0)] } ?? ["employee_id.user_id", "=", .int(uid)]
    }

    private var attendanceFields: JSONValue {
        schema.attendanceHasModes ? ["check_in", "check_out", "in_mode", "out_mode"] : ["check_in", "check_out"]
    }

    func checkIn(employeeID: Int, at date: Date) async throws {
        let values: JSONValue = ["employee_id": .int(employeeID), "check_in": .string(OdooDateTime.string(from: date))]
        _ = try await call("hr.attendance", "create", ["vals_list": [values]], positional: ["vals_list"])
    }

    func checkOut(attendanceID: Int, at date: Date) async throws {
        _ = try await write("hr.attendance", id: attendanceID, ["check_out": .string(OdooDateTime.string(from: date))])
    }

    /// Trägt eine vergessene Anwesenheit nach.
    func addAttendance(employeeID: Int, from checkIn: Date, to checkOut: Date) async throws {
        let values: JSONValue = ["employee_id": .int(employeeID), "check_in": .string(OdooDateTime.string(from: checkIn)),
                                 "check_out": .string(OdooDateTime.string(from: checkOut))]
        _ = try await call("hr.attendance", "create", ["vals_list": [values]], positional: ["vals_list"])
    }

    /// Korrigiert eine Anwesenheit. Was nicht angegeben ist, bleibt. Wer Zeiten selbst korrigiert, hat
    /// sie bestätigt: `manual` statt „automatisch ausgestempelt“ oder „von Odoo eingefügt“.
    func updateAttendance(id: Int, checkIn: Date? = nil, checkOut: Date? = nil,
                          confirmsCheckIn: Bool = false, confirmsCheckOut: Bool = false) async throws {
        var values: [String: JSONValue] = [:]
        if let checkIn { values["check_in"] = .string(OdooDateTime.string(from: checkIn)) }
        if let checkOut { values["check_out"] = .string(OdooDateTime.string(from: checkOut)) }
        if schema.attendanceHasModes {
            if confirmsCheckIn { values["in_mode"] = "manual" }
            if confirmsCheckOut { values["out_mode"] = "manual" }
        }
        guard !values.isEmpty else { return }
        _ = try await write("hr.attendance", id: id, values)
    }

    func deleteAttendance(id: Int) async throws {
        _ = try await call("hr.attendance", "unlink", ids: [id])
    }

    private static func periods(from rows: JSONValue) -> [AttendancePeriod] {
        rows.arrayValue?.compactMap { row in
            guard let id = row["id"]?.intValue,
                  let checkIn = row["check_in"]?.stringValue.flatMap(OdooDateTime.date(from:)) else { return nil }
            let period = AttendancePeriod(id: id, checkIn: checkIn,
                                          checkOut: row["check_out"]?.stringValue.flatMap(OdooDateTime.date(from:)),
                                          inMode: row["in_mode"]?.stringValue, outMode: row["out_mode"]?.stringValue)
            // Die Abwesenheitserkennung von Odoo legt für Tage ohne Anwesenheit Einträge von einer
            // Sekunde an (beide Seiten „technical“). Das ist keine Anwesenheit.
            if period.isTechnical, period.outMode == "technical", let checkOut = period.checkOut,
               checkOut.timeIntervalSince(checkIn) < 60 {
                return nil
            }
            return period
        } ?? []
    }
}
