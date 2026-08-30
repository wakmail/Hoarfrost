//
//  MenuBarManager.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Combine
import SwiftUI

/// Manager for the state of the menu bar.
@MainActor
final class MenuBarManager: ObservableObject {
    /// Information for the menu bar's average color.
    @Published private(set) var averageColorInfo: MenuBarAverageColorInfo?

    /// A Boolean value that indicates whether the menu bar is either always hidden
    /// by the system, or automatically hidden and shown by the system based on the
    /// location of the mouse.
    @Published private(set) var isMenuBarHiddenBySystem = false

    /// A Boolean value that indicates whether the menu bar is hidden by the system
    /// according to a value stored in UserDefaults.
    @Published private(set) var isMenuBarHiddenBySystemUserDefaults = false

    /// A Boolean value that indicates whether the "ShowOnHover" feature is allowed.
    @Published var showOnHoverAllowed = true

    /// Timestamp of the last time a section was shown.
    private(set) var lastShowTimestamp: ContinuousClock.Instant?

    /// Reference to the settings window.
    @Published private var settingsWindow: NSWindow?

    /// Diagnostic logger for the menu bar manager.
    private let diagLog = DiagLog(category: "MenuBarManager")

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// Cancellable for the periodic average-color refresh, active only while settings is visible.
    private var averageColorRefreshCancellable: AnyCancellable?

    /// A Boolean value that indicates whether the application menus are hidden.
    private var isHidingApplicationMenus = false

    /// A Boolean value that indicates whether the application menus were hidden
    /// by a manual toggle (URL/hotkey), rather than automatically by section state.
    private var isManuallyHidingApplicationMenus = false

    /// The panel that contains the Ice Bar interface.
    let iceBarPanel = IceBarPanel()

    /// The panel that contains the menu bar search interface.
    let searchPanel = MenuBarSearchPanel()

    /// The popover that contains a portable version of the menu bar
    /// appearance editor interface
    let appearanceEditorPanel = MenuBarAppearanceEditorPanel()

    /// The managed sections in the menu bar.
    @Published private(set) var sections: [MenuBarSection] = []

    private(set) var sectionsConfiguration: SectionsConfiguration = .defaults

    /// A Boolean value that indicates whether at least one of the manager's
    /// sections is visible.
    var hasVisibleSection: Bool {
        sections.contains { !$0.isHidden }
    }

    /// Performs the initial setup of the menu bar manager.
    func performSetup(with appState: AppState) {
        self.appState = appState
        if let data = Defaults.data(forKey: .sectionsConfiguration),
           let configuration = try? JSONDecoder().decode(SectionsConfiguration.self, from: data),
           !configuration.hiddenSections.isEmpty
        {
            sectionsConfiguration = configuration
        }
        let names = [MenuBarSection.Name.visible] + sectionsConfiguration.hiddenSections.enumerated().map { index, definition in
            MenuBarSection.Name(id: definition.id, rank: index + 1, displayName: definition.displayName)
        }
        sections = names.map(MenuBarSection.init(name:))
        for definition in sectionsConfiguration.hiddenSections {
            sections.first { $0.name.id == definition.id }?.revealStyle = definition.revealStyle
        }
        publishConfiguredNames()
        configureCancellables()
        iceBarPanel.performSetup(with: appState)
        searchPanel.performSetup(with: appState)
        appearanceEditorPanel.performSetup(with: appState)
        for section in sections {
            section.performSetup(with: appState)
        }
    }

    func saveSectionsConfiguration() {
        guard let data = try? JSONEncoder().encode(sectionsConfiguration) else { return }
        Defaults.set(data, forKey: .sectionsConfiguration)
    }

    /// Applies the section configuration carried by a profile.
    func applySectionsConfiguration(_ configuration: SectionsConfiguration) async {
        guard let appState else { return }
        let retainedIDs = Set(configuration.hiddenSections.map(\.id))
        for section in sections where !section.name.isVisible && !retainedIDs.contains(section.name.id) {
            section.controlItem.removeFromMenuBar()
        }

        sectionsConfiguration = configuration
        let names = [MenuBarSection.Name.visible] + configuration.hiddenSections.enumerated().map { index, definition in
            MenuBarSection.Name(id: definition.id, rank: index + 1, displayName: definition.displayName)
        }
        var rebuilt = [MenuBarSection]()
        for name in names {
            let section = sections.first(where: { $0.name.id == name.id }) ?? MenuBarSection(name: name)
            section.name = name
            section.revealStyle = configuration.hiddenSections.first(where: { $0.id == name.id })?.revealStyle ?? .automatic
            section.performSetup(with: appState)
            rebuilt.append(section)
        }
        sections = rebuilt
        publishConfiguredNames()
        saveSectionsConfiguration()
    }

    /// Mirrors the current section list into `MenuBarSection.Name.configured`
    /// so code that runs off the main actor sees the same sections.
    private func publishConfiguredNames() {
        MenuBarSection.Name.configured = sections.map(\.name)
    }

    /// Recomputes ranks from the configuration order and sorts sections.
    private func applyRanks() {
        for (index, definition) in sectionsConfiguration.hiddenSections.enumerated() {
            sections.first { $0.name.id == definition.id }?.name.rank = index + 1
        }
        sections.sort { $0.name < $1.name }
        publishConfiguredNames()
    }

    /// Adds a new hidden section at the deepest rank.
    func addSection() {
        guard let appState else { return }
        let id = UUID().uuidString
        let definition = SectionDefinition(
            id: id,
            displayName: "New Section",
            controlItemAutosaveName: "Thaw.ControlItem.Section.\(id)",
            hotkeyActionID: "ToggleSection.\(id)"
        )
        sectionsConfiguration.hiddenSections.append(definition)
        let name = MenuBarSection.Name(id: id, rank: sectionsConfiguration.hiddenSections.count, displayName: definition.displayName)
        let section = MenuBarSection(name: name)
        sections.append(section)
        section.performSetup(with: appState)
        section.controlItem.addToMenuBar()
        if let action = name.hotkeyAction {
            appState.settings.hotkeys.addHotkey(for: action)
        }
        applyRanks()
        saveSectionsConfiguration()
        Task {
            await appState.itemManager.cacheItemsRegardless(skipRecentMoveCheck: true)
        }
    }

    /// The rank the empty bar click cycle last opened, nil when the cycle
    /// is at the start.
    private var cycleRank: Int?

    /// Clicks collected while the cycle debounce window is open.
    private var pendingCycleSteps = 0
    private var cycleDebounceTask: Task<Void, Never>?

    /// One click of the empty bar cycle. Clicks inside the double click
    /// window accumulate and land as one jump, so a fast double click goes
    /// straight to the second section without flashing the first.
    func cycleSections() {
        diagLog.debug("cycleSections: click received, pending=\(pendingCycleSteps + 1)")
        guard sectionsConfiguration.cycleWaitsForMultiClicks else {
            performCycle(steps: 1)
            if let appState {
                let names = sections.filter { !$0.name.isVisible }.map(\.name)
                Task {
                    await appState.imageCache.warmImages(sections: names)
                }
            }
            return
        }
        pendingCycleSteps += 1
        // Warm every hidden section immediately so whatever the jump lands
        // on opens with its content already rendered.
        if pendingCycleSteps == 1, let appState {
            let names = sections.filter { !$0.name.isVisible }.map(\.name)
            Task {
                await appState.imageCache.warmImages(sections: names)
            }
        }
        cycleDebounceTask?.cancel()
        let window = min(NSEvent.doubleClickInterval, 0.12)
        cycleDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(window))
            guard !Task.isCancelled, let self else { return }
            let steps = self.pendingCycleSteps
            self.pendingCycleSteps = 0
            self.performCycle(steps: steps)
        }
    }

    /// Jumps the cycle forward by the given number of steps and shows only
    /// the destination.
    private func performCycle(steps: Int) {
        diagLog.debug("performCycle: steps=\(steps) fromRank=\(cycleRank.map(String.init) ?? "none")")
        let ordered = sections
            .filter { !$0.name.isVisible && $0.isEnabled }
            .sorted { $0.name.rank < $1.name.rank }
        guard !ordered.isEmpty, steps > 0 else { return }
        // Positions run first section, next, ..., deepest, then everything
        // hidden, and wrap around.
        let cycleLength = ordered.count + 1
        let currentPosition: Int
        if let cycleRank, let index = ordered.firstIndex(where: { $0.name.rank == cycleRank }) {
            currentPosition = index + 1
        } else {
            currentPosition = 0
        }
        let target = (currentPosition + steps) % cycleLength
        if target == 0 {
            cycleRank = nil
            for section in ordered where !section.isHidden {
                section.hide()
            }
            iceBarPanel.close()
        } else {
            let destination = ordered[target - 1]
            cycleRank = destination.name.rank
            destination.show()
        }
    }

    /// Sets whether the cycle waits for extra clicks before opening.
    func setCycleWaitsForMultiClicks(_ waits: Bool) {
        sectionsConfiguration.cycleWaitsForMultiClicks = waits
        saveSectionsConfiguration()
        objectWillChange.send()
    }

    /// Sets what clicking empty menu bar space does.
    func setEmptyBarClickBehavior(_ behavior: EmptyBarClickBehavior) {
        sectionsConfiguration.emptyBarClickBehavior = behavior
        saveSectionsConfiguration()
        objectWillChange.send()
    }

    /// Chooses whether dropdown rows show app icons or captured images.
    func setDropdownShowsAppIcons(_ enabled: Bool) {
        sectionsConfiguration.dropdownShowsAppIcons = enabled
        saveSectionsConfiguration()
        objectWillChange.send()
    }

    /// Chooses whether the app icon opens one combined dropdown.
    func setIceIconOpensCombinedMenu(_ enabled: Bool) {
        sectionsConfiguration.iceIconOpensCombinedMenu = enabled
        saveSectionsConfiguration()
        objectWillChange.send()
    }

    /// Changes how a section reveals its items.
    func setRevealStyle(_ style: SectionRevealStyle, forSectionID id: String) {
        guard let index = sectionsConfiguration.hiddenSections.firstIndex(where: { $0.id == id }) else { return }
        sectionsConfiguration.hiddenSections[index].revealStyle = style
        if let section = sections.first(where: { $0.name.id == id }) {
            if !section.isHidden {
                section.hide()
            }
            section.revealStyle = style
        }
        saveSectionsConfiguration()
        objectWillChange.send()
    }

    func renameSection(id: String, to displayName: String) {
        guard let index = sectionsConfiguration.hiddenSections.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sectionsConfiguration.hiddenSections[index].displayName = trimmed
        sections.first { $0.name.id == id }?.name.displayName = trimmed
        publishConfiguredNames()
        saveSectionsConfiguration()
    }

    func moveSection(id: String, offset: Int) {
        guard let index = sectionsConfiguration.hiddenSections.firstIndex(where: { $0.id == id }) else { return }
        let newIndex = index + offset
        guard sectionsConfiguration.hiddenSections.indices.contains(newIndex) else { return }
        sectionsConfiguration.hiddenSections.swapAt(index, newIndex)
        applyRanks()
        saveSectionsConfiguration()
        // Dividers follow the new ranks and every section keeps its items.
        Task {
            await appState?.itemManager.applySectionReorder()
        }
    }

    /// Removes a section after moving its items into the next shallower one.
    /// The two default sections cannot be removed.
    func removeSection(id: String) {
        guard
            let appState,
            let section = sections.first(where: { $0.name.id == id }),
            !section.name.isDefault,
            let index = sectionsConfiguration.hiddenSections.firstIndex(where: { $0.id == id })
        else {
            return
        }
        Task {
            await appState.itemManager.relocateItems(from: section.name)
            section.controlItem.removeFromMenuBar()
            if let action = section.name.hotkeyAction {
                appState.settings.hotkeys.removeHotkey(for: action)
            }
            sectionsConfiguration.hiddenSections.remove(at: index)
            sections.removeAll { $0.name.id == id }
            applyRanks()
            saveSectionsConfiguration()
            await appState.itemManager.cacheItemsRegardless(skipRecentMoveCheck: true)
        }
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables() {
        averageColorRefreshCancellable?.cancel()
        averageColorRefreshCancellable = nil
        var c = Set<AnyCancellable>()

        NSApp.publisher(for: \.currentSystemPresentationOptions)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] options in
                guard let self else {
                    return
                }
                let hidden = options.contains(.hideMenuBar) || options.contains(.autoHideMenuBar)
                isMenuBarHiddenBySystem = hidden
            }
            .store(in: &c)

        if
            let hiddenSection = section(withName: .alwaysHidden),
            let window = hiddenSection.controlItem.window
        {
            window.publisher(for: \.frame)
                .map { $0.origin.y }
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard
                        let self,
                        let isMenuBarHidden = Defaults.globalDomain["_HIHideMenuBar"] as? Bool
                    else {
                        return
                    }
                    isMenuBarHiddenBySystemUserDefaults = isMenuBarHidden
                }
                .store(in: &c)
        }

        // Handle the `focusedApp` and `smart` rehide strategies.
        NSWorkspace.shared.publisher(for: \.frontmostApplication)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                if
                    let self,
                    let appState,
                    let hiddenSection = section(withName: .hidden),
                    let screen = appState.hidEventManager.bestScreen(appState: appState),
                    !appState.hidEventManager.isMouseInsideMenuBar(appState: appState, screen: screen),
                    !appState.hidEventManager.isMouseInsideIceBar(appState: appState),
                    appState.settings.general.autoRehide
                {
                    // Handle both focusedApp and smart strategies for focus changes
                    switch appState.settings.general.rehideStrategy {
                    case .focusedApp, .smart:
                        Task {
                            // Add delay for smart strategy to allow app focus to settle
                            let delay: TimeInterval = appState.settings.general.rehideStrategy == .smart ? 0.25 : 0.1
                            try await Task.sleep(for: .seconds(delay))

                            // Ignore rehide requests for a short grace period after showing.
                            if let lastShow = self.lastShowTimestamp,
                               lastShow.duration(to: .now) < .milliseconds(500)
                            {
                                self.diagLog.debug("Skipping rehide due to grace period")
                                return
                            }

                            // Check if any menu bar item has a menu open (for smart strategy)
                            if appState.settings.general.rehideStrategy == .smart {
                                if await appState.itemManager.isAnyMenuBarItemMenuOpen() {
                                    return
                                }
                            }

                            hiddenSection.hide()
                        }
                    default:
                        break
                    }
                }
            }
            .store(in: &c)

        appState?.publisherForWindow(.settings)
            .sink { [weak self] window in
                self?.settingsWindow = window
            }
            .store(in: &c)

        if let appState {
            appState.settings.displaySettings.$configurations
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.updateControlItemStates()
                }
                .store(in: &c)
        }

        $settingsWindow
            .removeNil()
            .map { $0.publisher(for: \.isVisible) }
            .switchToLatest()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isVisible in
                guard let self else { return }
                if isVisible {
                    updateAverageColorInfo()
                    // Start a visibility-gated 60s refresh to catch wallpaper changes
                    // (macOS no longer posts a wallpaper change notification).
                    averageColorRefreshCancellable = Timer.publish(every: 60, tolerance: 10, on: .main, in: .default)
                        .autoconnect()
                        .sink { [weak self] _ in
                            self?.updateAverageColorInfo()
                        }
                } else {
                    averageColorRefreshCancellable?.cancel()
                    averageColorRefreshCancellable = nil
                }
            }
            .store(in: &c)

        // Hide application menus when a section is shown (if applicable).
        Publishers.MergeMany(sections.map { $0.controlItem.$state })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let appState else {
                    return
                }

                // Don't continue if:
                //   * The "HideApplicationMenus" setting isn't enabled.
                //   * Using the Ice Bar.
                //   * The menu bar is hidden by the system.
                //   * The active space is fullscreen.
                //   * The settings window is visible.
                guard
                    appState.settings.advanced.hideApplicationMenus,
                    !appState.settings.displaySettings.configurationForActiveDisplay().useIceBar,
                    !isMenuBarHiddenBySystem,
                    !appState.activeSpace.isFullscreen,
                    !appState.navigationState.isSettingsPresented
                else {
                    return
                }

                // The deepest section currently shown decides how far the
                // menu bar expands. Shown means isHidden is false.
                let deepestShown = self.sections
                    .filter { !$0.name.isVisible && !$0.isHidden }
                    .max { $0.name.rank < $1.name.rank }

                if let deepestShown {
                    // Use the screen with the active menu bar
                    guard let screen = NSScreen.screenWithActiveMenuBar ?? NSScreen.main else {
                        return
                    }

                    Task {
                        // The window server needs time to update window positions after expansion.
                        try? await Task.sleep(for: .milliseconds(50))

                        // Get the app menu frame for this screen
                        guard let appMenuFrame = screen.getApplicationMenuFrame() else {
                            return
                        }

                        // Get ALL menu bar items
                        let allItems = await MenuBarItem.getMenuBarItems(option: .activeSpace)

                        // Filter to items on THIS screen by comparing Y coordinate with app menu's Y
                        let menuBarY = appMenuFrame.origin.y
                        let screenItems = allItems.filter { item in
                            abs(item.bounds.origin.y - menuBarY) < 50
                        }

                        // The shown section's divider on this screen, and the
                        // width of the items it reveals.
                        var controlBounds: CGRect = .zero
                        var hiddenItemsWidth: CGFloat = 0
                        let dividerTag = MenuBarItemTag(controlItem: deepestShown.name.controlItemIdentifier)
                        if let control = screenItems.first(where: { $0.tag == dividerTag }) {
                            controlBounds = control.bounds
                            if let appState = self.appState {
                                hiddenItemsWidth = appState.itemManager.itemCache[deepestShown.name].reduce(0) { $0 + $1.bounds.width }
                            }
                        }

                        // The hidden section expands by replacing control item with hidden items
                        // New rightmost = where hidden items end = control.minX + hiddenItemsWidth
                        let newRightmostPos = controlBounds.minX + hiddenItemsWidth

                        // Use the actual app menu frame for needed space
                        let appMenuRightStart = appMenuFrame.maxX

                        // Available space: if app menu extends into notch, add notch width; otherwise use visible frame
                        let spaceAvailableFromAppMenuEnd: CGFloat
                        if let notch = screen.frameOfNotch {
                            if appMenuRightStart > notch.minX {
                                // App menu extends into notch, items get moved past notch
                                spaceAvailableFromAppMenuEnd = (notch.minX - appMenuRightStart) + (screen.visibleFrame.maxX - notch.maxX)
                            } else {
                                // App menu doesn't extend into notch
                                spaceAvailableFromAppMenuEnd = screen.visibleFrame.maxX - appMenuRightStart
                            }
                        } else {
                            spaceAvailableFromAppMenuEnd = screen.visibleFrame.maxX - appMenuRightStart
                        }

                        let spaceNeededFromAppMenuEnd = newRightmostPos - appMenuRightStart

                        // If items would extend past screen edge, hide the app menu
                        if spaceNeededFromAppMenuEnd > spaceAvailableFromAppMenuEnd {
                            self.hideApplicationMenus()
                        }
                    }
                } else if isHidingApplicationMenus, !isManuallyHidingApplicationMenus {
                    showApplicationMenus()
                }
            }
            .store(in: &c)

        cancellables = c
    }

    /// Updates the ``averageColorInfo`` property with the current average color
    /// of the menu bar.
    func updateAverageColorInfo() {
        guard let appState else { return }

        // Only update if we really need the color info
        let isSettingsVisible = settingsWindow?.isVisible == true
        let isIceBarVisible = appState.navigationState.isIceBarPresented
        let isSearchVisible = appState.navigationState.isSearchPresented
        let anyIceBarEnabled = appState.settings.displaySettings.isIceBarEnabledOnAnyDisplay

        guard isSettingsVisible || isIceBarVisible || isSearchVisible || anyIceBarEnabled else {
            return
        }

        guard
            let settingsWindow,
            settingsWindow.isVisible,
            let screen = settingsWindow.screen
        else {
            return
        }

        let windows = WindowInfo.createWindows(option: .onScreen)
        let displayID = screen.displayID

        guard
            let menuBarWindow = WindowInfo.menuBarWindow(from: windows, for: displayID),
            let wallpaperWindow = WindowInfo.wallpaperWindow(from: windows, for: displayID)
        else {
            return
        }

        guard
            let image = ScreenCapture.captureWindows(
                with: [menuBarWindow.windowID, wallpaperWindow.windowID],
                screenBounds: withMutableCopy(of: wallpaperWindow.bounds) { $0.size.height = 1 },
                option: .nominalResolution
            ),
            let color = image.averageColor(option: .ignoreAlpha)
        else {
            return
        }

        let info = MenuBarAverageColorInfo(color: color, source: .menuBarWindow)

        if averageColorInfo != info {
            averageColorInfo = info
        }
    }

    /// Returns a Boolean value that indicates whether the given display
    /// has a valid menu bar.
    func hasValidMenuBar(in windows: [WindowInfo], for display: CGDirectDisplayID) -> Bool {
        guard
            let window = WindowInfo.menuBarWindow(from: windows, for: display),
            let element = AXHelpers.element(at: window.bounds.origin)
        else {
            return false
        }
        return AXHelpers.role(for: element) == .menuBar
    }

    /// Shows the secondary context menu.
    /// Builders kept alive while the secondary context menu is open.
    private var contextMenuBuilders: [SectionDropdownMenu] = []

    func showSecondaryContextMenu(at point: CGPoint) {
        let menu = NSMenu(title: "\(Constants.displayName)")

        // Every section first, as a submenu of its items, so a menu bar with
        // no chevrons and no icon still reaches each section by mouse.
        if let appState {
            let combined = SectionDropdownMenu.makeCombinedMenu(appState: appState)
            contextMenuBuilders = combined.builders
            for item in combined.menu.items {
                combined.menu.removeItem(item)
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let editAppearanceItem = NSMenuItem(
            title: String(localized: "Edit Menu Bar Appearance…"),
            action: #selector(showAppearanceEditorPanel),
            keyEquivalent: ""
        )
        editAppearanceItem.image = NSImage(systemSymbolName: "swatchpalette", accessibilityDescription: "Edit Appearance")
        editAppearanceItem.target = self
        menu.addItem(editAppearanceItem)

        let editLayoutItem = NSMenuItem(
            title: String(localized: "Edit Menu Bar Layout…"),
            action: #selector(showMenuBarLayoutSettings),
            keyEquivalent: ""
        )
        editLayoutItem.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Edit Layout")
        editLayoutItem.target = self
        menu.addItem(editLayoutItem)

        // Profiles submenu.
        if let appState, !appState.profileManager.profiles.isEmpty {
            menu.addItem(.separator())

            let profilesItem = NSMenuItem(
                title: String(localized: "Profiles"),
                action: nil,
                keyEquivalent: ""
            )
            profilesItem.image = NSImage(
                systemSymbolName: "person.crop.rectangle.stack",
                accessibilityDescription: "Profiles"
            )
            let profilesMenu = NSMenu()
            for meta in appState.profileManager.profiles {
                let item = NSMenuItem(
                    title: meta.name,
                    action: #selector(applyProfileFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = meta.id
                if meta.id == appState.profileManager.activeProfileID {
                    item.state = .on
                }
                profilesMenu.addItem(item)
            }
            profilesItem.submenu = profilesMenu
            menu.addItem(profilesItem)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: String(localized: "\(Constants.displayName) Settings…"),
            action: #selector(AppDelegate.openSettingsWindow),
            keyEquivalent: ","
        )
        settingsItem.image = NSImage(systemSymbolName: "gear", accessibilityDescription: "Settings")
        menu.addItem(settingsItem)

        menu.popUp(positioning: nil, at: point, in: nil)
    }

    @objc private func applyProfileFromMenu(_ menuItem: NSMenuItem) {
        guard
            let profileID = menuItem.representedObject as? UUID,
            let appState,
            appState.profileManager.layoutTask == nil,
            profileID != appState.profileManager.activeProfileID
        else { return }
        Task { [weak self] in
            do {
                let profile = try appState.profileManager.loadProfile(id: profileID)
                appState.profileManager.activeProfileID = profileID
                appState.profileManager.applyProfile(profile, to: appState)
            } catch {
                self?.diagLog.error("Failed to apply profile \(profileID): \(error)")
            }
        }
    }

    /// Hides the application menus.
    ///
    /// - Important: Uses `.regular` activation policy to hide menus, which briefly shows the app in the Dock.
    func hideApplicationMenus(manual: Bool = false) {
        guard let appState else {
            diagLog.error("Error hiding application menus: Missing app state")
            return
        }

        if isHidingApplicationMenus {
            return
        }

        diagLog.info("Hiding application menus")
        isHidingApplicationMenus = true
        if manual {
            isManuallyHidingApplicationMenus = true
        }

        // Ensure this happens on the main thread
        Task { @MainActor in
            guard isHidingApplicationMenus else { return }

            appState.activate(withPolicy: .regular)

            // Force activation again after a micro-delay.
            // The first activation after policy change can sometimes be ignored by the system.
            try? await Task.sleep(for: .milliseconds(25))
            guard isHidingApplicationMenus else { return }
            appState.activate()
        }
    }

    /// Shows the application menus.
    func showApplicationMenus() {
        guard let appState else {
            diagLog.error("Error showing application menus: Missing app state")
            return
        }
        diagLog.info("Showing application menus")
        appState.deactivate(withPolicy: .accessory)
        isHidingApplicationMenus = false
        isManuallyHidingApplicationMenus = false
    }

    /// Toggles the visibility of the application menus.
    func toggleApplicationMenus() {
        if isHidingApplicationMenus {
            showApplicationMenus()
        } else {
            hideApplicationMenus(manual: true)
        }
    }

    /// Shows the menu bar layout settings pane.
    @objc private func showMenuBarLayoutSettings() {
        guard let appState else {
            return
        }
        appState.navigationState.settingsNavigationIdentifier = .menuBarLayout
        appState.activate(withPolicy: .regular)
        appState.openWindow(.settings)
    }

    /// Shows the appearance editor panel.
    @objc private func showAppearanceEditorPanel() {
        guard let screen = MenuBarAppearanceEditorPanel.defaultScreen else {
            return
        }
        appearanceEditorPanel.show(on: screen) {
            self.dismissAppearanceEditorPanel()
        }
    }

    /// Dismisses the appearance editor panel if it is shown.
    func dismissAppearanceEditorPanel() {
        appearanceEditorPanel.close()
    }

    /// Updates the ``lastShowTimestamp`` property.
    func updateLastShowTimestamp() {
        lastShowTimestamp = .now
    }

    /// Updates the control item states for all sections.
    ///
    /// - Parameter screen: The screen to use for the update. If `nil`, the
    ///   best screen is determined automatically.
    func updateControlItemStates(for screen: NSScreen? = nil) {
        for section in sections {
            section.updateControlItemState(for: screen)
        }
    }

    /// Returns the menu bar section with the given name.
    func section(withName name: MenuBarSection.Name) -> MenuBarSection? {
        sections.first { $0.name == name }
    }

    /// Returns the control item for the menu bar section with the given name.
    func controlItem(withName name: MenuBarSection.Name) -> ControlItem? {
        section(withName: name)?.controlItem
    }
}

// MARK: - MenuBarAverageColorInfo

/// Information for the average color of the menu bar.
struct MenuBarAverageColorInfo: Hashable {
    /// Sources used to compute the average color of the menu bar.
    enum Source: Hashable {
        case menuBarWindow
        case desktopWallpaper
    }

    /// The average color of the menu bar
    var color: CGColor

    /// The source used to compute the color.
    var source: Source

    /// The brightness of the menu bar's color.
    var brightness: CGFloat {
        color.brightness ?? 0
    }

    /// A Boolean value that indicates whether the menu bar has a
    /// bright color.
    ///
    /// This value is `true` if ``brightness`` is above `0.67`. At
    /// the time of writing, if this value is `true`, the menu bar
    /// draws its items with a darker appearance.
    var isBright: Bool {
        brightness > 0.67
    }
}
