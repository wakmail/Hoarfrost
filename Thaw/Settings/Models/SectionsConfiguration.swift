//
//  SectionsConfiguration.swift
//  Project: Hoarfrost
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Copyright (Hoarfrost) © 2026 wakmail
//  Licensed under the GNU GPLv3

import Foundation

/// How a section reveals its items when opened.
enum SectionRevealStyle: String, Codable, CaseIterable, Sendable {
    /// Follow the per display Ice Bar setting, like Ice and Thaw.
    case automatic
    /// Expand inline, pushing items into the menu bar.
    case push
    /// Show the floating Ice Bar panel.
    case bar
    /// Show a dropdown menu with one row per item.
    case menu

    var displayName: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .push: String(localized: "Expand in menu bar")
        case .bar: String(localized: "Floating bar")
        case .menu: String(localized: "Dropdown menu")
        }
    }
}

struct SectionDefinition: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var displayName: String
    var controlItemAutosaveName: String
    var hotkeyActionID: String
    var revealStyle: SectionRevealStyle = .automatic

    init(id: String, displayName: String, controlItemAutosaveName: String, hotkeyActionID: String, revealStyle: SectionRevealStyle = .automatic) {
        self.id = id
        self.displayName = displayName
        self.controlItemAutosaveName = controlItemAutosaveName
        self.hotkeyActionID = hotkeyActionID
        self.revealStyle = revealStyle
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, controlItemAutosaveName, hotkeyActionID, revealStyle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        controlItemAutosaveName = try container.decode(String.self, forKey: .controlItemAutosaveName)
        hotkeyActionID = try container.decode(String.self, forKey: .hotkeyActionID)
        revealStyle = try container.decodeIfPresent(SectionRevealStyle.self, forKey: .revealStyle) ?? .automatic
    }

    static let hidden = SectionDefinition(id: "hidden", displayName: "Hidden", controlItemAutosaveName: "Thaw.ControlItem.Hidden", hotkeyActionID: "ToggleHiddenSection")
    static let alwaysHidden = SectionDefinition(id: "alwaysHidden", displayName: "Always Hidden", controlItemAutosaveName: "Thaw.ControlItem.AlwaysHidden", hotkeyActionID: "ToggleAlwaysHiddenSection")
}

struct SectionsConfiguration: Codable, Hashable, Sendable {
    var hiddenSections: [SectionDefinition]
    /// When true, clicking the app's own menu bar icon opens one dropdown
    /// with a submenu per section instead of toggling the first section.
    var iceIconOpensCombinedMenu: Bool = false

    static let defaults = SectionsConfiguration(hiddenSections: [.hidden, .alwaysHidden])

    init(hiddenSections: [SectionDefinition], iceIconOpensCombinedMenu: Bool = false) {
        self.hiddenSections = hiddenSections
        self.iceIconOpensCombinedMenu = iceIconOpensCombinedMenu
    }

    private enum CodingKeys: String, CodingKey {
        case hiddenSections, iceIconOpensCombinedMenu
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hiddenSections = try container.decode([SectionDefinition].self, forKey: .hiddenSections)
        iceIconOpensCombinedMenu = try container.decodeIfPresent(Bool.self, forKey: .iceIconOpensCombinedMenu) ?? false
    }
}
