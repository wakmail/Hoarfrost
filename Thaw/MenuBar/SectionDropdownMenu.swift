//
//  SectionDropdownMenu.swift
//  Project: Hoarfrost
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Copyright (Hoarfrost) © 2026 Preston Chen
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

    /// Row image height in points.
    private static let rowImageHeight: CGFloat = 16

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

        // Refresh images in the background so the next opening is current.
        Task {
            await appState.imageCache.updateCache(sections: [sectionName])
        }
        return menu
    }

    /// Presents the menu under the given control item.
    func show(from controlItem: ControlItem) {
        controlItem.present(makeMenu())
    }

    /// The captured image of the item scaled to row height, falling back to
    /// the owning app's icon when no capture exists yet.
    private func rowImage(for item: MenuBarItem) -> NSImage? {
        guard let appState else { return nil }
        let height = Self.rowImageHeight
        if let captured = appState.imageCache.image(for: item.tag) {
            let image = captured.nsImage
            let size = captured.scaledSize
            guard size.height > 0 else { return image }
            image.size = CGSize(width: size.width * height / size.height, height: height)
            return image
        }
        if let url = item.sourceApplication?.bundleURL ?? item.owningApplication?.bundleURL {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = CGSize(width: height, height: height)
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
