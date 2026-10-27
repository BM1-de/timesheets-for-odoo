// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Hauptansicht: Tag, laufende Projektzeit, Anwesenheit, Einträge, neuer Eintrag.
struct DayView: View {
    @Environment(AppModel.self) private var model
    @Environment(Updates.self) private var updates: Updates?
    var onOpenSettings: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DayHeader()
            if let notice = model.notice {
                NoticeBanner(notice: notice)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            if let updates, let version = updates.availableVersion {
                UpdateBanner(version: version) { updates.checkForUpdates() }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            VStack(spacing: 14) {
                if model.noFeatureActive {
                    NoFeatureCard(onOpenSettings: onOpenSettings)
                }
                if model.timesheetsActive, model.runningTimer != nil || model.timerNotice != nil {
                    RunningTimerSection()
                }
                if model.attendanceActive {
                    AttendanceSection()
                }
                if model.timesheetsActive {
                    EntriesSection()
                    NewEntrySection()
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .padding(.bottom, 14)
            Divider()
            PanelFooter(onOpenSettings: onOpenSettings)
        }
        .background {
            // ⌘R ohne sichtbaren Knopf
            Button("Aktualisieren") { Task { await model.refresh(force: true) } }
                .keyboardShortcut("r", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

struct DayHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.dayTitle)
                    .font(.title3.weight(.semibold))
                Text(model.dayLongDate)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Wird geladen")
            }
            if model.offersQuickStart {
                Button { Task { await model.startTimerNow() } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.tint)
                        Text("Starten")
                    }
                }
                .controlSize(.small)
                .help("Startet die Zeit jetzt. Projekt und Aufgabe wählst du, während sie läuft, oder beim Stoppen.")
            }
            if !model.isShowingToday {
                Button("Heute") { model.showToday() }
                    .controlSize(.small)
                    .keyboardShortcut("t", modifiers: .command)
                    .help("Zu heute (⌘T)")
            }
            Button { model.showPreviousDay() } label: {
                Image(systemName: "chevron.left").fontWeight(.semibold)
            }
            .buttonStyle(IconButtonStyle())
            .keyboardShortcut("[", modifiers: .command)
            .help("Vorheriger Tag (⌘[)")
            .accessibilityLabel("Vorheriger Tag")
            Button { model.showNextDay() } label: {
                Image(systemName: "chevron.right").fontWeight(.semibold)
            }
            .buttonStyle(IconButtonStyle())
            .keyboardShortcut("]", modifiers: .command)
            .help("Nächster Tag (⌘])")
            .accessibilityLabel("Nächster Tag")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

struct NoticeBanner: View {
    @Environment(AppModel.self) private var model
    let notice: AppModel.Notice

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(notice.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            switch notice.kind {
            case .signedOut:
                Button("Neu anmelden") { model.showSignIn() }
                    .controlSize(.small)
            case .offline, .failure:
                Button("Erneut versuchen") { Task { await model.refresh(force: true) } }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var symbol: String {
        switch notice.kind {
        case .offline: "wifi.exclamationmark"
        case .signedOut: "person.crop.circle.badge.exclamationmark"
        case .failure: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color { notice.kind == .failure ? .red : .orange }
}

/// Dezenter Hinweis auf eine neue Version; „Installieren …“ öffnet das Fenster von Sparkle.
struct UpdateBanner: View {
    let version: String
    var install: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Version \(version) ist verfügbar.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Installieren …", action: install)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct NoFeatureCard: View {
    var onOpenSettings: @MainActor () -> Void

    var body: some View {
        InsetGroup {
            VStack(spacing: 4) {
                Text("Keine Funktion eingeschaltet")
                    .fontWeight(.semibold)
                Text("Zeiterfassung und Anwesenheit sind ausgeschaltet oder in dieser Odoo-Datenbank nicht verfügbar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Einstellungen öffnen …") { onOpenSettings() }
                    .buttonStyle(.link)
                    .padding(.top, 6)
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
        }
    }
}

struct PanelFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    var onOpenSettings: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if let url = model.odooWebURL {
                Button { openURL(url) } label: {
                    HStack(spacing: 4) {
                        Text("In Odoo öffnen")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(IconButtonStyle())
                .help(url.absoluteString)
            }
            Spacer()
            // Die Tastenkürzel ⌘R, ⌘, und ⌘Q gelten im ganzen Fenster (DayView und Hauptmenü).
            Menu {
                Button("Aktualisieren") { Task { await model.refresh(force: true) } }
                Button("Einstellungen …") { onOpenSettings() }
                Divider()
                Button("\(AppInfo.name) beenden") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 6)
            .help("Weitere Befehle")
            .accessibilityLabel("Weitere Befehle")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}
