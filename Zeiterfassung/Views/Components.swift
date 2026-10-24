// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

// MARK: - Farben

extension Color {
    /// Fläche einer Gruppe: weiß im hellen, leicht aufgehellt im dunklen Erscheinungsbild.
    static let groupFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 1, alpha: 0.96)
    })

    /// Fußzeile einer Gruppe, etwa „Summe“.
    static let groupFooterFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.035) : NSColor(white: 0.975, alpha: 1)
    })

    static let hairline = Color(nsColor: .separatorColor)
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

// MARK: - Gruppen

/// Abgerundete Gruppe wie in den Systemeinstellungen.
struct InsetGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color.groupFill)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.hairline.opacity(0.6), lineWidth: 0.5)
            }
    }
}

struct SectionHeader: View {
    let title: LocalizedStringKey
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let detail { Text(detail).font(.subheadline) }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
    }
}

/// Zeile mit Symbol vorn, wie in Kalender und Erinnerungen.
struct FormRow<Content: View>: View {
    let symbol: String
    var minHeight: CGFloat = 40
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            content
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
    }
}

// MARK: - Knöpfe und Anzeigen

/// Knopf nur aus Symbol oder kurzem Text, mit Hervorhebung beim Überfahren.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration)
    }

    private struct IconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(.horizontal, 6)
                .frame(minWidth: 28, minHeight: 26)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : (isHovering && isEnabled ? 0.07 : 0)))
                }
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
                .opacity(isEnabled ? 1 : 0.35)
        }
    }
}

/// Inhalt eines Auswahlknopfs: Text links, Doppelpfeil rechts.
struct PopUpLabel: View {
    let title: String
    var isPlaceholder = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .foregroundStyle(isPlaceholder || !isEnabled ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

/// Grüner Punkt, solange eingestempelt; sonst ein leerer Kreis.
struct StatusDot: View {
    let isRunning: Bool

    var body: some View {
        ZStack {
            if isRunning {
                Circle().fill(Color.green.opacity(0.22)).frame(width: 14, height: 14)
                Circle().fill(Color.green).frame(width: 8, height: 8)
            } else {
                Circle().strokeBorder(Color.secondary, lineWidth: 1.5).frame(width: 8, height: 8)
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

/// Farbige Symbolkachel wie in den Systemeinstellungen.
struct IconTile: View {
    let symbol: String
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(color.gradient)
            .frame(width: 24, height: 24)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

struct ErrorBanner: View {
    let title: LocalizedStringKey
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Leichte Hervorhebung beim Überfahren einer Zeile.
struct HoverHighlight: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(isHovering ? Color.primary.opacity(0.04) : .clear)
            .onHover { isHovering = $0 }
    }
}

// MARK: - Status der Funktionen

struct FeatureStatus: Equatable {
    let symbol: String
    let color: Color
    let text: String
    let isAvailable: Bool

    static func timesheets(_ capabilities: Capabilities?) -> FeatureStatus {
        guard let capabilities else { return notChecked }
        switch capabilities.timesheets {
        case .available:
            return FeatureStatus(symbol: "checkmark.circle.fill", color: .green,
                                 text: String(localized: "Odoo-App „Zeiterfassung“ gefunden"), isAvailable: true)
        case .notInstalled:
            return problem(String(localized: "Die Odoo-App „Zeiterfassung“ ist in dieser Datenbank nicht installiert."))
        case .noEmployee:
            return problem(String(localized: "Dein Odoo-Benutzer ist mit keinem Mitarbeiter verknüpft."))
        case .noAccess:
            return problem(String(localized: "Kein Zugriff auf Zeiteinträge."))
        }
    }

    static func attendance(_ capabilities: Capabilities?) -> FeatureStatus {
        guard let capabilities else { return notChecked }
        switch capabilities.attendance {
        case .available where capabilities.canStamp:
            return FeatureStatus(symbol: "checkmark.circle.fill", color: .green,
                                 text: String(localized: "Odoo-App „Anwesenheiten“ gefunden"), isAvailable: true)
        case .available:
            return FeatureStatus(symbol: "info.circle.fill", color: .blue,
                                 text: String(localized: "Gefunden. Stempeln und Korrigieren braucht in Odoo das Recht „Sachbearbeiter: Alle Anwesenheiten verwalten“, bis dahin nur Anzeige."),
                                 isAvailable: true)
        case .notInstalled:
            return problem(String(localized: "Die Odoo-App „Anwesenheiten“ ist nicht installiert. Nach der Installation auf „Erneut prüfen“ klicken."))
        case .noEmployee:
            return problem(String(localized: "Dein Odoo-Benutzer ist mit keinem Mitarbeiter verknüpft. Ohne Verknüpfung speichert Odoo keine Anwesenheit."))
        case .noAccess:
            return problem(String(localized: "Kein Zugriff auf Anwesenheiten."))
        }
    }

    private static let notChecked = FeatureStatus(symbol: "questionmark.circle", color: .secondary,
                                                  text: String(localized: "Wird nach der Anmeldung geprüft."), isAvailable: false)

    private static func problem(_ text: String) -> FeatureStatus {
        FeatureStatus(symbol: "exclamationmark.triangle.fill", color: .orange, text: text, isAvailable: false)
    }
}
