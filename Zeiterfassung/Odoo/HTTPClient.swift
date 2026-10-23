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
