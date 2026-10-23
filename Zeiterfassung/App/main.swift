// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

// `--version` gibt nur die Version aus. Das Release-Skript prüft damit, ob die fertige App startet
// und alle eingebetteten Bibliotheken laden darf.
if CommandLine.arguments.dropFirst().first == "--version" {
    print(AppInfo.version)
    exit(0)
}

// Die App lebt nur in der Menüleiste (LSUIElement): kein Dock-Symbol, kein Hauptfenster.
let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
