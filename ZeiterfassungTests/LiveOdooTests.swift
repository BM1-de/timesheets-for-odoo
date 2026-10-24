// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Zeiterfassung

/// Tests gegen ein echtes Test-Odoo, z. B. aus `dev/start-test-odoo.sh`.
/// Sie laufen nur, wenn die Umgebungsvariablen gesetzt sind, und schreiben Testdaten:
///
///     TEST_RUNNER_ZEITERFASSUNG_LIVE_URL=http://localhost:8079 \
///     TEST_RUNNER_ZEITERFASSUNG_LIVE_KEY=… TEST_RUNNER_ZEITERFASSUNG_LIVE_LOGIN=admin \
///     TEST_RUNNER_ZEITERFASSUNG_LIVE_DB=zeiterfassung xcodebuild test …
///
/// Mit `TEST_RUNNER_ZEITERFASSUNG_LIVE_MULTI_KEY` (Benutzerin `zweifirmen` aus dem Skript) laufen
/// auch die Tests mit zwei Firmen. `TEST_RUNNER_ZEITERFASSUNG_LIVE_NO_STAMPING=1` lässt das Stempeln
/// zur aktuellen Zeit aus, etwa wenn andere Tests dasselbe Test-Odoo nutzen. Nie gegen eine
/// Datenbank mit echten Daten laufen lassen.
struct LiveConfig {
    let url: URL
    let apiKey: String
    let login: String?
    let database: String?
    let multiCompanyKey: String?
    let stampsNow: Bool

    static let current: LiveConfig? = {
        let environment = ProcessInfo.processInfo.environment
        guard let text = environment["ZEITERFASSUNG_LIVE_URL"], let url = URL(string: text),
              let apiKey = environment["ZEITERFASSUNG_LIVE_KEY"], !apiKey.isEmpty else { return nil }
        return LiveConfig(url: url, apiKey: apiKey, login: environment["ZEITERFASSUNG_LIVE_LOGIN"],
                          database: environment["ZEITERFASSUNG_LIVE_DB"],
                          multiCompanyKey: environment["ZEITERFASSUNG_LIVE_MULTI_KEY"].flatMap { $0.isEmpty ? nil : $0 },
                          stampsNow: environment["ZEITERFASSUNG_LIVE_NO_STAMPING"] == nil)
    }()
}

@Suite("Test-Odoo", .enabled(if: LiveConfig.current != nil), .serialized)
struct LiveOdooTests {
    private let config = LiveConfig.current!
    private let http = URLSessionHTTPClient.makeDefault()

    private func service(_ session: OdooSession) -> OdooService {
        OdooService(transport: session.makeTransport(apiKey: config.apiKey, http: http), uid: session.uid,
                    context: ["lang": "de_DE"])
    }

    @Test("anmelden wie die App: JSON-2, wo es das gibt, sonst JSON-RPC; Funktionen, buchen, lesen")
    func connectorRoundTrip() async throws {
        let connector = Connector(http: http)
        let session = try await connector.connect(serverURL: config.url, apiKey: config.apiKey,
                                                  login: config.login, database: config.database)
        let major = try #require(session.serverMajorVersion)
        #expect(session.interface == (major >= 19 ? .json2 : .jsonRPC))
        if session.interface == .json2 {
            // Odoo 19 braucht keinen Benutzernamen.
            let withoutLogin = try await connector.connect(serverURL: config.url, apiKey: config.apiKey, login: nil,
                                                           database: config.database)
            #expect(withoutLogin.interface == .json2)
        } else {
            // Odoo 17 und 18 kennen JSON-2 nicht (Odoo 18 leitet auf die Anmeldeseite um): Benutzername nötig.
            await #expect(throws: OdooError.loginRequired) {
                try await connector.connect(serverURL: config.url, apiKey: config.apiKey, login: nil, database: config.database)
            }
        }
        try await roundTrip(session)
    }

    @Test("JSON-RPC: dieselben Abläufe über die ältere Schnittstelle")
    func jsonRPCRoundTrip() async throws {
        let login = try #require(config.login)
        let database = try #require(config.database)
        let uidValue = try await JSONRPCTransport.call(
            baseURL: config.url, http: http, service: "common", method: "authenticate",
            arguments: [.string(database), .string(login), .string(config.apiKey), .object([:])]
        )
        let uid = try #require(uidValue.intValue)
        let session = OdooSession(serverURL: config.url, database: database, login: login, interface: .jsonRPC,
                                  uid: uid, language: "de_DE", serverMajorVersion: nil)
        try await roundTrip(session)
    }

    @Test("folgt keiner Umleitung des Servers")
    func refusesRedirect() async throws {
        // Ohne Sitzung leitet Odoo die Weboberfläche auf die Anmeldeseite um.
        var request = URLRequest(url: config.url.appending(path: "web"))
        request.httpMethod = "GET"
        do {
            _ = try await http.send(request)
            Issue.record("Die Umleitung wurde nicht gemeldet.")
        } catch OdooError.redirected(let location) {
            #expect(location.contains("/web/login"))
        }
    }

    private func roundTrip(_ session: OdooSession) async throws {
        var service = service(session)
        let found = try await service.discoverCapabilities()
        service.schema = found.schema
        #expect(found.timesheets == .available)

        let projects = try await service.projects()
        let project = try #require(projects.first)
        let tasks = try await service.tasks(projectID: project.id)
        let day = CalendarDay.today()
        let before = try await service.timesheets(on: day).count
        let marker = "Test der Mac-App \(UUID().uuidString.prefix(8))"
        let id = try await service.createTimesheet(
            TimesheetDraft(projectID: project.id, taskID: tasks.first?.id, description: marker, minutes: 15, day: day)
        )
        #expect(id > 0)
        let after = try await service.timesheets(on: day)
        #expect(after.count == before + 1)
        let entry = try #require(after.first { $0.id == id })
        #expect(entry.description == marker)
        #expect(entry.minutes == 15)
        #expect(entry.project?.id == project.id)

        let recent = try await service.recentProjectIDs(since: day.adding(days: -30))
        #expect(recent.contains(project.id))

        // Ändern und wieder löschen
        try await service.updateTimesheet(id: id, to: TimesheetDraft(projectID: project.id, taskID: tasks.first?.id,
                                                                    description: marker + " geändert", minutes: 30, day: day))
        let updated = try #require(try await service.timesheets(on: day).first { $0.id == id })
        #expect(updated.description == marker + " geändert")
        #expect(updated.minutes == 30)
        #expect(updated.lock == nil)
        #expect(updated.companyID != nil)
        try await service.deleteTimesheet(id: id)
        #expect(try await service.timesheets(on: day).contains { $0.id == id } == false)

        if found.attendance == .available, found.canStamp, let employeeID = found.employeeID {
            try await correctAttendance(service, employeeID: employeeID)
            guard config.stampsNow else { return }
            if let open = try await service.openAttendance() {
                try await service.checkOut(attendanceID: open.id, at: Date())
            }
            // Rückwirkend einstempeln könnte sich mit früheren Testläufen überschneiden, und Ein- und
            // Ausstempeln in derselben Sekunde verwirrt Odoos Prüfung auf Überschneidungen.
            try await Task.sleep(for: .seconds(1.1))
            do {
                try await service.checkIn(employeeID: employeeID, at: Date())
            } catch OdooError.accessDenied {
                // „Sachbearbeiter: Anwesenheiten verwalten“, ohne eigener Anwesenheitsgenehmiger zu sein:
                // Odoo lehnt erst beim Anlegen ab. Die App blendet das Stempeln dann aus.
                return
            }
            let open = try #require(try await service.openAttendance())
            try await Task.sleep(for: .seconds(1.1))
            try await service.checkOut(attendanceID: open.id, at: Date())
            #expect(try await service.openAttendance() == nil)
            #expect(try await service.attendances(on: day).contains { $0.id == open.id })
        }
    }

    /// Nachtragen, korrigieren und löschen, an einem Tag weit zurück, damit sich nichts mit früheren
    /// Testläufen überschneidet.
    private func correctAttendance(_ service: OdooService, employeeID: Int) async throws {
        let calendar = Calendar.gregorianLocal
        let day = CalendarDay.today().adding(days: -Int.random(in: 4000...9000))
        let start = try #require(calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day.startDate()))
        try await service.addAttendance(employeeID: employeeID, from: start, to: start.addingTimeInterval(4 * 3600))
        let added = try #require(try await service.attendances(on: day, employeeID: employeeID).first)
        #expect(added.checkIn == start)

        try await service.updateAttendance(id: added.id, checkIn: start.addingTimeInterval(-1800),
                                           checkOut: start.addingTimeInterval(5 * 3600), confirmsCheckOut: true)
        let corrected = try #require(try await service.attendances(on: day, employeeID: employeeID).first)
        #expect(corrected.checkIn == start.addingTimeInterval(-1800))
        #expect(corrected.checkOut == start.addingTimeInterval(5 * 3600))
        #expect(corrected.outMode == "manual")

        // Eine Überschneidung lehnt Odoo ab.
        await #expect(throws: OdooError.self) {
            try await service.addAttendance(employeeID: employeeID, from: start.addingTimeInterval(3600),
                                            to: start.addingTimeInterval(2 * 3600))
        }

        try await service.deleteAttendance(id: added.id)
        #expect(try await service.attendances(on: day, employeeID: employeeID).isEmpty)
    }

    @Test("mehrere Firmen: Odoo bucht in der Firma des Projekts, die App stellt beim Ändern den Mitarbeiter um",
          .enabled(if: LiveConfig.current?.multiCompanyKey != nil))
    func multiCompany() async throws {
        let key = try #require(config.multiCompanyKey)
        let session = try await Connector(http: http).connect(serverURL: config.url, apiKey: key, login: nil,
                                                              database: config.database)
        var service = OdooService(transport: session.makeTransport(apiKey: key, http: http), uid: session.uid,
                                  context: ["lang": "de_DE"])
        let found = try await service.discoverCapabilities()
        service.schema = found.schema
        let organization = try #require(found.organization)
        #expect(organization.companies.count == 2)
        #expect(organization.employees.count == 2)
        #expect(found.employeeID == organization.employee(in: organization.mainCompanyID)?.id)

        let projects = try await service.projects()
        let photo = try #require(projects.first { $0.name == "Fotoprojekt" })
        let shared = try #require(projects.first { $0.name == "Gemeinsames Projekt" })
        let main = try #require(projects.first { $0.companyID == organization.mainCompanyID })
        #expect(photo.companyID == organization.companies.last?.id)
        #expect(shared.companyID == nil)

        let day = CalendarDay.today()
        let draft = TimesheetDraft(projectID: photo.id, taskID: nil, description: "Test zweier Firmen", minutes: 15, day: day)
        let id = try await service.createTimesheet(draft)
        var entry = try #require(try await service.timesheets(on: day).first { $0.id == id })
        #expect(entry.companyID == photo.companyID)
        #expect(entry.employeeID == organization.employee(in: photo.companyID)?.id)

        let mainEmployee = organization.employee(in: organization.mainCompanyID)?.id
        var moved = draft
        moved.projectID = main.id
        try await service.updateTimesheet(id: id, to: moved, employeeID: mainEmployee)
        entry = try #require(try await service.timesheets(on: day).first { $0.id == id })
        #expect(entry.companyID == organization.mainCompanyID)
        #expect(entry.employeeID == mainEmployee)

        // Ein Projekt für alle Firmen lässt den Eintrag in seiner Firma.
        moved.projectID = shared.id
        try await service.updateTimesheet(id: id, to: moved)
        entry = try #require(try await service.timesheets(on: day).first { $0.id == id })
        #expect(entry.companyID == organization.mainCompanyID)
        try await service.deleteTimesheet(id: id)
    }
}
