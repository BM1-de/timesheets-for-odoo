// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

struct Project: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    /// Firma des Projekts; `nil`, wenn es allen Firmen gehört.
    var companyID: Int?
}

struct ProjectTask: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
}

/// Ein Zeiteintrag (`account.analytic.line` mit Projekt).
struct TimesheetEntry: Identifiable, Hashable, Sendable {
    /// Warum Odoo einen Eintrag nicht mehr ändern lässt.
    enum Lock: Hashable, Sendable {
        /// Abgerechnet (`timesheet_invoice_id`): Dauer, Datum, Projekt und Aufgabe stehen fest,
        /// löschen geht nicht, die Beschreibung bleibt änderbar.
        case invoiced
        /// Freigegeben (`validated`, Odoo Enterprise): nur noch die Freigebenden dürfen ändern.
        case validated
    }

    let id: Int
    let description: String
    let project: Reference?
    let task: Reference?
    let minutes: Int
    var day: CalendarDay?
    var lock: Lock?
    /// Firma, in der Odoo den Eintrag führt, und der Mitarbeiter, auf den er gebucht ist.
    var companyID: Int?
    var employeeID: Int?

    /// „Projekt › Aufgabe“ für die Liste.
    var path: String {
        [project?.name, task?.name].compactMap { $0 }.joined(separator: " › ")
    }
}

/// Neuer Zeiteintrag, wie er an Odoo geht.
struct TimesheetDraft: Sendable, Equatable {
    var projectID: Int
    var taskID: Int?
    var description: String
    var minutes: Int
    var day: CalendarDay
}

/// Eine Anwesenheit (`hr.attendance`): eingestempelt bis ausgestempelt.
struct AttendancePeriod: Identifiable, Hashable, Sendable {
    let id: Int
    let checkIn: Date
    let checkOut: Date?
    /// Wie ein- und ausgestempelt wurde (`in_mode`, `out_mode`, ab Odoo 17), etwa `manual`.
    var inMode: String?
    var outMode: String?

    var isOpen: Bool { checkOut == nil }

    /// Odoo hat selbst ausgestempelt (ab Odoo 18, „Automatisch abmelden“ in den Einstellungen).
    var isAutoCheckOut: Bool { outMode == "auto_check_out" }

    /// Von Odoo angelegt statt gestempelt. Mit dem Modul Arbeitszeitgesetz ist das der zweite Teil
    /// einer Anwesenheit, in die Odoo die gesetzliche Pause eingefügt hat.
    var isTechnical: Bool { inMode == "technical" }

    /// Dauer in Minuten; läuft die Anwesenheit noch, bis `now`.
    func minutes(until now: Date) -> Int {
        max(0, Int(((checkOut ?? now).timeIntervalSince(checkIn) / 60).rounded(.down)))
    }
}

/// Was die App in dieser Odoo-Datenbank kann.
struct Capabilities: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case available
        /// Die Odoo-App ist nicht installiert.
        case notInstalled
        /// Der Benutzer ist mit keinem Mitarbeiter verknüpft.
        case noEmployee
        /// Kein Lesezugriff.
        case noAccess
    }

    var userName: String
    var timesheets: Status
    var attendance: Status
    /// Darf Anwesenheiten anlegen, ändern und löschen, also stempeln und korrigieren; in Odoo mit
    /// „Sachbearbeiter: Alle Anwesenheiten verwalten“ oder als eigener Anwesenheitsgenehmiger.
    var canStamp: Bool
    /// Mitarbeiter, mit dem die App stempelt: der des Benutzers in seiner Hauptfirma oder der in
    /// den Einstellungen gewählte.
    var employeeID: Int?
    var schema: Schema
    /// Firmen und Mitarbeiter, wenn der Benutzer mehr als eine Firma sehen darf.
    var organization: Organization?
}

/// Mehrere Firmen in einer Odoo-Datenbank. Odoo bucht jeden Eintrag in der Firma seines Projekts,
/// mit dem Mitarbeiter des Benutzers in dieser Firma. Eine Anwesenheit gehört zu einem Mitarbeiter
/// und damit zu einer Firma.
struct Organization: Codable, Equatable, Sendable {
    struct Company: Codable, Equatable, Sendable, Identifiable {
        let id: Int
        let name: String
    }

    struct Employee: Codable, Equatable, Sendable {
        let id: Int
        let companyID: Int
    }

    /// Die Firmen des Benutzers, die Hauptfirma zuerst.
    var companies: [Company]
    /// Die Mitarbeiter des Benutzers, höchstens einer je Firma.
    var employees: [Employee]

    var mainCompanyID: Int? { companies.first?.id }

    func company(_ id: Int?) -> Company? { companies.first { $0.id == id } }

    func employee(in companyID: Int?) -> Employee? { employees.first { $0.companyID == companyID } }

    /// Lehnt Odoo einen Eintrag auf diesem Projekt ab? Das tut es, wenn der Benutzer mehrere
    /// Mitarbeiter hat, aber keinen in der Firma des Projekts. Mit nur einem bucht Odoo auf diesen.
    func lacksEmployee(for project: Project) -> Bool {
        guard employees.count > 1, let companyID = project.companyID else { return false }
        return employee(in: companyID) == nil
    }
}

/// Felder, die es nicht in jeder Odoo-Version gibt.
struct Schema: Codable, Equatable, Sendable {
    /// `project.project.is_template` (ab Odoo 18)
    var projectHasTemplates = false
    /// `project.task.is_closed`
    var taskHasIsClosed = false
    /// `account.analytic.line.timesheet_invoice_id` (mit der Odoo-App Verkauf)
    var lineHasInvoice = false
    /// `account.analytic.line.validated` (Odoo Enterprise)
    var lineHasValidated = false
    /// `hr.attendance.in_mode` und `out_mode` (ab Odoo 17)
    var attendanceHasModes = false
    /// Pausenregeln des Moduls Arbeitszeitgesetz (`l10n_de_hr_attendance_arbzg`), falls installiert.
    var breakRules: BreakRules?

    init() {}

    /// Ältere Fassungen der App kannten nur einen Teil der Felder; was fehlt, bleibt beim Standard.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectHasTemplates = try container.decodeIfPresent(Bool.self, forKey: .projectHasTemplates) ?? false
        taskHasIsClosed = try container.decodeIfPresent(Bool.self, forKey: .taskHasIsClosed) ?? false
        lineHasInvoice = try container.decodeIfPresent(Bool.self, forKey: .lineHasInvoice) ?? false
        lineHasValidated = try container.decodeIfPresent(Bool.self, forKey: .lineHasValidated) ?? false
        attendanceHasModes = try container.decodeIfPresent(Bool.self, forKey: .attendanceHasModes) ?? false
        breakRules = try container.decodeIfPresent(BreakRules.self, forKey: .breakRules)
    }
}

/// Pausen und Höchstarbeitszeit nach dem Arbeitszeitgesetz, wie sie das Modul je Firma einstellt.
/// Die App rechnet damit nur vor; was gilt, entscheidet Odoo beim Speichern.
struct BreakRules: Codable, Equatable, Sendable {
    /// Ab so viel Arbeit (Minuten) …
    var firstThreshold = 360
    /// … so viel Pause (Minuten).
    var firstBreak = 30
    var secondThreshold = 540
    var secondBreak = 45
    /// Lücken ab dieser Länge zählen als Pause.
    var minimumGap = 15
    /// Höchstarbeitszeit am Tag
    var maximumWork = 600

    /// Fehlende Pause für `work` Minuten Arbeit mit `breaks` Minuten Pause, wie das Modul sie rechnet:
    /// Verlangt wird nur die Zeit über der Grenze; wer 6:10 Stunden arbeitet, braucht 10 Minuten.
    func missingBreak(work: Int, breaks: Int) -> (missing: Int, required: Int) {
        var work = work
        var breaks = breaks
        var missing = 0
        var required = 0
        for (threshold, needed) in [(firstThreshold, firstBreak), (secondThreshold, secondBreak)] where work > threshold {
            required = needed
            if breaks < needed {
                let part = min(needed - breaks, work - threshold)
                missing += part
                work -= part
                breaks += part
            }
        }
        return (missing, required)
    }
}
