// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
@testable import Zeiterfassung

/// Hält die erste passende Anfrage an, bis der Test sie weiterlaufen lässt. So lässt sich prüfen,
/// was passiert, während die App auf Odoo wartet.
final class PausingHTTPClient: HTTPClient, @unchecked Sendable {
    private let base: any HTTPClient
    private let pausesOn: @Sendable (URLRequest) -> Bool
    private let lock = NSLock()
    private var hasPaused = false
    private var arrivalWaiter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    init(base: any HTTPClient, pausesOn: @escaping @Sendable (URLRequest) -> Bool) {
        self.base = base
        self.pausesOn = pausesOn
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if shouldPause(request) {
            await withCheckedContinuation { continuation in
                let waiter = lock.withLock {
                    release = continuation
                    defer { arrivalWaiter = nil }
                    return arrivalWaiter
                }
                waiter?.resume()
            }
        }
        return try await base.send(request)
    }

    private func shouldPause(_ request: URLRequest) -> Bool {
        guard pausesOn(request) else { return false }
        return lock.withLock {
            defer { hasPaused = true }
            return !hasPaused
        }
    }

    /// Wartet, bis die Anfrage angehalten ist.
    func waitUntilPaused() async {
        await withCheckedContinuation { continuation in
            let arrived = lock.withLock {
                if release != nil { return true }
                arrivalWaiter = continuation
                return false
            }
            if arrived { continuation.resume() }
        }
    }

    func resume() {
        let continuation = lock.withLock {
            defer { release = nil }
            return release
        }
        continuation?.resume()
    }
}
