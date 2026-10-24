// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Zeiterfassung

@Suite("Datenzugriff")
struct OdooServiceTests {
    private func service(_ odoo: FakeOdoo) -> OdooService {
        let url = URL(string: "https://odoo.example.de")!
        let transport: any OdooTransport = odoo.mode == .odoo19
            ? JSON2Transport(baseURL: url, apiKey: odoo.apiKey, database: nil, http: odoo.client())
            : JSONRPCTransport(baseURL: url, database: "demo", uid: odoo.uid, apiKey: odoo.apiKey, http: odoo.client())
        return OdooService(transport: transport, uid: odoo.uid)
    }

    @Test("erkennt beide Funktionen und das Recht zu stempeln", arguments: [FakeOdoo.Mode.odoo19, .odoo18, .odoo17])
    func discoversEverything(mode: FakeOdoo.Mode) async throws {
        let odoo = FakeOdoo(mode: mode)
        let found = try await service(odoo).discoverCapabilities()
        #expect(found.userName == "Erika Mustermann")
        #expect(found.timesheets == .available)
        #expect(found.attendance == .available)
        #expect(found.canStamp)
        #expect(found.employeeID == 3)
        #expect(found.schema.taskHasIsClosed)
        #expect(found.schema.projectHasTemplates == (mode != .odoo17))
    }

    @Test("ohne Odoo-App Anwesenheiten", arguments: [FakeOdoo.Mode.odoo19, .odoo18, .odoo17])
    func attendanceMissing(mode: FakeOdoo.Mode) async throws {
        let odoo = FakeOdoo(mode: mode)
        odoo.attendanceInstalled = false
        let found = try await service(odoo).discoverCapabilities()
        #expect(found.timesheets == .available)
        #expect(found.attendance == .notInstalled)
        #expect(!found.canStamp)
    }

    @Test("ohne verknüpften Mitarbeiter und ohne Recht zu stempeln")
    func noEmployeeNoStamp() async throws {
        let odoo = FakeOdoo()
        odoo.employeeID = nil
        var found = try await service(odoo).discoverCapabilities()
        #expect(found.timesheets == .noEmployee)
        #expect(found.attendance == .noEmployee)

        odoo.employeeID = 3
        odoo.canStamp = false
        found = try await service(odoo).discoverCapabilities()
        #expect(found.attendance == .available)
        #expect(!found.canStamp)
    }

    @Test("legt einen Zeiteintrag an und liest ihn wieder", arguments: [FakeOdoo.Mode.odoo19, .odoo18, .odoo17])
    func createsAndReadsTimesheet(mode: FakeOdoo.Mode) async throws {
        let odoo = FakeOdoo(mode: mode)
        let service = service(odoo)
        let day = CalendarDay(year: 2026, month: 10, day: 23)
        let id = try await service.createTimesheet(
            TimesheetDraft(projectID: 2, taskID: 21, description: "Plugin-Updates", minutes: 45, day: day)
        )
        #expect(id > 0)
        let line = try #require(odoo.withLock { odoo.lines.first })
        #expect(line.hours == 0.75)
        #expect(line.date == "2026-10-23")
        #expect(line.taskID == 21)

        let entries = try await service.timesheets(on: day)
        #expect(entries.count == 1)
        #expect(entries[0].minutes == 45)
        #expect(entries[0].description == "Plugin-Updates")
        #expect(entries[0].path == "Website-Betreuung (Muster GmbH) › Wartung")
        #expect(try await service.timesheets(on: day.adding(days: 1)).isEmpty)
    }

    @Test("leere Beschreibung wird zu „/“ und zurück")
    func emptyDescription() async throws {
        let odoo = FakeOdoo()
        let service = service(odoo)
        let day = CalendarDay(year: 2026, month: 10, day: 23)
        try await service.createTimesheet(TimesheetDraft(projectID: 4, taskID: nil, description: "", minutes: 15, day: day))
        #expect(odoo.withLock { odoo.lines.first?.name } == "/")
        #expect(odoo.withLock { odoo.lines.first?.taskID } == nil)
        #expect(try await service.timesheets(on: day).first?.description == "")
    }

    @Test("stempelt ein und aus", arguments: [FakeOdoo.Mode.odoo19, .odoo18, .odoo17])
    func stamps(mode: FakeOdoo.Mode) async throws {
        let odoo = FakeOdoo(mode: mode)
        let service = service(odoo)
        let checkIn = TestClock.now.addingTimeInterval(-3600)
        try await service.checkIn(employeeID: 3, at: checkIn)
        let open = try #require(try await service.openAttendance())
        #expect(open.checkIn == checkIn)
        #expect(open.isOpen)

        try await service.checkOut(attendanceID: open.id, at: TestClock.now)
        #expect(try await service.openAttendance() == nil)
        let today = try await service.attendances(on: CalendarDay(date: TestClock.now, calendar: TestClock.calendar),
                                                  calendar: TestClock.calendar)
        #expect(today.count == 1)
        #expect(today[0].minutes(until: TestClock.now) == 60)
    }

    @Test("Odoos eigene Einträge von einer Sekunde zählen nicht als Anwesenheit")
    func skipsTechnicalEntries() async throws {
        let odoo = FakeOdoo()
        odoo.withLock {
            odoo.attendances = [
                .init(id: 1, checkIn: "2026-10-23 06:00:00", checkOut: "2026-10-23 06:00:01", inMode: "technical", outMode: "technical"),
                .init(id: 2, checkIn: "2026-10-23 07:00:00", checkOut: "2026-10-23 11:00:00", inMode: "technical", outMode: "manual"),
            ]
        }
        let periods = try await service(odoo).attendances(on: CalendarDay(year: 2026, month: 10, day: 23),
                                                          calendar: TestClock.calendar)
        #expect(periods.map(\.id) == [2])
        #expect(periods.first?.isTechnical == true)
    }

    @Test("gemerkte Funktionen der Version 0.1.0 lassen sich weiter lesen")
    func decodesOldCapabilities() throws {
        let json = #"{"userName":"Erika","timesheets":"available","attendance":"available","canStamp":true,"employeeID":3,"schema":{"projectHasTemplates":true,"taskHasIsClosed":true}}"#
        let capabilities = try JSONDecoder().decode(Capabilities.self, from: Data(json.utf8))
        #expect(capabilities.schema.projectHasTemplates)
        #expect(!capabilities.schema.lineHasInvoice)
        #expect(capabilities.schema.breakRules == nil)
        #expect(capabilities.organization == nil)
    }

    @Test("Projekte, Aufgaben und zuletzt verwendete")
    func projectsAndTasks() async throws {
        let odoo = FakeOdoo()
        let service = service(odoo)
        #expect(try await service.projects().map(\.name).contains("Interne Arbeiten"))
        #expect(try await service.tasks(projectID: 3).map(\.name) == ["Text", "Layout"])
        #expect(try await service.tasks(projectID: 4).isEmpty)

        let today = CalendarDay(year: 2026, month: 10, day: 23)
        for (project, day) in [(3, 20), (1, 21), (3, 22), (2, 23)] {
            try await service.createTimesheet(TimesheetDraft(projectID: project, taskID: nil, description: "x", minutes: 15,
                                                              day: CalendarDay(year: 2026, month: 10, day: day)))
        }
        #expect(try await service.recentProjectIDs(since: today.adding(days: -30)) == [2, 3, 1])
    }
}
