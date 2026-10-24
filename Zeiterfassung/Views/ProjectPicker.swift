// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Projektauswahl mit Suche, zuletzt verwendete Projekte oben. Mit mehreren Firmen gliedert sie sich
/// nach Firma; zuletzt verwendete Projekte und Suchtreffer nennen die Firma dazu.
/// Tastatur: tippen sucht, ↑ ↓ wählen, ↩ übernimmt, esc schließt.
struct ProjectPicker: View {
    let projects: [Project]
    let recentIDs: [Int]
    let selectedID: Int?
    let isLoading: Bool
    /// Mit mehreren Firmen: Name der Firma eines Projekts.
    var companyName: ((Project) -> String?)?
    /// Reihenfolge der Firmen, die Hauptfirma zuerst.
    var companyOrder: [Int] = []
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

    private struct Group: Identifiable {
        let id: String
        let title: String?
        let projects: [Project]
        let showsCompany: Bool
    }

    private var groups: [Group] {
        let multiCompany = companyName != nil
        if isSearching { return [Group(id: "treffer", title: nil, projects: matches, showsCompany: multiCompany)] }
        var result: [Group] = []
        if !recent.isEmpty {
            result.append(Group(id: "zuletzt", title: String(localized: "Zuletzt verwendet"), projects: recent,
                                showsCompany: multiCompany))
        }
        let recentSet = Set(recentIDs)
        let others = projects.filter { !recentSet.contains($0.id) }
        guard multiCompany else {
            result.append(Group(id: "weitere", title: result.isEmpty ? nil : String(localized: "Weitere Projekte"),
                                projects: others, showsCompany: false))
            return result
        }
        for companyID in companyOrder {
            let list = others.filter { $0.companyID == companyID }
            guard let first = list.first else { continue }
            result.append(Group(id: "firma-\(companyID)", title: companyName?(first), projects: list, showsCompany: false))
        }
        let rest = others.filter { project in !companyOrder.contains { $0 == project.companyID } }
        if !rest.isEmpty {
            result.append(Group(id: "ohne", title: String(localized: "Ohne Firma"), projects: rest, showsCompany: false))
        }
        return result
    }

    /// Reihenfolge für ↑ und ↓.
    private var navigable: [Project] { groups.flatMap(\.projects) }

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
                        let groups = groups
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            if index > 0 { Divider().padding(.vertical, 5).padding(.horizontal, 8) }
                            if let title = group.title { groupTitle(title) }
                            ForEach(group.projects) { project in
                                row(for: project, company: group.showsCompany ? companyName?(project) : nil)
                            }
                        }
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
                .frame(height: companyName == nil ? 248 : 300)
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
        .frame(width: companyName == nil ? 340 : 420)
        .onAppear {
            Task { @MainActor in isSearchFocused = true }
        }
        .onChange(of: query) {
            highlightedID = isSearching ? matches.first?.id : nil
        }
    }

    private func groupTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(for project: Project, company: String?) -> some View {
        ProjectRow(project: project, company: company, isSelected: project.id == selectedID,
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
    let company: String?
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
                if let company {
                    Text(company)
                        .font(.subheadline)
                        .foregroundStyle(isActive ? Color.white : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 170, alignment: .trailing)
                        .layoutPriority(-1)
                }
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
        .accessibilityLabel([project.name, company].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
