// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

/// Unsichtbares Hauptmenü. Die App zeigt keine Menüleiste, aber ohne diese Einträge
/// funktionieren ⌘C, ⌘V, ⌘Z, ⌘W, ⌘, und ⌘Q nicht.
@MainActor
enum MainMenu {
    static func make(delegate: AppDelegate) -> NSMenu {
        let mainMenu = NSMenu()

        let appMenu = NSMenu(title: AppInfo.name)
        appMenu.addItem(item(String(localized: "Über \(AppInfo.name)"), #selector(AppDelegate.showAbout(_:)), target: delegate))
        #if !APP_STORE
        appMenu.addItem(item(String(localized: "Nach Updates suchen …"), #selector(AppDelegate.checkForUpdates(_:)), target: delegate))
        #endif
        appMenu.addItem(.separator())
        appMenu.addItem(item(String(localized: "Einstellungen …"), #selector(AppDelegate.showSettings(_:)), key: ",", target: delegate))
        appMenu.addItem(.separator())
        appMenu.addItem(item(String(localized: "\(AppInfo.name) beenden"), #selector(NSApplication.terminate(_:)), key: "q"))
        mainMenu.addItem(submenuItem(appMenu))

        let editMenu = NSMenu(title: String(localized: "Bearbeiten"))
        editMenu.addItem(item(String(localized: "Widerrufen"), Selector(("undo:")), key: "z"))
        editMenu.addItem(item(String(localized: "Wiederholen"), Selector(("redo:")), key: "z", modifiers: [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(item(String(localized: "Ausschneiden"), #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(item(String(localized: "Kopieren"), #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(item(String(localized: "Einsetzen"), #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(item(String(localized: "Alles auswählen"), #selector(NSText.selectAll(_:)), key: "a"))
        mainMenu.addItem(submenuItem(editMenu))

        let windowMenu = NSMenu(title: String(localized: "Fenster"))
        windowMenu.addItem(item(String(localized: "Schließen"), #selector(NSWindow.performClose(_:)), key: "w"))
        mainMenu.addItem(submenuItem(windowMenu))

        return mainMenu
    }

    private static func item(_ title: String, _ action: Selector, key: String = "",
                             modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
