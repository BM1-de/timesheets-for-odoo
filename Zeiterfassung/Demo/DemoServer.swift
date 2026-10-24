// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Ausprobieren ohne eigenes Odoo: Wer als Server „demo“ einträgt, arbeitet mit erfundenen Daten,
/// die nur im Arbeitsspeicher liegen. So prüft auch Apple die App, bevor sie in den App Store kommt.
enum DemoServer {
    /// Die Endung `.invalid` ist reserviert und kommt im Netz nie vor; keine Anfrage verlässt den Mac.
    static let url = URL(string: "https://demo.invalid")!
    /// Der Demo-Server nimmt diesen Schlüssel, gleich was im Feld steht.
    static let apiKey = "demo"

    static func isRequested(_ server: String) -> Bool {
        server.trimmed.caseInsensitiveCompare("demo") == .orderedSame
    }

    static func isDemo(_ serverURL: URL) -> Bool {
        serverURL.host() == url.host()
    }
}

/// Anfragen an den Demo-Server beantwortet ein Odoo im Arbeitsspeicher, alle anderen gehen ins Netz.
struct DemoRoutingHTTPClient: HTTPClient {
    let network: any HTTPClient
    let demo: FakeOdoo

    init(network: any HTTPClient, demo: FakeOdoo = DemoData.makeOdoo()) {
        self.network = network
        self.demo = demo
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, DemoServer.isDemo(url) else { return try await network.send(request) }
        return StubHTTPClient.response(to: request, with: try demo.reply(to: request))
    }
}

/// Erfundene Projekte, Aufgaben und Einträge für den Demo-Modus, in der Sprache der App: gestern ein
/// voller Arbeitstag mit einem schon abgerechneten Eintrag, heute zwei Einträge und noch nicht
/// eingestempelt. Was man einträgt, ändert oder stempelt, bleibt bis zum Beenden der App erhalten.
enum DemoData {
    static func makeOdoo(now: Date = Date(), calendar: Calendar = .gregorianLocal) -> FakeOdoo {
        let today = CalendarDay(date: now, calendar: calendar)
        let yesterday = today.adding(days: -1, calendar: calendar)
        func time(_ day: CalendarDay, _ hour: Int, _ minute: Int) -> String {
            let start = day.startDate(calendar: calendar)
            return OdooDateTime.string(from: calendar.date(bySettingHour: hour, minute: minute, second: 0, of: start) ?? start)
        }

        let odoo = FakeOdoo(mode: .odoo19)
        odoo.withLock {
            odoo.apiKey = DemoServer.apiKey
            odoo.logsCalls = false
            odoo.userName = String(localized: "Erika Mustermann")
            odoo.projects = [
                (1, String(localized: "Interne Arbeiten")),
                (2, String(localized: "Website-Betreuung (Muster GmbH)")),
                (3, String(localized: "Kundenmagazin (Beispiel AG)")),
                (4, String(localized: "Online-Shop (Demo KG)")),
                (5, String(localized: "Website-Relaunch (Musterhaus GmbH)")),
                (6, String(localized: "Social Media (Café Beispiel)")),
            ]
            // Das Online-Shop-Projekt hat keine Aufgaben: Dort bucht die App aufs Projekt.
            odoo.tasks = [
                1: [(11, String(localized: "Verwaltung")), (12, String(localized: "Weiterbildung"))],
                2: [(21, String(localized: "Wartung")), (22, String(localized: "Umsetzung"))],
                3: [(31, String(localized: "Text")), (32, String(localized: "Layout"))],
                4: [],
                5: [(51, String(localized: "Konzept")), (52, String(localized: "Design"))],
                6: [(61, String(localized: "Redaktion"))],
            ]
            odoo.lines = [
                .init(id: 1, date: yesterday.odooString, name: String(localized: "Beiträge für den nächsten Monat"),
                      projectID: 6, taskID: 61, hours: 2.5, invoiced: true),
                .init(id: 2, date: yesterday.odooString, name: String(localized: "Kontaktformular angepasst"),
                      projectID: 2, taskID: 22, hours: 1.5),
                .init(id: 3, date: yesterday.odooString, name: String(localized: "Seitenstruktur abgestimmt"),
                      projectID: 5, taskID: 51, hours: 4),
                .init(id: 4, date: today.odooString, name: String(localized: "Plugin-Updates"),
                      projectID: 2, taskID: 21, hours: 0.25),
                .init(id: 5, date: today.odooString, name: String(localized: "Angebot vorbereitet"),
                      projectID: 1, taskID: 11, hours: 2),
            ]
            odoo.attendances = [
                .init(id: 1, checkIn: time(yesterday, 8, 10), checkOut: time(yesterday, 12, 5)),
                .init(id: 2, checkIn: time(yesterday, 12, 45), checkOut: time(yesterday, 17, 10)),
            ]
        }
        return odoo
    }
}
