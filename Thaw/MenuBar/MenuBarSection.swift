//
//  MenuBarSection.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import SwiftUI

/// A representation of a section in a menu bar.
@MainActor
final class MenuBarSection {
    /// The name of a menu bar section.
    /// The identity of a section.
    ///
    /// Equality and hashing use `id` only, so a renamed or reordered section
    /// still matches its cached items and persisted keys.
    struct Name: Hashable, Codable, Sendable, Comparable {
        /// Stable persistence key. The three defaults use the strings Ice and
        /// Thaw always used on disk.
        let id: String
        /// 0 is the visible section, 1 the first hidden section, 2 the next
        /// one to its left, and so on.
        var rank: Int
        var displayName: String

        static let visible = Name(id: "visible", rank: 0, displayName: "Visible")
        static let hidden = Name(id: "hidden", rank: 1, displayName: "Hidden")
        static let alwaysHidden = Name(id: "alwaysHidden", rank: 2, displayName: "Always Hidden")

        /// The sections currently configured, in rank order. Updated by
        /// `MenuBarManager` whenever the configuration changes so code that
        /// runs off the main actor sees the same list.
        nonisolated(unsafe) static var configured: [Name] = [.visible, .hidden, .alwaysHidden]

        /// All configured sections in rank order.
        static var allCases: [Name] { configured }

        var rawValue: String { id }
        var isVisible: Bool { rank == 0 }
        /// Whether this is one of the three sections Ice and Thaw shipped with.
        var isDefault: Bool { id == "visible" || id == "hidden" || id == "alwaysHidden" }

        /// The control item identifier for this section. Derived from `id`,
        /// never from rank, so divider positions survive reordering.
        var controlItemIdentifier: ControlItem.Identifier {
            switch id {
            case "visible": .visible
            case "hidden": .hidden
            case "alwaysHidden": .alwaysHidden
            default: ControlItem.Identifier(rawValue: "Thaw.ControlItem.Section.\(id)")
            }
        }

        /// The hotkey action that toggles this section, or nil for visible.
        var hotkeyAction: HotkeyAction? {
            switch id {
            case "visible": nil
            case "hidden": .toggleHiddenSection
            case "alwaysHidden": .toggleAlwaysHiddenSection
            default: .toggleSection(id: id)
            }
        }

        static func == (lhs: Name, rhs: Name) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
        static func < (lhs: Name, rhs: Name) -> Bool { lhs.rank < rhs.rank }

        /// A string to show in the interface.
        var displayString: String {
            displayName
        }

        /// A string to use for logging purposes.
        var logString: String {
            "\(displayName.lowercased()) section"
        }

        /// Localized string key representation.
        var localized: LocalizedStringKey {
            switch id {
            case "visible": "Visible"
            case "hidden": "Hidden"
            case "alwaysHidden": "Always-Hidden"
            default: LocalizedStringKey(displayName)
            }
        }
    }

    /// The name of the section.
    var name: Name

    /// How the section reveals its items. Set from the persisted
    /// configuration by `MenuBarManager`.
    var revealStyle: SectionRevealStyle = .automatic

    /// The dropdown used by the `menu` reveal style.
    private var dropdownMenu: SectionDropdownMenu?

    /// Builders kept alive while the combined menu is open.
    private var combinedMenuBuilders: [SectionDropdownMenu] = []

    /// The control item that manages the section.
    let controlItem: ControlItem

    /// The shared app state.
    private weak var appState: AppState?

    /// A task that manages rehiding the section.
    private var rehideTask: Task<Void, Never>?

    /// An event monitor that handles starting the rehide task when the mouse
    /// is outside of the menu bar.
    private var rehideMonitor: EventMonitor?

    /// The section's diagnostic logger.
    private nonisolated let diagLog = DiagLog(category: "MenuBarSection")

    /// A Boolean value that indicates whether the Ice Bar should be used
    /// on the current active display.
    private var useIceBar: Bool {
        guard let appState else { return false }
        switch revealStyle {
        case .bar:
            return true
        case .push, .menu:
            return false
        case .automatic:
            let screen = screenForIceBar
            let displayID = screen?.displayID ?? CGMainDisplayID()
            return appState.settings.displaySettings.useIceBar(for: displayID)
        }
    }

    /// The gap that macOS leaves to the left and right of the notch (in points).
    static let notchGap: CGFloat = 24

    /// Checks whether there is enough space to show the hidden items inline
    /// on the given screen, accounting for the notch and its required gaps.
    ///
    /// - Parameter screen: The screen to check space on.
    /// - Returns: `true` if items will fit without extending into the notch area.
    private func canShowItemsInline(on screen: NSScreen) -> Bool {
        guard let appState else { return false }

        // Get the application menu frame to determine where items start
        guard let appMenuFrame = screen.getApplicationMenuFrame() else {
            return true // If we can't determine, assume it fits
        }

        // Calculate total width of items in the sections we want to show
        var totalItemsWidth: CGFloat = 0

        totalItemsWidth = appState.menuBarManager.sections
            .filter { $0.name.rank <= name.rank }
            .flatMap { appState.itemManager.itemCache[$0.name] }
            .reduce(0) { $0 + $1.bounds.width }

        // Get the right edge of the application menu
        let appMenuRightEdge = appMenuFrame.maxX

        // Check if screen has a notch
        if let notch = screen.frameOfNotch {
            // macOS leaves a 24px gap on both sides of the notch
            let usableLeftOfNotch = notch.minX - Self.notchGap
            let usableRightOfNotchStart = notch.maxX + Self.notchGap

            // Calculate available space to the left of the notch (from app menu end)
            let spaceLeftOfNotch = max(0, usableLeftOfNotch - appMenuRightEdge)

            // Calculate available space to the right of the notch (until screen edge)
            let spaceRightOfNotch = screen.visibleFrame.maxX - usableRightOfNotchStart

            // Total usable space is sum of space on both sides of the notch
            let totalUsableSpace = spaceLeftOfNotch + spaceRightOfNotch

            // Check if items fit within usable space
            return totalItemsWidth <= totalUsableSpace
        } else {
            // No notch - just check against visible frame
            let availableSpace = screen.visibleFrame.maxX - appMenuRightEdge
            return totalItemsWidth <= availableSpace
        }
    }

    /// A weak reference to the menu bar manager.
    private weak var menuBarManager: MenuBarManager? {
        appState?.menuBarManager
    }

    /// The best screen to show the Ice Bar on.
    ///
    /// Always returns the screen with the active menu bar so that
    /// clicking icons in the IceBar actually activates their popups.
    private weak var screenForIceBar: NSScreen? {
        NSScreen.screenWithActiveMenuBar ?? NSScreen.main
    }

    /// The hiding state the user desires for the section.
    @Published var desiredState: ControlItem.HidingState = .hideSection

    /// A Boolean value that indicates whether the section is hidden.
    var isHidden: Bool {
        if useIceBar {
            if controlItem.state == .showSection {
                return false
            }
            return menuBarManager?.iceBarPanel.currentSection?.rank != name.rank
        }
        if menuBarManager?.iceBarPanel.currentSection?.rank == name.rank { return false }
        return desiredState == .hideSection
    }

    /// A Boolean value that indicates whether the section is enabled.
    var isEnabled: Bool {
        if name.isVisible {
            // The visible section should always be enabled.
            return true
        }
        return controlItem.isAddedToMenuBar
    }

    /// The hotkey to toggle the section.
    var hotkey: Hotkey? {
        guard let hotkeys = appState?.settings.hotkeys else {
            return nil
        }
        guard let action = name.hotkeyAction else { return nil }
        return hotkeys.hotkey(withAction: action)
    }

    /// Creates a section with the given name and control item.
    init(name: Name, controlItem: ControlItem) {
        self.name = name
        self.controlItem = controlItem
    }

    /// Creates a section with the given name.
    convenience init(name: Name) {
        let controlItem = ControlItem(identifier: name.controlItemIdentifier)
        self.init(name: name, controlItem: controlItem)
    }

    /// Performs the initial setup of the section.
    func performSetup(with appState: AppState) {
        self.appState = appState
        controlItem.performSetup(with: appState)
        desiredState = controlItem.state
    }

    /// Updates the state of the control item based on the desired state
    /// and the current display configuration.
    ///
    /// - Parameter screen: The screen to use for the update. If `nil`, the
    ///   best screen is determined automatically.
    func updateControlItemState(for screen: NSScreen? = nil) {
        guard let appState else { return }

        // If the user wants to show, always show.
        if desiredState == .showSection {
            controlItem.state = .showSection
            return
        }

        // If the user wants to hide, check the current display config.
        // Use screenWithMouse for instant reactivity when switching displays.
        guard let activeScreen = screen ?? NSScreen.screenWithMouse ?? NSScreen.screenWithActiveMenuBar ?? NSScreen.main else {
            controlItem.state = desiredState
            return
        }

        let displaySettings = appState.settings.displaySettings
        let alwaysShow = displaySettings.alwaysShowHiddenItems(for: activeScreen.displayID)
        let useIceBar = displaySettings.useIceBar(for: activeScreen.displayID)

        if name.rank <= 1, alwaysShow, !useIceBar {
            controlItem.state = .showSection
        } else {
            controlItem.state = desiredState
        }
    }

    /// Shows the section.
    func show(triggeredByHotkey: Bool = false) {
        guard let menuBarManager, isHidden else {
            return
        }

        menuBarManager.updateLastShowTimestamp()

        guard controlItem.isAddedToMenuBar else {
            return
        }

        if name.isVisible, let appState, menuBarManager.sectionsConfiguration.iceIconOpensCombinedMenu {
            // One icon, every section: a dropdown with a submenu per section.
            menuBarManager.iceBarPanel.close()
            let combined = SectionDropdownMenu.makeCombinedMenu(appState: appState)
            combinedMenuBuilders = combined.builders
            controlItem.present(combined.menu)
            return
        }

        if revealStyle == .menu, let appState {
            // Items stay physically hidden; the menu shows their images.
            menuBarManager.iceBarPanel.close()
            if dropdownMenu == nil {
                dropdownMenu = SectionDropdownMenu(appState: appState, sectionName: name)
            }
            dropdownMenu?.show(from: controlItem)
            return
        }

        // Determine whether we should use the Ice Bar based on settings.
        let shouldUseIceBarBasedOnSettings = useIceBar

        // Check if items will fit inline (only relevant when not already using Ice Bar).
        var canShowInline = true
        if !shouldUseIceBarBasedOnSettings, let screen = screenForIceBar {
            canShowInline = canShowItemsInline(on: screen)
            if !canShowInline {
                diagLog.info("Not enough space to show items inline, falling back to Ice Bar")
            }
        }

        // Use Ice Bar if settings say so OR if items won't fit inline.
        if shouldUseIceBarBasedOnSettings || !canShowInline {
            // Make sure hidden and always-hidden control items are collapsed.
            // Still update the visible control item (Ice icon) state to show
            // its alternate icon.
            for section in menuBarManager.sections {
                if section.name.isVisible {
                    section.desiredState = .showSection
                } else {
                    section.desiredState = .hideSection
                }
                section.updateControlItemState(for: nil)
            }

            if let screen = screenForIceBar {
                if name.rank <= 1 {
                    menuBarManager.iceBarPanel.show(
                        section: name,
                        on: screen,
                        triggeredByHotkey: triggeredByHotkey
                    )
                } else {
                    menuBarManager.iceBarPanel.show(
                        section: name,
                        on: screen,
                        triggeredByHotkey: triggeredByHotkey
                    )
                }
                startRehideChecks()
            }

            return // We're done.
        }

        // If we made it here, we're not using the Ice Bar.
        // Make sure it's closed.
        menuBarManager.iceBarPanel.close()

        for section in menuBarManager.sections {
            section.desiredState = section.name.rank <= name.rank ? .showSection : .hideSection
            section.updateControlItemState(for: nil)
        }

        startRehideChecks()
    }

    /// Hides the section.
    func hide() {
        guard let menuBarManager, !isHidden else {
            return
        }

        menuBarManager.iceBarPanel.close() // Make sure Ice Bar is always closed.
        menuBarManager.showOnHoverAllowed = true

        for section in menuBarManager.sections {
            section.desiredState = .hideSection
            section.updateControlItemState(for: nil)
        }

        stopRehideChecks()
    }

    /// Toggles the visibility of the section.
    func toggle(triggeredByHotkey: Bool = false) {
        if isHidden {
            show(triggeredByHotkey: triggeredByHotkey)
        } else {
            hide()
        }
    }

    /// Returns `true` when the mouse cursor is inside the menu bar or the
    /// IceBar panel, meaning the section should not be rehidden yet.
    private func isMouseInsideActiveArea() -> Bool {
        guard let appState else { return false }
        if let screen = appState.hidEventManager.bestScreen(appState: appState),
           appState.hidEventManager.isMouseInsideMenuBar(appState: appState, screen: screen)
        {
            return true
        }
        if appState.hidEventManager.isMouseInsideIceBar(appState: appState) {
            return true
        }
        return false
    }

    /// Starts running checks to determine when to rehide the section.
    private func startRehideChecks() {
        rehideTask?.cancel()
        rehideMonitor?.stop()

        guard
            let appState,
            appState.settings.general.autoRehide
        else {
            return
        }

        switch appState.settings.general.rehideStrategy {
        case .smart:
            // Smart rehide strategy uses the rehide interval as a fallback
            // to the click-based rehide checks. Task.sleep replaces Timer so
            // cancellation is automatic when the task is reassigned or cancelled.
            let interval = appState.settings.general.rehideInterval
            rehideTask = Task { [weak self, weak appState] in
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self, let appState else { return }
                // Don't rehide while the mouse is inside the menu bar or IceBar.
                if self.isMouseInsideActiveArea() {
                    self.startRehideChecks()
                    return
                }
                // Check if any menu bar item has a menu open before hiding.
                if await appState.itemManager.isAnyMenuBarItemMenuOpen() {
                    // Restart the task to check again later.
                    self.startRehideChecks()
                    return
                }
                self.hide()
            }
        case .timed:
            rehideMonitor = EventMonitor.universal(for: .mouseMoved) { [weak self, weak appState] event in
                // Throttle: process at most ~20fps regardless of mouse polling rate.
                enum Context {
                    static var lastTime: TimeInterval = 0
                }
                let now = CACurrentMediaTime()
                guard now - Context.lastTime > 0.05 else { return event }
                Context.lastTime = now

                guard
                    let self,
                    let appState,
                    let screen = NSScreen.main
                else {
                    return event
                }
                let mouseInActiveArea =
                    NSEvent.mouseLocation.y >= screen.visibleFrame.maxY ||
                    appState.hidEventManager.isMouseInsideIceBar(appState: appState)

                if !mouseInActiveArea {
                    if rehideTask == nil {
                        let interval = appState.settings.general.rehideInterval
                        rehideTask = Task { @MainActor [weak self, weak appState] in
                            try? await Task.sleep(for: .seconds(interval))
                            guard !Task.isCancelled, let self, let appState else { return }
                            // Don't rehide while the mouse is inside the menu bar or IceBar.
                            if self.isMouseInsideActiveArea() {
                                self.startRehideChecks()
                                return
                            }
                            // Check if any menu bar item has a menu open before hiding.
                            if await appState.itemManager.isAnyMenuBarItemMenuOpen() {
                                self.diagLog.debug("Open menu detected - restarting timed rehide task")
                                await self.restartTimedRehideTimer()
                                return
                            }
                            self.hide()
                        }
                    }
                } else {
                    rehideTask?.cancel()
                    rehideTask = nil
                }
                return event
            }

            rehideMonitor?.start()
        case .focusedApp:
            break
        }
    }

    /// Restarts the timed rehide task (used when a menu is detected).
    @MainActor
    private func restartTimedRehideTimer() async {
        guard
            let appState,
            appState.settings.general.autoRehide,
            case .timed = appState.settings.general.rehideStrategy
        else {
            return
        }

        rehideTask?.cancel()
        let interval = appState.settings.general.rehideInterval
        rehideTask = Task { [weak self, weak appState] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, let self, let appState else { return }
            // Don't rehide while the mouse is inside the menu bar or IceBar.
            if self.isMouseInsideActiveArea() {
                self.startRehideChecks()
                return
            }
            // Check if any menu bar item has a menu open before hiding.
            if await appState.itemManager.isAnyMenuBarItemMenuOpen() {
                self.diagLog.debug("Open menu still detected - restarting timed rehide task again")
                await self.restartTimedRehideTimer()
                return
            }
            self.hide()
        }
    }

    /// Stops running checks to determine when to rehide the section.
    private func stopRehideChecks() {
        rehideTask?.cancel()
        rehideMonitor?.stop()
        rehideTask = nil
        rehideMonitor = nil
    }
}
