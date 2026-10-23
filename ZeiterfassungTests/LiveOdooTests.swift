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
/// Nie gegen eine Datenbank mit echten Daten laufen lassen.
struct LiveConfig {
    let url: URL
    let apiKey: String
    let login: String?
    let database: String?

    static let current: LiveConfig? = {
        let environment = ProcessInfo.processInfo.environment
        guard let text = environment["ZEITERFASSUNG_LIVE_URL"], let url = URL(string: text),
              let apiKey = environment["ZEITERFASSUNG_LIVE_KEY"], !apiKey.isEmpty else { return nil }
        return LiveConfig(url: url, apiKey: apiKey, login: environment["ZEITERFASSUNG_LIVE_LOGIN"],
                          database: environment["ZEITERFASSUNG_LIVE_DB"])
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

    @Test("JSON-2: anmelden, Funktionen, buchen, lesen")
    func json2RoundTrip() async throws {
        let session = try await Connector(http: http).connect(serverURL: config.url, apiKey: config.apiKey,
                                                              login: nil, database: config.database)
        #expect(session.interface == .json2)
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

        if found.attendance == .available, found.canStamp, let employeeID = found.employeeID {
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
}
