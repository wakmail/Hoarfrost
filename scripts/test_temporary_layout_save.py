#!/usr/bin/env python3
"""Verify temporary return moves cannot overwrite the permanent layout."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
path = 'Thaw/MenuBar/MenuBarItems/MenuBarItemManager.swift'
source = subprocess.check_output(['git', 'show', sys.argv[1] + ':' + path], cwd=root, text=True) if len(sys.argv) > 1 else (root / path).read_text()
method = source[source.index('    private func saveSectionOrder('):source.index('    /// Returns a persistable string key')]
method = method.replace('private func', 'func')
setup = source[source.index('    func performSetup(with appState:'):source.index('        configureCancellables(with: appState)')] + '    }\n'
program = r'''
import Foundation
enum MenuBarSection {
    enum Name: String, CaseIterable { case visible, hidden, alwaysHidden }
}
struct Tag { var namespace: String; var title = "Item"; var instanceIndex = 0 }
struct Item {
    var tag: Tag
    var isControlItem = false
    var uniqueIdentifier: String { "\(tag.namespace):\(tag.title)" }
}
struct ItemCache {
    var items: [MenuBarSection.Name: [Item]] = [:]
    subscript(_ section: MenuBarSection.Name) -> [Item] { items[section] ?? [] }
    var managedItems: [Item] { items.values.flatMap { $0 } }
}
struct Section { var name: MenuBarSection.Name }
struct BarManager { var sections = MenuBarSection.Name.allCases.map { Section(name: $0) } }
struct AppState { var menuBarManager = BarManager() }
struct Log { func debug(_ text: String) {} }
struct MouseHelpers { static func startMonitoringUserMovement() {} }
final class MenuBarItemManager {
    static let diagLog = Log()
    var appState: AppState? = AppState()
    var rehideInProgress = false
    var isInStartupSettling = false
    var knownItemIdentifiers: Set<String> = ["known"]
    var pinnedHiddenBundleIDs = Set<String>()
    var pinnedAlwaysHiddenBundleIDs = Set<String>()
    var suppressNextNewLeftmostItemRelocation = false
    var itemCache = ItemCache()
    func loadKnownItemIdentifiers() {}
    func loadPinnedBundleIDs() {}
    func loadPendingRelocations() {}
    func loadSavedSectionOrder() {}
    func loadNewItemsPlacementPreference() {}
    func cacheItemsRegardless() async {
        if !isInStartupSettling { saveSectionOrder(from: itemCache) }
    }
    var savedSectionOrder: [String: [String]] = [:]
    var triggerControlledIdentifiers = Set<String>()
    var writes = 0
    func persistSavedSectionOrder() { writes += 1 }
    func sectionName(for key: String) -> MenuBarSection.Name? { .init(rawValue: key) }
    func sectionKey(for section: MenuBarSection.Name) -> String { section.rawValue }
'''+method+setup+r'''
}
@main struct Checks {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { print("FAIL: " + message); exit(1) }
    }
    static func main() async {
        let manager = MenuBarItemManager()
        let snitch = Item(tag: Tag(namespace: "LittleSnitch"))
        let neighbor = Item(tag: Tag(namespace: "Neighbor"))
        let visible = Item(tag: Tag(namespace: "VisibleApp"))
        let permanent = ["visible": [visible.uniqueIdentifier], "hidden": [neighbor.uniqueIdentifier, snitch.uniqueIdentifier]]
        manager.savedSectionOrder = permanent
        let revealed = ItemCache(items: [.visible: [visible, snitch], .hidden: [neighbor]])
        manager.rehideInProgress = true
        for _ in 0..<3 { manager.saveSectionOrder(from: revealed) }
        expect(manager.savedSectionOrder == permanent && manager.writes == 0,
               "A cache during failed return attempts must not save Little Snitch as visible")
        manager.rehideInProgress = false
        let returned = ItemCache(items: [.visible: [visible], .hidden: [neighbor, snitch]])
        manager.saveSectionOrder(from: returned)
        expect(manager.savedSectionOrder == permanent && manager.writes == 0,
               "Successful return must retain the original layout")
        manager.saveSectionOrder(from: revealed)
        expect(manager.savedSectionOrder["visible"] == [visible.uniqueIdentifier, snitch.uniqueIdentifier] && manager.writes == 1,
               "An intentional move outside a return must still save normally")
        manager.savedSectionOrder = permanent
        manager.itemCache = revealed
        let previousWrites = manager.writes
        await manager.performSetup(with: AppState())
        expect(manager.savedSectionOrder == permanent && manager.writes == previousWrites,
               "Startup must protect the saved layout before reading visible physical positions")
        print("PASS: temporary return snapshots, repeated failures, successful return, intentional edits, and startup preservation")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='hoarfrost-temporary-layout-test-') as folder:
    work = Path(folder)
    (work / 'Checks.swift').write_text(program)
    subprocess.run(['swiftc', '-parse-as-library', str(work / 'Checks.swift'), '-o', str(work / 'checks')], check=True)
    subprocess.run([str(work / 'checks')], check=True)
