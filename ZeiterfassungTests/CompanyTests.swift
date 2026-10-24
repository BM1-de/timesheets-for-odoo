// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Zeiterfassung

@MainActor
@Suite("Mehrere Firmen")
struct CompanyTests {
    /// Zwei Firmen mit je einem Mitarbeiter. Projekt 3 gehört der zweiten Firma, Projekt 4 allen.
    private func twoCompanies(_ mode: FakeOdoo.Mode = .odoo19) -> FakeOdoo {
        let odoo = FakeOdoo(mode: mode)
        odoo.withLock {
            odoo.companies = [(1, "Muster Agentur GmbH"), (2, "Muster Fotostudio")]
            odoo.otherEmployees = [(id: 4, companyID: 2)]
            odoo.projectCompanies = [1: 1, 2: 1, 3: 2]
        }
        return odoo
    }

    private func service(_ odoo: FakeOdoo) -> OdooService {
        let url = URL(string: "https://odoo.example.de")!
        let transport: any OdooTransport = odoo.mode == .odoo19
            ? JSON2Transport(baseURL: url, apiKey: odoo.apiKey, database: nil, http: odoo.client())
            : JSONRPCTransport(baseURL: url, database: "demo", uid: odoo.uid, apiKey: odoo.apiKey, http: odoo.client())
        return OdooService(transport: transport, uid: odoo.uid)
    }

    private func signedIn(_ odoo: FakeOdoo, defaults: UserDefaults = ScratchDefaults.make("zeiterfassung-tests")) async throws -> AppModel {
        let model = AppModel(preferences: Preferences(defaults: defaults), http: odoo.client(), secrets: MemorySecretStore(),
                             calendar: TestClock.calendar, clock: { TestClock.now })
        try await model.signIn(server: "odoo.example.de", apiKey: odoo.apiKey,
                               login: odoo.mode == .odoo19 ? nil : odoo.login, database: nil)
        model.finishSignIn()
        await model.refresh(force: true)
        return model
    }

    private func line(_ odoo: FakeOdoo, _ id: Int) -> FakeOdoo.Line? {
        odoo.withLock { odoo.lines.first { $0.id == id } }
    }

    @Test("erkennt Firmen und Mitarbeiter je Firma, die Hauptfirma zuerst", arguments: [FakeOdoo.Mode.odoo19, .odoo18, .odoo17])
    func discoversOrganization(mode: FakeOdoo.Mode) async throws {
        let odoo = twoCompanies(mode)
        var found = try await service(odoo).discoverCapabilities()
        let organization = try #require(found.organization)
        #expect(organization.companies.map(\.id) == [1, 2])
        #expect(organization.employees == [Organization.Employee(id: 3, companyID: 1), Organization.Employee(id: 4, companyID: 2)])
        #expect(found.employeeID == 3)

        found = try await service(odoo).discoverCapabilities(attendanceEmployeeID: 4)
        #expect(found.employeeID == 4)
        found = try await service(odoo).discoverCapabilities(attendanceEmployeeID: 99)
        #expect(found.employeeID == 3)
    }

    @Test("mit nur einer Firma bleibt alles wie bisher")
    func singleCompany() async throws {
        let odoo = FakeOdoo()
        odoo.withLock { odoo.lines = [.init(id: 1, date: "2026-10-23", name: "Plugin-Updates", projectID: 2, taskID: 21, hours: 0.25)] }
        let found = try await service(odoo).discoverCapabilities()
        #expect(found.organization == nil)
        let model = try await signedIn(odoo)
        #expect(model.entryGroups.count == 1)
        #expect(model.entryGroups.first?.title == nil)
        model.selectProject(try #require(model.projects.first { $0.id == 2 }))
        #expect(model.selectedProjectCompanyText == nil)
        #expect(model.attendanceCompanies.isEmpty)
    }

    @Test("Odoo bucht in der Firma des Projekts, mit dem Mitarbeiter dieser Firma", arguments: [FakeOdoo.Mode.odoo19, .odoo18, .odoo17])
    func booksInProjectCompany(mode: FakeOdoo.Mode) async throws {
        let odoo = twoCompanies(mode)
        let service = service(odoo)
        let projects = try await service.projects()
        #expect(projects.first { $0.id == 3 }?.companyID == 2)
        #expect(projects.first { $0.id == 4 }?.companyID == nil)

        let day = CalendarDay(year: 2026, month: 10, day: 23)
        try await service.createTimesheet(TimesheetDraft(projectID: 3, taskID: 31, description: "Bildauswahl", minutes: 60, day: day))
        let entry = try #require(try await service.timesheets(on: day).first)
        #expect(entry.companyID == 2)
        #expect(entry.employeeID == 4)
    }

    @Test("Einträge eines Tages aus zwei Firmen stehen in Gruppen mit Zwischensumme")
    func groupsEntries() async throws {
        let odoo = twoCompanies()
        odoo.withLock {
            odoo.lines = [
                .init(id: 1, date: "2026-10-23", name: "Bildauswahl", projectID: 3, taskID: 31, hours: 1, companyID: 2, employeeID: 4),
                .init(id: 2, date: "2026-10-23", name: "Plugin-Updates", projectID: 2, taskID: 21, hours: 0.25),
                .init(id: 3, date: "2026-10-23", name: "Angebot", projectID: 1, taskID: 11, hours: 2),
            ]
        }
        let model = try await signedIn(odoo)
        let groups = model.entryGroups
        #expect(groups.map(\.title) == ["Muster Agentur GmbH", "Muster Fotostudio"])
        #expect(groups.map(\.minutes) == [135, 60])
        #expect(groups.map { $0.entries.map(\.id) } == [[2, 3], [1]])
    }

    @Test("im Formular steht, in welcher Firma Odoo bucht")
    func showsBookingCompany() async throws {
        let model = try await signedIn(twoCompanies())
        model.selectProject(try #require(model.projects.first { $0.id == 3 }))
        #expect(model.selectedProjectCompanyText == "Muster Fotostudio")
        model.selectProject(try #require(model.projects.first { $0.id == 4 }))
        #expect(model.selectedProjectCompanyText == "Ohne Firma · gebucht in Muster Agentur GmbH")
        #expect(model.companyName(of: try #require(model.projects.first { $0.id == 4 })) == "Ohne Firma")
    }

    @Test("wechselt ein Eintrag die Firma, wechselt die App auch den Mitarbeiter", arguments: [FakeOdoo.Mode.odoo19, .odoo18, .odoo17])
    func switchesEmployee(mode: FakeOdoo.Mode) async throws {
        let odoo = twoCompanies(mode)
        odoo.withLock {
            odoo.lines = [.init(id: 1, date: "2026-10-23", name: "Retusche", projectID: 2, taskID: 21, hours: 1, companyID: 1, employeeID: 3)]
        }
        let model = try await signedIn(odoo)
        model.beginEditing(try #require(model.entries.first))
        model.selectProject(try #require(model.projects.first { $0.id == 3 }))
        await model.loadTasks(projectID: 3)
        model.draft.taskID = 31
        await model.save()
        #expect(model.saveError == nil)
        #expect(line(odoo, 1)?.companyID == 2)
        #expect(line(odoo, 1)?.employeeID == 4)

        // Zu einem Projekt ohne Firma: Der Eintrag bleibt in seiner Firma und bei seinem Mitarbeiter.
        model.beginEditing(try #require(model.entries.first))
        model.selectProject(try #require(model.projects.first { $0.id == 4 }))
        await model.loadTasks(projectID: 4)
        await model.save()
        #expect(model.saveError == nil)
        #expect(line(odoo, 1)?.projectID == 4)
        #expect(line(odoo, 1)?.companyID == 2)
        #expect(line(odoo, 1)?.employeeID == 4)
    }

    @Test("ohne Mitarbeiter in der Firma des Projekts sagt die App, warum es nicht geht")
    func missingEmployee() async throws {
        let odoo = twoCompanies()
        odoo.withLock {
            odoo.companies.append((5, "Muster Druck"))
            odoo.projectCompanies[1] = 5
        }
        let model = try await signedIn(odoo)
        model.selectProject(try #require(model.projects.first { $0.id == 1 }))
        await model.loadTasks(projectID: 1)
        model.draft.taskID = 11
        model.draft.durationText = "1:00"
        await model.save()
        #expect(model.saveError == "Für „Muster Druck“ gibt es keinen Mitarbeiter zu deinem Odoo-Benutzer. Wähle ein anderes Projekt oder lass dir in Odoo einen Mitarbeiter anlegen.")
        #expect(odoo.withLock { odoo.lines.isEmpty })
        #expect(!odoo.log.contains("account.analytic.line.create"))
    }

    @Test("Stempeln für eine andere Firma: deren Mitarbeiter, deren Anwesenheiten")
    func attendanceCompany() async throws {
        let odoo = twoCompanies()
        odoo.withLock {
            odoo.attendances = [.init(id: 1, checkIn: "2026-10-23 06:12:00", checkOut: "2026-10-23 10:05:00")]
        }
        let defaults = ScratchDefaults.make("zeiterfassung-tests")
        let model = try await signedIn(odoo, defaults: defaults)
        #expect(model.attendanceCompanies.map(\.id) == [1, 2])
        #expect(model.attendanceCompanyID == 1)
        #expect(model.shownPeriods.map(\.id) == [1])

        await model.setAttendanceCompany(2)
        #expect(model.capabilities?.employeeID == 4)
        #expect(model.attendanceCompanyID == 2)
        #expect(model.preferences.attendanceEmployeeID == 4)
        #expect(model.shownPeriods.isEmpty)
        await model.toggleAttendance()
        #expect(odoo.withLock { odoo.attendances.last?.employeeID } == 4)

        // Nach einem Neustart gilt die Wahl weiter.
        let restarted = AppModel(preferences: Preferences(defaults: defaults), http: odoo.client(), secrets: MemorySecretStore(),
                                 calendar: TestClock.calendar, clock: { TestClock.now })
        #expect(restarted.preferences.attendanceEmployeeID == 4)

        await model.setAttendanceCompany(1)
        #expect(model.capabilities?.employeeID == 3)
        #expect(model.preferences.attendanceEmployeeID == nil)
    }
}
