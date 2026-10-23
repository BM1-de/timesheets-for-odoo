// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Zeiterfassung

@Suite("Sprachen")
struct LocalizationTests {
    static let languages = ["en", "fr"]

    @Test("jeder Text ist englisch und französisch übersetzt, mit denselben Platzhaltern")
    func catalogIsComplete() throws {
        let strings = try Self.catalog()
        #expect(strings.count > 150)
        for (key, value) in strings {
            let entry = value as? [String: Any] ?? [:]
            if entry["shouldTranslate"] as? Bool == false { continue }
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            for language in Self.languages {
                let texts = Self.texts(in: localizations[language])
                #expect(!texts.isEmpty, "\(language) fehlt: \(key)")
                for text in texts {
                    #expect(Self.placeholders(text) == Self.placeholders(key), "\(language): \(key) → \(text)")
                }
            }
        }
    }

    @Test("die gebaute App enthält die Übersetzungen", arguments: [
        ("en", "Settings…", "Timesheets for Odoo", "1 hour", "2 hours"),
        ("fr", "Réglages…", "Feuilles de temps pour Odoo", "1 heure", "2 heures"),
    ])
    func builtTranslations(language: String, settings: String, name: String, oneHour: String, twoHours: String) throws {
        let bundle = try Self.bundle(language)
        #expect(String(localized: "Einstellungen …", bundle: bundle) == settings)
        #expect(bundle.localizedString(forKey: "CFBundleDisplayName", value: nil, table: "InfoPlist") == name)
        #expect(String(localized: "\(1) Stunden", bundle: bundle) == oneHour)
        #expect(String(localized: "\(2) Stunden", bundle: bundle) == twoHours)

        let marker = "\u{1}fehlt"
        let missing = try Self.catalog().compactMap { key, value -> String? in
            let entry = value as? [String: Any] ?? [:]
            guard entry["shouldTranslate"] as? Bool != false, !key.contains("%lld") else { return nil }
            return bundle.localizedString(forKey: key, value: marker, table: nil) == marker ? key : nil
        }
        #expect(missing.isEmpty, "\(language): \(missing)")
    }

    @Test("französisch steht die Null in der Einzahl")
    func frenchPlural() throws {
        let bundle = try Self.bundle("fr")
        #expect(String(localized: "\(0) Minuten", bundle: bundle, locale: Locale(identifier: "fr_FR")) == "0 minute")
        #expect(String(localized: "\(5) Minuten", bundle: bundle, locale: Locale(identifier: "fr_FR")) == "5 minutes")
    }

    /// Deutsch ist die Ausgangssprache: Die deutschen Texte sind die Schlüssel selbst. Wäre eine andere
    /// Sprache als Entwicklungssprache eingetragen, griffe macOS bei deutschen Texten auf sie zurück.
    @Test("die Tests laufen auf Deutsch, wie im Schema eingestellt")
    func testsRunInGerman() {
        #expect(Bundle.main.preferredLocalizations.first == "de")
        #expect(Bundle.main.developmentLocalization == "de")
        #expect(String(localized: "Einstellungen …") == "Einstellungen …")
        #expect(AppInfo.name == "Zeiterfassung für Odoo")
        #expect(DurationInput.spoken(61) == "1 Stunde 1 Minute")
    }

    // MARK: - Hilfen

    /// Der Übersetzungskatalog im Quellcode, nicht die gebaute Fassung.
    private static func catalog() throws -> [String: Any] {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Zeiterfassung/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return try #require(json?["strings"] as? [String: Any])
    }

    /// Ein Sprachordner der App als eigenes Bundle, um Texte einer anderen Sprache zu lesen.
    private static func bundle(_ language: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    /// Alle Texte einer Sprache, bei Einzahl und Mehrzahl beide.
    private static func texts(in localization: Any?) -> [String] {
        guard let localization = localization as? [String: Any] else { return [] }
        if let unit = localization["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
            return [value]
        }
        let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: Any] ?? [:]
        return plural.values.compactMap { (($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String }
    }

    private static func placeholders(_ text: String) -> [String] {
        text.matches(of: /%(?:\d+\$)?(?:lld|ld|d|@)/).map { String($0.output) }.sorted()
    }
}
