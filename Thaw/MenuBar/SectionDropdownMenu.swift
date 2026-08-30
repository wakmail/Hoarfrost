//
//  SectionDropdownMenu.swift
//  Project: Hoarfrost
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Copyright (Hoarfrost) © 2026 wakmail
//  Licensed under the GNU GPLv3

import Cocoa

/// A real dropdown menu listing the items of one section: a menu bar app
/// for menu bar apps.
///
/// macOS offers no way to place another app's status item inside a menu, so
/// each row shows the item's captured image and name. Choosing a row briefly
/// shows the real item and clicks it, the same trick the Ice Bar uses.
@MainActor
final class SectionDropdownMenu: NSObject {
    private static let diagLog = DiagLog(category: "SectionDropdownMenu")

    /// Largest row image height in points. Captured images keep their own
    /// size below this so they look like they do in the menu bar.
    private static let maxRowImageHeight: CGFloat = 22

    private weak var appState: AppState?
    private let sectionName: MenuBarSection.Name

    init(appState: AppState, sectionName: MenuBarSection.Name) {
        self.appState = appState
        self.sectionName = sectionName
    }

    /// Builds the menu from the current item and image caches.
    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: sectionName.displayName)
        menu.autoenablesItems = false

        guard let appState else {
            return menu
        }

        let items = appState.itemManager.itemCache[sectionName]
        if items.isEmpty {
            let empty = NSMenuItem(title: String(localized: "No items in this section"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }

        for item in items {
            let row = NSMenuItem(title: item.displayName, action: #selector(activate(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = item
            row.image = rowImage(for: item)
            menu.addItem(row)
        }

        // Refresh every hidden section in the background so whatever opens
        // next, dropdown or bar, has current images waiting.
        let names = appState.menuBarManager.sections.filter { !$0.name.isVisible }.map(\.name)
        Task {
            await appState.imageCache.warmImages(sections: names)
        }
        return menu
    }

    /// Presents the menu under the given control item.
    func show(from controlItem: ControlItem) {
        controlItem.present(makeMenu())
    }

    /// Builds one menu with a submenu per hidden section.
    ///
    /// Returns the per section builders alongside the menu; the caller must
    /// keep them alive while the menu is open because menu items hold their
    /// targets weakly.
    static func makeCombinedMenu(appState: AppState) -> (menu: NSMenu, builders: [SectionDropdownMenu]) {
        let menu = NSMenu(title: Constants.displayName)
        menu.autoenablesItems = false
        var builders = [SectionDropdownMenu]()
        for section in appState.menuBarManager.sections where !section.name.isVisible && section.isEnabled {
            let builder = SectionDropdownMenu(appState: appState, sectionName: section.name)
            builders.append(builder)
            let row = NSMenuItem(title: section.name.displayName, action: nil, keyEquivalent: "")
            row.submenu = builder.makeMenu()
            menu.addItem(row)
        }
        if builders.isEmpty {
            let empty = NSMenuItem(title: String(localized: "No sections"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        return (menu, builders)
    }

    /// The captured image of the item scaled to row height, falling back to
    /// the owning app's icon when no capture exists yet.
    private func rowImage(for item: MenuBarItem) -> NSImage? {
        guard let appState else { return nil }
        let maxHeight = Self.maxRowImageHeight
        let wantsAppIcon = appState.menuBarManager.sectionsConfiguration.dropdownShowsAppIcons
        if !wantsAppIcon, let captured = appState.imageCache.image(for: item.tag) {
            let image = captured.nsImage
            let size = captured.scaledSize
            if size.height > maxHeight {
                image.size = CGSize(width: size.width * maxHeight / size.height, height: maxHeight)
            }
            return image
        }
        if let url = item.sourceApplication?.bundleURL ?? item.owningApplication?.bundleURL {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = CGSize(width: maxHeight, height: maxHeight)
            return icon
        }
        return nil
    }

    @objc private func activate(_ sender: NSMenuItem) {
        guard
            let appState,
            let item = sender.representedObject as? MenuBarItem
        else {
            return
        }
        let itemManager = appState.itemManager
        let displayID = Bridging.getActiveMenuBarDisplayID()
        Self.diagLog.debug("activate: \(item.logString)")
        Task {
            // Let the menu finish closing before events are posted.
            try? await Task.sleep(for: .milliseconds(25))
            if Bridging.isWindowOnScreen(item.windowID) {
                try? await itemManager.click(item: item, with: .left)
            } else {
                await itemManager.temporarilyShow(item: item, clickingWith: .left, on: displayID, fastPath: true)
            }
        }
    }
}
