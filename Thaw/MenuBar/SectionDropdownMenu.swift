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

    /// Row image height in points. Sized to read like the menu bar without
    /// inflating the menu's row spacing.
    private static let rowImageHeight: CGFloat = 20

    private weak var appState: AppState?
    private let sectionName: MenuBarSection.Name

    /// A menu built ahead of time so the first open presents instantly.
    private var prebuiltMenu: NSMenu?

    /// The dropdown currently on screen, if any.
    private(set) static weak var openMenu: NSMenu?

    /// Hides the open dropdown immediately, skipping the fade out.
    static func dismissOpenMenuInstantly() {
        openMenu?.cancelTrackingWithoutAnimation()
        openMenu = nil
    }

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

        let rowFont = NSFont.menuFont(ofSize: NSFont.systemFontSize + 1)
        for item in items {
            let row = NSMenuItem(title: "", action: #selector(activate(_:)), keyEquivalent: "")
            row.attributedTitle = NSAttributedString(string: item.displayName, attributes: [.font: rowFont])
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
    ///
    /// Waits for the mouse button to be released first. Popping while the
    /// button is still down hands the menu a tracking session that the
    /// imminent mouse up ends, so it appears and immediately fades away.
    func show(from controlItem: ControlItem) {
        let menu = prebuiltMenu ?? makeMenu()
        prebuiltMenu = nil
        Task { @MainActor [weak self, weak appState] in
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
            while NSEvent.pressedMouseButtons != 0, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(8))
            }
            guard let self, let appState else { return }
            let manager = appState.menuBarManager
            Self.openMenu = menu
            manager.openDropdownRank = self.sectionName.rank
            controlItem.present(menu)
            manager.openDropdownRank = nil
            manager.lastDropdownDismissal = (self.sectionName.rank, Date.now)
            Self.openMenu = nil
            // Rebuild for the next open now that current images are in.
            self.prebuiltMenu = self.makeMenu()
        }
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
        let height = Self.rowImageHeight
        let wantsAppIcon = appState.menuBarManager.sectionsConfiguration.dropdownShowsAppIcons
        if !wantsAppIcon, let captured = appState.imageCache.image(for: item.tag) {
            // The capture includes the item's transparent padding; trim it
            // so the glyph itself fills the row height like an app icon.
            let cgImage = captured.cgImage.trimmedToOpaqueBounds() ?? captured.cgImage
            let size = CGSize(width: CGFloat(cgImage.width) / captured.scale, height: CGFloat(cgImage.height) / captured.scale)
            let image = NSImage(cgImage: cgImage, size: size)
            if size.height > 0 {
                // Downscale only. Blowing a small glyph up to the row height
                // makes it look thick and soft.
                let target = min(height, size.height)
                image.size = CGSize(width: size.width * target / size.height, height: target)
            }
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

private extension CGImage {
    /// The image cropped to the smallest rectangle containing every pixel
    /// with meaningful alpha, or nil when the image is fully transparent or
    /// unreadable. One point of padding is kept on every side.
    func trimmedToOpaqueBounds() -> CGImage? {
        let width = self.width
        let height = self.height
        guard width > 0, height > 0 else { return nil }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ) else {
            return nil
        }
        context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0 ..< height {
            let rowStart = y * width
            for x in 0 ..< width where pixels[rowStart + x] > 16 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let rect = CGRect(
            x: max(0, minX - 1),
            y: max(0, minY - 1),
            width: min(width, maxX - minX + 3),
            height: min(height, maxY - minY + 3)
        )
        return cropping(to: rect)
    }
}
