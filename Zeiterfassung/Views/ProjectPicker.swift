// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Projektauswahl mit Suche, zuletzt verwendete Projekte oben.
/// Tastatur: tippen sucht, ↑ ↓ wählen, ↩ übernimmt, esc schließt.
struct ProjectPicker: View {
    let projects: [Project]
    let recentIDs: [Int]
    let selectedID: Int?
    let isLoading: Bool
    let onPick: (Project) -> Void

    @State private var query = ""
    @State private var highlightedID: Int?
    @FocusState private var isSearchFocused: Bool

    private var isSearching: Bool { !query.trimmed.isEmpty }

    private var matches: [Project] {
        let text = query.trimmed
        return text.isEmpty ? projects : projects.filter { $0.name.localizedStandardContains(text) }
    }

    private var recent: [Project] {
        guard !isSearching else { return [] }
        return recentIDs.compactMap { id in projects.first { $0.id == id } }
    }

    private var others: [Project] {
        guard !isSearching else { return matches }
        let recentSet = Set(recentIDs)
        return projects.filter { !recentSet.contains($0.id) }
    }

    /// Reihenfolge für ↑ und ↓.
    private var navigable: [Project] { recent + others }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Projekt oder Kunde suchen", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Projekt suchen")
                    .focused($isSearchFocused)
                    .onSubmit(pickHighlighted)
                    .onKeyPress(.downArrow) { move(by: 1); return .handled }
                    .onKeyPress(.upArrow) { move(by: -1); return .handled }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !recent.isEmpty {
                            groupTitle("Zuletzt verwendet")
                            ForEach(recent) { row(for: $0) }
                            Divider().padding(.vertical, 5).padding(.horizontal, 8)
                            groupTitle("Weitere Projekte")
                        }
                        ForEach(others) { row(for: $0) }
                        if navigable.isEmpty {
                            Text(isLoading ? String(localized: "Projekte werden geladen …") : String(localized: "Kein Projekt gefunden"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        }
                    }
                    .padding(5)
                }
                .frame(height: 248)
                .onChange(of: highlightedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }

            Divider()

            Text("↩ übernehmen · esc schließen")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .frame(width: 340)
        .onAppear {
            Task { @MainActor in isSearchFocused = true }
        }
        .onChange(of: query) {
            highlightedID = isSearching ? matches.first?.id : nil
        }
    }

    private func groupTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(for project: Project) -> some View {
        ProjectRow(project: project, isSelected: project.id == selectedID,
                   isHighlighted: project.id == highlightedID) { onPick(project) }
            .id(project.id)
    }

    private func move(by step: Int) {
        let list = navigable
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == highlightedID }.map { $0 + step } ?? (step > 0 ? 0 : list.count - 1)
        highlightedID = list[min(max(index, 0), list.count - 1)].id
    }

    private func pickHighlighted() {
        if let id = highlightedID, let project = projects.first(where: { $0.id == id }) {
            onPick(project)
        } else if let first = navigable.first {
            onPick(first)
        }
    }
}

/// Zeile wie ein Menüeintrag: Häkchen bei der Auswahl, Hervorhebung in der Akzentfarbe.
private struct ProjectRow: View {
    let project: Project
    let isSelected: Bool
    let isHighlighted: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var isActive: Bool { isHighlighted || isHovering }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 16)
                Text(project.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.leading, 4)
            .padding(.trailing, 8)
            .frame(height: 24)
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isActive ? Color.accentColor : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(project.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
