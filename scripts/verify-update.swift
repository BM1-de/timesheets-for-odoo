#!/usr/bin/env swift
// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Prüft vor dem Veröffentlichen, ob das Update in appcast.xml zur App passt: Die Signatur des DMG muss
// sich mit dem öffentlichen Schlüssel der App (SUPublicEDKey) bestätigen lassen, Größe und Version
// müssen stimmen. Sonst würde jede installierte App das Update ablehnen.
//
//   swift scripts/verify-update.swift build/release/Zeiterfassung.app build/release/….dmg build/appcast/appcast.xml

import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Update-Prüfung: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else { fail("Aufruf: verify-update.swift <App> <DMG> <appcast.xml>") }
let info = NSDictionary(contentsOfFile: arguments[1] + "/Contents/Info.plist")
guard let keyText = info?["SUPublicEDKey"] as? String, let keyData = Data(base64Encoded: keyText),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
    fail("Die App hat keinen gültigen SUPublicEDKey.")
}
guard let dmg = FileManager.default.contents(atPath: arguments[2]) else { fail("DMG nicht lesbar.") }
guard let appcast = try? String(contentsOfFile: arguments[3], encoding: .utf8) else { fail("appcast.xml nicht lesbar.") }

guard let signatureText = appcast.firstMatch(of: #/sparkle:edSignature="([^"]+)"/#)?.1,
      let signature = Data(base64Encoded: String(signatureText)) else {
    fail("appcast.xml enthält keine Signatur.")
}
guard publicKey.isValidSignature(signature, for: dmg) else {
    fail("Die Signatur passt nicht zum öffentlichen Schlüssel der App.")
}
guard let length = appcast.firstMatch(of: #/length="(\d+)"/#)?.1, Int(length) == dmg.count else {
    fail("Die Größe in appcast.xml passt nicht zum DMG.")
}
let version = info?["CFBundleVersion"] as? String ?? ""
guard appcast.contains("<sparkle:version>\(version)</sparkle:version>") else {
    fail("appcast.xml nennt nicht die Version \(version) der App.")
}
print("Update-Prüfung: Signatur, Größe und Version \(version) passen.")
