// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Zeiterfassung

/// Netz, das im Demo-Modus keine Anfrage bekommen darf.
private struct NoNetwork: HTTPClient {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        Issue.record("Anfrage ins Netz: \(request.url?.absoluteString ?? "")")
        throw OdooError.offline("Kein Netz im Test")
    }
}

@MainActor
@Suite("Demo-Modus")
struct DemoTests {
    private func makeModel(network: any HTTPClient = NoNetwork()) -> AppModel {
        let demo = DemoData.makeOdoo(now: TestClock.now, calendar: TestClock.calendar)
        return AppModel(preferences: Preferences(defaults: ScratchDefaults.make("zeiterfassung-tests")),
                        http: DemoRoutingHTTPClient(network: network, demo: demo), secrets: MemorySecretStore(),
                        calendar: TestClock.calendar, clock: { TestClock.now })
    }

    @Test("„demo“ als Server: anmelden, buchen und stempeln, ohne dass etwas ins Netz geht")
    func demo() async throws {
        let model = makeModel()
        let found = try await model.signIn(server: " Demo ", apiKey: "beliebig", login: nil, database: nil)
        #expect(found.timesheets == .available && found.attendance == .available && found.canStamp)
        #expect(model.serverDisplay == "Demo")
        #expect(model.odooWebURL == nil)
        #expect(model.preferences.loginHints?.server == "demo")

        model.finishSignIn()
        await model.refresh(force: true)
        #expect(model.entries.count == 2)
        #expect(model.bookedMinutes == 135)

        // Das Online-Shop-Projekt hat keine Aufgaben, gebucht wird aufs Projekt.
        model.selectProject(try #require(model.projects.first { $0.id == 4 }))
        await model.loadTasks(projectID: 4)
        model.draft.description = "Produktfotos"
        model.draft.durationText = "1:30"
        await model.save()
        #expect(model.saveError == nil)
        #expect(model.entries.count == 3)

        await model.toggleAttendance()
        #expect(model.stampError == nil)
        #expect(model.openPeriod != nil)
    }

    @Test("andere Server gehen weiter ins Netz")
    func otherServers() async throws {
        let odoo = FakeOdoo()
        let model = makeModel(network: odoo.client())
        try await model.signIn(server: "odoo.example.de", apiKey: odoo.apiKey, login: nil, database: nil)
        #expect(model.serverDisplay == "odoo.example.de")
        #expect(model.odooWebURL != nil)
    }

    @Test("die Daten liegen um den heutigen Tag")
    func data() {
        let demo = DemoData.makeOdoo(now: TestClock.now, calendar: TestClock.calendar)
        demo.withLock {
            #expect(demo.lines.filter { $0.date == "2026-10-23" }.count == 2)
            #expect(demo.lines.filter { $0.date == "2026-10-22" }.count == 3)
            // 08:10 Ortszeit, in Odoo als UTC
            #expect(demo.attendances.first?.checkIn == "2026-10-22 06:10:00")
            #expect(demo.attendances.allSatisfy { $0.checkOut != nil })
        }
    }
}
