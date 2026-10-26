// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

#if DEBUG
import AppKit
import SwiftUI

/// Bilder für den Mac App Store: 2880 × 1800 Pixel, die Ansichten der App mit den Daten des
/// Demo-Modus auf einem Hintergrund mit Menüleiste und einer Überschrift. Je Sprache einmal, am
/// besten aus dem Debug-Build des Ziels „Zeiterfassung App Store“ (ohne Update-Suche), mit der
/// Region, deren Datumsformat die Bilder zeigen sollen:
///
///     Zeiterfassung.app/Contents/MacOS/Zeiterfassung -renderAppStoreScreenshots YES -AppleLanguages '(en)' -AppleLocale en_US
///
/// Die Bilder liegen danach im Container der App unter `tmp/appstore/<Sprache>`.
@MainActor
enum AppStoreScreenshots {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "renderAppStoreScreenshots") }

    private static let canvas = NSSize(width: 1440, height: 900)
    private static let menuBarHeight: CGFloat = 24
    private static var language: String { Bundle.main.preferredLocalizations.first ?? "de" }

    static func run() {
        Task {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "appstore/\(language)")
            let parts = directory.appending(path: "teile")
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
            await renderAll(to: directory, parts: parts)
            try? FileManager.default.removeItem(at: parts)
            print("App-Store-Bilder: \(directory.path)")
            NSApp.terminate(nil)
        }
    }

    private static func renderAll(to directory: URL, parts: URL) async {
        let demo = DemoData.makeOdoo(now: ScreenshotRenderer.now, calendar: ScreenshotRenderer.calendar)
        // Heute eingestempelt: 08:12–12:05 und seit 12:47 Ortszeit (UTC zwei Stunden früher).
        demo.withLock {
            demo.attendances += [
                .init(id: 11, checkIn: "2026-10-23 06:12:00", checkOut: "2026-10-23 10:05:00"),
                .init(id: 12, checkIn: "2026-10-23 10:47:00", checkOut: nil),
            ]
        }
        let model = ScreenshotRenderer.makeModel(demo)
        _ = try? await model.signIn(server: "odoo.example.com", apiKey: DemoServer.apiKey, login: nil, database: nil)
        model.finishSignIn()
        await model.refresh(force: true)
        model.stop()
        let texts = headlines[language] ?? headlines["en"]!

        let day = parts.appending(path: "tag.png")
        await ScreenshotRenderer.renderPanel(model, appearance: .aqua, to: day)
        compose(texts[0], panel: day, to: directory.appending(path: "1-tag.png"))

        model.preferences.durationRounding = .quarterHour
        if let project = model.projects.first(where: { $0.id == 5 }) {
            model.selectProject(project)
            await model.loadTasks(projectID: project.id)
            model.draft.taskID = 52
            model.draft.description = entryDescription[language] ?? entryDescription["en"]!
            model.draft.durationText = "1:20"
        }
        let entry = parts.appending(path: "eintrag.png")
        await ScreenshotRenderer.renderPanel(model, appearance: .aqua, to: entry)
        let picker = parts.appending(path: "suche.png")
        await ScreenshotRenderer.render(
            ProjectPicker(projects: model.projects, recentIDs: model.recentProjectIDs, selectedID: nil, isLoading: false) { _ in }
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)),
            appearance: .aqua, to: picker)
        compose(texts[1], panel: entry, beside: picker, to: directory.appending(path: "2-eintrag.png"))
        model.draft = AppModel.Draft()

        LoginItem.stateForScreenshots = false
        let settings = parts.appending(path: "einstellungen.png")
        await ScreenshotRenderer.render(
            SettingsView().environment(model).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)),
            appearance: .aqua, to: settings)
        compose(texts[2], window: settings, to: directory.appending(path: "3-einstellungen.png"))

        let dark = parts.appending(path: "dunkel.png")
        await ScreenshotRenderer.renderPanel(model, appearance: .darkAqua, to: dark)
        compose(texts[3], panel: dark, darkBackground: true, to: directory.appending(path: "4-dunkel.png"))
    }

    // MARK: - Texte

    private static let headlines: [String: [(String, String)]] = [
        "de": [
            ("Zeiterfassung in der Menüleiste", "Stunden buchen und stempeln, direkt in dein Odoo."),
            ("Projekt suchen, Dauer eintragen, fertig", "Die zuletzt verwendeten Projekte stehen oben."),
            ("Passt sich deinem Odoo an", "Die App prüft, welche Odoo-Apps und Rechte du hast."),
            ("Hell und dunkel", "Wie macOS, mit Tastatur und VoiceOver."),
        ],
        "en": [
            ("Time tracking in your menu bar", "Book hours and check in, straight into your Odoo."),
            ("Find the project, enter the time, done", "Recently used projects come first."),
            ("Adapts to your Odoo", "The app checks which Odoo apps and rights you have."),
            ("Light and dark", "Feels like macOS, with keyboard and VoiceOver."),
        ],
        "fr": [
            ("Le suivi du temps dans la barre des menus", "Saisissez vos heures et pointez, directement dans Odoo."),
            ("Trouvez le projet, indiquez la durée, c’est fait", "Les projets récents apparaissent en premier."),
            ("S’adapte à votre Odoo", "L’app vérifie vos applications Odoo et vos droits."),
            ("Clair et sombre", "Comme macOS, avec le clavier et VoiceOver."),
        ],
    ]

    private static let entryDescription = [
        "de": "Startseite: Varianten für den Kopfbereich",
        "en": "Home page: header variants",
        "fr": "Page d’accueil : variantes de l’en-tête",
    ]

    // MARK: - Zusammensetzen

    /// Fenster unter der Menüleiste rechts, Überschrift links; optional daneben die Projektsuche.
    private static func compose(_ text: (String, String), panel: URL, beside: URL? = nil,
                                darkBackground: Bool = false, to file: URL) {
        draw(to: file, dark: darkBackground) {
            guard let image = NSImage(contentsOf: panel) else { return }
            let size = pointSize(image)
            let statusItemX = canvas.width - 250
            let frame = NSRect(x: statusItemX - size.width / 2, y: canvas.height - menuBarHeight - 6 - size.height,
                               width: size.width, height: size.height)
            drawWithShadow(image, in: frame)
            if let beside, let picker = NSImage(contentsOf: beside) {
                let pickerSize = pointSize(picker)
                // Wie das Aufklappfenster am Feld „Projekt“ des neuen Eintrags
                let pickerFrame = NSRect(x: frame.minX - pickerSize.width - 24, y: frame.maxY - 395 - pickerSize.height,
                                         width: pickerSize.width, height: pickerSize.height)
                drawWithShadow(picker, in: pickerFrame)
            }
            drawHeadline(text, in: NSRect(x: 96, y: 0, width: (beside == nil ? frame.minX : frame.minX - 380) - 150,
                                          height: canvas.height), dark: darkBackground)
        }
    }

    /// Einstellungsfenster rechts, Überschrift links.
    private static func compose(_ text: (String, String), window: URL, to file: URL) {
        draw(to: file, dark: false) {
            guard let image = NSImage(contentsOf: window) else { return }
            let size = pointSize(image)
            let frame = NSRect(x: canvas.width - 120 - size.width, y: (canvas.height - menuBarHeight - size.height) / 2,
                               width: size.width, height: size.height)
            drawWithShadow(image, in: frame)
            drawHeadline(text, in: NSRect(x: 96, y: 0, width: frame.minX - 200, height: canvas.height), dark: false)
        }
    }

    private static func draw(to file: URL, dark: Bool, content: () -> Void) {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * 2), pixelsHigh: Int(canvas.height * 2),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        bitmap.size = canvas
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)

        let colors = dark
            ? [NSColor(srgbRed: 0.10, green: 0.13, blue: 0.24, alpha: 1), NSColor(srgbRed: 0.22, green: 0.16, blue: 0.36, alpha: 1)]
            : [NSColor(srgbRed: 0.42, green: 0.62, blue: 0.93, alpha: 1), NSColor(srgbRed: 0.62, green: 0.50, blue: 0.90, alpha: 1)]
        NSGradient(colors: colors)?.draw(in: NSRect(origin: .zero, size: canvas), angle: -35)
        drawMenuBar(dark: dark)
        content()

        NSGraphicsContext.restoreGraphicsState()
        try? bitmap.representation(using: .png, properties: [:])?.write(to: file)
    }

    /// Schlichte Menüleiste: rechts das Symbol der App mit den heute gebuchten Stunden und die Uhrzeit.
    private static func drawMenuBar(dark: Bool) {
        let bar = NSRect(x: 0, y: canvas.height - menuBarHeight, width: canvas.width, height: menuBarHeight)
        (dark ? NSColor(white: 0.1, alpha: 0.55) : NSColor(white: 1, alpha: 0.55)).setFill()
        bar.fill()
        let color = dark ? NSColor.white : NSColor.black
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let clock = Date.FormatStyle(locale: Formatting.locale, calendar: ScreenshotRenderer.calendar,
                                     timeZone: ScreenshotRenderer.calendar.timeZone)
            .weekday(.abbreviated).day().month(.abbreviated).hour().minute()
        let time = NSAttributedString(string: ScreenshotRenderer.now.formatted(clock), attributes: [.font: font, .foregroundColor: color])
        time.draw(at: NSPoint(x: canvas.width - 20 - time.size().width, y: bar.minY + 4))

        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        if let symbol = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
            let tinted = NSImage(size: symbol.size, flipped: false) { rect in
                symbol.draw(in: rect)
                color.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            let hours = NSAttributedString(string: " 2:15", attributes: [.font: font, .foregroundColor: color])
            let width = tinted.size.width + hours.size().width
            let x = canvas.width - 250 - width / 2
            tinted.draw(in: NSRect(x: x, y: bar.minY + (menuBarHeight - tinted.size.height) / 2, width: tinted.size.width,
                                   height: tinted.size.height))
            hours.draw(at: NSPoint(x: x + tinted.size.width, y: bar.minY + 4))
        }
    }

    private static func drawHeadline(_ text: (String, String), in rect: NSRect, dark: Bool) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.18)
        shadow.shadowBlurRadius = 12
        let title = NSAttributedString(string: text.0, attributes: [
            .font: NSFont.systemFont(ofSize: 52, weight: .bold), .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph, .shadow: shadow,
        ])
        let subtitle = NSAttributedString(string: text.1, attributes: [
            .font: NSFont.systemFont(ofSize: 24, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.9),
            .paragraphStyle: paragraph, .shadow: shadow,
        ])
        let titleHeight = title.boundingRect(with: NSSize(width: rect.width, height: 400), options: .usesLineFragmentOrigin).height
        let subtitleHeight = subtitle.boundingRect(with: NSSize(width: rect.width, height: 400), options: .usesLineFragmentOrigin).height
        let top = rect.midY + (titleHeight + 20 + subtitleHeight) / 2
        title.draw(with: NSRect(x: rect.minX, y: top - titleHeight, width: rect.width, height: titleHeight), options: .usesLineFragmentOrigin)
        subtitle.draw(with: NSRect(x: rect.minX, y: top - titleHeight - 20 - subtitleHeight, width: rect.width, height: subtitleHeight),
                      options: .usesLineFragmentOrigin)
    }

    private static func drawWithShadow(_ image: NSImage, in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
        shadow.shadowBlurRadius = 30
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Die Teilbilder sind doppelt aufgelöst; gezeichnet wird in Punkten.
    private static func pointSize(_ image: NSImage) -> NSSize {
        guard let rep = image.representations.first else { return image.size }
        return NSSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2)
    }
}
#endif
