//
//  HotkeyAction.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

enum HotkeyAction: Hashable, Codable {
    // Menu Bar Sections
    case toggleHiddenSection
    case toggleAlwaysHiddenSection
    case toggleSection(id: String)

    /// Menu Bar Items
    case searchMenuBarItems

    // Other
    case enableIceBar
    case toggleApplicationMenus

    /// Used by profile hotkeys — action is handled externally.
    case profileApply

    var rawValue: String {
        switch self {
        case .toggleSection(let id): return "ToggleSection.\(id)"
        case .toggleHiddenSection: return "ToggleHiddenSection"
        case .toggleAlwaysHiddenSection: return "ToggleAlwaysHiddenSection"
        case .searchMenuBarItems: return "SearchMenuBarItems"
        case .enableIceBar: return "EnableIceBar"
        case .toggleApplicationMenus: return "ToggleApplicationMenus"
        case .profileApply: return "ProfileApply"
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "ToggleHiddenSection": self = .toggleHiddenSection
        case "ToggleAlwaysHiddenSection": self = .toggleAlwaysHiddenSection
        case "SearchMenuBarItems": self = .searchMenuBarItems
        case "EnableIceBar": self = .enableIceBar
        case "ToggleApplicationMenus": self = .toggleApplicationMenus
        case "ProfileApply": self = .profileApply
        default:
            guard rawValue.hasPrefix("ToggleSection.") else { return nil }
            self = .toggleSection(id: String(rawValue.dropFirst("ToggleSection.".count)))
        }
    }

    static var allCases: [HotkeyAction] {
        [.toggleHiddenSection, .toggleAlwaysHiddenSection, .searchMenuBarItems, .enableIceBar, .toggleApplicationMenus, .profileApply]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let action = Self(rawValue: value) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown hotkey action") }
        self = action
    }

    /// Actions that should appear in the Hotkeys settings pane.
    static var settingsActions: [HotkeyAction] {
        allCases.filter { $0 != .profileApply }
    }

    @MainActor
    func perform(appState: AppState) {
        switch self {
        case .toggleHiddenSection:
            guard let section = appState.menuBarManager.section(withName: .hidden) else {
                return
            }
            section.toggle(triggeredByHotkey: true)
            // Prevent the section from automatically rehiding after mouse movement.
            if !section.isHidden {
                appState.menuBarManager.showOnHoverAllowed = false
            }
        case .toggleAlwaysHiddenSection:
            guard let section = appState.menuBarManager.section(withName: .alwaysHidden) else {
                return
            }
            section.toggle(triggeredByHotkey: true)
            // Prevent the section from automatically rehiding after mouse movement.
            if !section.isHidden {
                appState.menuBarManager.showOnHoverAllowed = false
            }
        case .toggleSection(let id):
            guard let section = appState.menuBarManager.sections.first(where: { $0.name.id == id }) else { return }
            section.toggle(triggeredByHotkey: true)
            if !section.isHidden { appState.menuBarManager.showOnHoverAllowed = false }
        case .searchMenuBarItems:
            appState.menuBarManager.searchPanel.toggle()
        case .enableIceBar:
            appState.settings.displaySettings.toggleIceBarForActiveDisplay()
        case .toggleApplicationMenus:
            appState.menuBarManager.toggleApplicationMenus()
        case .profileApply:
            // Handled externally by ProfileManager's custom registration.
            break
        }
    }
}
