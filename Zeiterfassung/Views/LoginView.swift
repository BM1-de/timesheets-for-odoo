// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

/// Erste Anmeldung: Server und API-Schlüssel. Benutzername und Datenbank erscheinen nur,
/// wenn der Server sie braucht (Odoo 17/18, mehrere Datenbanken).
struct LoginView: View {
    @Environment(AppModel.self) private var model
    @State private var server = ""
    @State private var apiKey = ""
    @State private var login = ""
    @State private var database = ""
    @State private var showsLogin = false
    @State private var showsDatabase = false
    @State private var isConnecting = false
    @State private var errorText: String?
    @State private var result: Capabilities?
    @State private var didPrefill = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case server
        case apiKey
        case login
        case database
    }

    /// Als `String`, nicht als `LocalizedStringKey`: Sonst liest SwiftUI die Adresse als Markdown-Link.
    private static let serverPlaceholder = "https://odoo.example.de"

    private var canConnect: Bool {
        !isConnecting && !server.trimmed.isEmpty && !apiKey.trimmed.isEmpty
            && (!showsLogin || !login.trimmed.isEmpty) && (!showsDatabase || !database.trimmed.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let result {
                success(result)
            } else {
                form
            }
        }
        .onAppear(perform: prefill)
    }

    private var header: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
            Text(result == nil ? String(localized: "Mit Odoo verbinden") : String(localized: "Verbunden"))
                .font(.title3.weight(.semibold))
                .padding(.top, 4)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 20)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    private var subtitle: String {
        if let result {
            return String(localized: "Angemeldet als \(result.userName) bei \(model.serverDisplay).")
        }
        return String(localized: "Einmal anmelden, danach erfasst du Zeiten direkt aus der Menüleiste.")
    }

    // MARK: - Formular

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            InsetGroup {
                row("Server") {
                    TextField(Self.serverPlaceholder, text: $server)
                        .accessibilityLabel("Server")
                        .textContentType(.URL)
                        .focused($focusedField, equals: .server)
                }
                Divider().padding(.leading, 12)
                row("API-Schlüssel") {
                    SecureField("Erforderlich", text: $apiKey)
                        .accessibilityLabel("API-Schlüssel")
                        .focused($focusedField, equals: .apiKey)
                }
                if showsLogin {
                    Divider().padding(.leading, 12)
                    row("Benutzername") {
                        TextField("Login in Odoo, meist die E-Mail", text: $login)
                            .accessibilityLabel("Benutzername")
                            .textContentType(.username)
                            .focused($focusedField, equals: .login)
                    }
                }
                if showsDatabase {
                    Divider().padding(.leading, 12)
                    row("Datenbank") {
                        TextField("Name der Datenbank", text: $database)
                            .accessibilityLabel("Datenbank")
                            .focused($focusedField, equals: .database)
                    }
                }
            }
            Text("In Odoo: Profilbild oben rechts › Meine Präferenzen › Sicherheit › API-Schlüssel hinzufügen. Der Schlüssel wird im Schlüsselbund deines Mac gespeichert.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            HStack(spacing: 8) {
                if model.session != nil {
                    Button("Abbrechen") { model.cancelSignIn() }
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                if isConnecting {
                    ProgressView().controlSize(.small)
                    Text("Verbinde …").font(.callout).foregroundStyle(.secondary)
                }
                Button("Verbinden") { Task { await connect() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConnect)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .disabled(isConnecting)
    }

    private func row<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 100, alignment: .leading)
            content()
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
    }

    // MARK: - Ergebnis

    private func success(_ found: Capabilities) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "In Odoo gefunden")
            InsetGroup {
                resultRow("Zeiterfassung", FeatureStatus.timesheets(found))
                Divider().padding(.leading, 40)
                resultRow("Anwesenheit", FeatureStatus.attendance(found))
            }
            Text("Ändern kannst du das jederzeit in den Einstellungen.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            HStack {
                Spacer()
                Button("Fertig") { model.finishSignIn() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private func resultRow(_ title: LocalizedStringKey, _ status: FeatureStatus) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status.symbol)
                .foregroundStyle(status.color)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(status.isAvailable ? String(localized: "eingeschaltet") : status.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Ablauf

    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        if let hints = model.preferences.loginHints {
            server = hints.server
            if let hintLogin = hints.login {
                login = hintLogin
                showsLogin = true
            }
            // Eine vorausgefüllte Datenbank immer zeigen, damit sie nicht unbemerkt mitgeschickt wird.
            if let hintDatabase = hints.database {
                database = hintDatabase
                showsDatabase = true
            }
        }
        Task { @MainActor in focusedField = server.isEmpty ? .server : .apiKey }
    }

    private func connect() async {
        isConnecting = true
        errorText = nil
        defer { isConnecting = false }
        do {
            result = try await model.signIn(server: server, apiKey: apiKey,
                                            login: showsLogin ? login : nil,
                                            database: database.trimmed.isEmpty ? nil : database)
            apiKey = ""
        } catch OdooError.loginRequired {
            showsLogin = true
            errorText = OdooError.loginRequired.localizedDescription
            focusedField = .login
        } catch OdooError.databaseRequired {
            showsDatabase = true
            errorText = OdooError.databaseRequired.localizedDescription
            focusedField = .database
        } catch {
            errorText = error.localizedDescription
        }
    }
}
