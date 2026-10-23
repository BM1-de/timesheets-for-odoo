// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

struct Project: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
}

struct ProjectTask: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
}

/// Ein Zeiteintrag (`account.analytic.line` mit Projekt).
struct TimesheetEntry: Identifiable, Hashable, Sendable {
    let id: Int
    let description: String
    let project: Reference?
    let task: Reference?
    let minutes: Int

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

    var isOpen: Bool { checkOut == nil }

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
    /// Darf Anwesenheiten anlegen und ändern; in Odoo mit „Sachbearbeiter: Alle Anwesenheiten verwalten“
    /// oder als eigener Anwesenheitsgenehmiger.
    var canStamp: Bool
    /// Mitarbeiter des Benutzers in seiner Hauptfirma, zum Einstempeln.
    var employeeID: Int?
    var schema: Schema
}

/// Felder, die es nicht in jeder Odoo-Version gibt.
struct Schema: Codable, Equatable, Sendable {
    /// `project.project.is_template` (ab Odoo 18)
    var projectHasTemplates = false
    /// `project.task.is_closed`
    var taskHasIsClosed = false
}
