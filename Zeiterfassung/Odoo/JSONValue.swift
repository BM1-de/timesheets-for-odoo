// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Ein beliebiger JSON-Wert, wie ihn Odoo erwartet und liefert.
///
/// Odoo schreibt leere Felder als `false`, Verweise auf andere Datensätze
/// (Many2one) als `[id, "Name"]`. Die Hilfen unten lesen beides.
enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    static func int(_ value: Int) -> JSONValue { .number(Double(value)) }

    static func ints(_ values: [Int]) -> JSONValue { .array(values.map(JSONValue.int)) }
}

// MARK: - Lesen

extension JSONValue {
    var intValue: Int? {
        guard case .number(let number) = self, number.rounded() == number, abs(number) < 9e15 else { return nil }
        return Int(number)
    }

    var doubleValue: Double? {
        guard case .number(let number) = self else { return nil }
        return number
    }

    var stringValue: String? {
        guard case .string(let string) = self else { return nil }
        return string
    }

    var boolValue: Bool? {
        guard case .bool(let bool) = self else { return nil }
        return bool
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let array) = self else { return nil }
        return array
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let object) = self else { return nil }
        return object
    }

    subscript(key: String) -> JSONValue? { objectValue?[key] }

    /// Verweis auf einen anderen Datensatz (`[id, "Name"]`); `nil` bei `false`.
    var reference: Reference? {
        guard let array = arrayValue, array.count >= 2, let id = array[0].intValue else { return nil }
        return Reference(id: id, name: array[1].stringValue ?? "")
    }
}

/// Verweis auf einen Odoo-Datensatz mit Anzeigename.
struct Reference: Sendable, Hashable, Codable {
    let id: Int
    let name: String
}

// MARK: - Codable

extension JSONValue: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unbekannter JSON-Wert")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let bool):
            try container.encode(bool)
        case .number(let number):
            // Ganze Zahlen als Ganzzahl schreiben: Odoo erwartet IDs als int, nicht als 1.0.
            if number.rounded() == number, abs(number) < 9e15 {
                try container.encode(Int64(number))
            } else {
                try container.encode(number)
            }
        case .string(let string):
            try container.encode(string)
        case .array(let array):
            try container.encode(array)
        case .object(let object):
            try container.encode(object)
        }
    }
}

// MARK: - Literale

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(nilLiteral: ()) { self = .null }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(stringLiteral value: String) { self = .string(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
