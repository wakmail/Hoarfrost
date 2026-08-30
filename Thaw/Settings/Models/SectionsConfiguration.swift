//
//  SectionsConfiguration.swift
//  Project: Hoarfrost
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Copyright (Hoarfrost) © 2026 Preston Chen
//  Licensed under the GNU GPLv3

import Foundation

struct SectionDefinition: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var displayName: String
    var controlItemAutosaveName: String
    var hotkeyActionID: String

    static let hidden = SectionDefinition(id: "hidden", displayName: "Hidden", controlItemAutosaveName: "Thaw.ControlItem.Hidden", hotkeyActionID: "ToggleHiddenSection")
    static let alwaysHidden = SectionDefinition(id: "alwaysHidden", displayName: "Always Hidden", controlItemAutosaveName: "Thaw.ControlItem.AlwaysHidden", hotkeyActionID: "ToggleAlwaysHiddenSection")
}

struct SectionsConfiguration: Codable, Hashable, Sendable {
    var hiddenSections: [SectionDefinition]
    static let defaults = SectionsConfiguration(hiddenSections: [.hidden, .alwaysHidden])
}
