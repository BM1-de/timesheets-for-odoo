// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Schickt eine Anfrage und liefert Daten und Antwortkopf. In Tests ersetzbar.
protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// HTTP über `URLSession`, ohne Cookies und ohne Umleitungen.
///
/// - Cookies: Die Schnittstellen von Odoo arbeiten ohne Sitzung, und ein Sitzungs-Cookie würde
///   mit dem Kopf `X-Odoo-Database` kollidieren.
/// - Umleitungen: Eine Umleitung schickte den API-Schlüssel (Kopf oder Inhalt der Anfrage) an die
///   neue Adresse. Die App folgt deshalb nie, sondern meldet die neue Adresse.
struct URLSessionHTTPClient: HTTPClient {
    let session: URLSession

    static func makeDefault() -> URLSessionHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.httpAdditionalHeaders = ["User-Agent": AppInfo.userAgent]
        return URLSessionHTTPClient(session: URLSession(configuration: configuration, delegate: RedirectBlocker(),
                                                        delegateQueue: nil))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw OdooError.unexpectedResponse(String(localized: "Keine HTTP-Antwort."))
            }
            if (300..<400).contains(httpResponse.statusCode) {
                throw OdooError.redirected(httpResponse.value(forHTTPHeaderField: "Location") ?? "")
            }
            return (data, httpResponse)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw OdooError.offline(error.localizedDescription)
        }
    }
}

/// Lehnt jede Umleitung ab; `URLSession` liefert dann die 3xx-Antwort selbst.
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

/// Schickt Anfragen nacheinander und wartet, wenn Odoo „zu viele Anfragen“ meldet (HTTP 429).
///
/// Odoo Online lehnt mehrere gleichzeitige Anfragen schnell ab. Eine mit 429 abgelehnte Anfrage hat
/// Odoo nicht ausgeführt, die Wiederholung legt also nichts doppelt an. Hilft das Warten nicht, fragt
/// die App eine Weile gar nicht mehr an, statt die Sperre mit jedem Versuch zu verlängern.
actor PacedHTTPClient: HTTPClient {
    private static let retryDelays: [TimeInterval] = [2, 4, 8]
    /// Länger wartet eine Anfrage nicht, solange andere hinter ihr anstehen.
    private static let longestWait: TimeInterval = 15
    private static let shortestPause: TimeInterval = 30
    private static let longestPause: TimeInterval = 300

    private let base: any HTTPClient
    private let clock: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var pausedUntil: Date?

    init(base: any HTTPClient, clock: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.base = base
        self.clock = clock
        self.sleep = sleep
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await enter()
        defer { leave() }
        try Task.checkCancellation()
        if let pausedUntil, clock() < pausedUntil { throw OdooError.rateLimited }

        var attempt = 0
        while true {
            let (data, response) = try await base.send(request)
            guard response.statusCode == 429 else { return (data, response) }
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            guard attempt < Self.retryDelays.count,
                  (retryAfter ?? Self.retryDelays[attempt]) <= Self.longestWait else {
                let pause = min(max(retryAfter ?? 0, Self.shortestPause), Self.longestPause)
                pausedUntil = clock().addingTimeInterval(pause)
                throw OdooError.rateLimited
            }
            try await sleep(.seconds(retryAfter ?? Self.retryDelays[attempt]))
            attempt += 1
        }
    }

    private func enter() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func leave() {
        if waiting.isEmpty {
            isBusy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
