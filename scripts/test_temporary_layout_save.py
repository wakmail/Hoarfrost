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
if 'func recordLayoutMove(' in method:
    method = method[:method.index('    /// Only a completed native drag')]
method = method.replace('private func', 'func')
if 'allowingChangesTo' not in method:
    method = method.replace('from cache: ItemCache)', 'from cache: ItemCache, allowingChangesTo edited: Set<String> = [])')
    method += '    func recordLayoutMove(item: Item, to destination: MoveDestination, section: MenuBarSection.Name) {}\n'

relocate_start = source.index('    func relocateItems(from section:')
relocate = source[relocate_start:source.index('        var items =', relocate_start)] + '    }\n'
setup = source[source.index('    func performSetup(with appState:'):source.index('        configureCancellables(with: appState)')] + '    }\n'
program = r'''
import Foundation
enum MenuBarSection {
    enum Name: String, CaseIterable {
        case visible, hidden, alwaysHidden
        var id: String { rawValue }
        var rank: Int { Self.allCases.firstIndex(of: self)! }
        var isVisible: Bool { self == .visible }
    }
}
struct Tag { var namespace: String; var title = "Item"; var instanceIndex = 0 }
struct Item {
    var tag: Tag
    var isControlItem = false
    var uniqueIdentifier: String { "\(tag.namespace):\(tag.title)" }
}
typealias MenuBarItem = Item
enum MoveDestination {
    case leftOfItem(Item), rightOfItem(Item)
    var targetItem: Item { switch self { case .leftOfItem(let item), .rightOfItem(let item): item } }
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
'''+method+setup+relocate+r'''
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
        expect(manager.savedSectionOrder == permanent && manager.writes == 0,
               "A background reading must not move saved icons even outside a temporary return")
        manager.recordLayoutMove(item: snitch, to: .rightOfItem(visible), section: .visible)
        expect(manager.savedSectionOrder["visible"] == [visible.uniqueIdentifier, snitch.uniqueIdentifier] && manager.writes == 1,
               "An intentional move outside a return must still save normally")
        manager.savedSectionOrder = permanent
        manager.itemCache = revealed
        let previousWrites = manager.writes
        await manager.performSetup(with: AppState())
        expect(manager.savedSectionOrder == permanent && manager.writes == previousWrites,
               "Startup must protect the saved layout before reading visible physical positions")
        // Arbitrary partial snapshots must never change an established layout.
        let icons = (0..<8).map { Item(tag: Tag(namespace: "App\($0)")) }
        let original = ["visible": Array(icons[0..<2]).map(\.uniqueIdentifier),
                        "hidden": Array(icons[2..<5]).map(\.uniqueIdentifier),
                        "alwaysHidden": Array(icons[5..<8]).map(\.uniqueIdentifier)]
        manager.savedSectionOrder = original
        var seed: UInt64 = 42
        func next() -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int(seed >> 33) }
        for _ in 0..<3000 {
            var scrambled = ItemCache()
            for item in icons.sorted(by: { $0.uniqueIdentifier > $1.uniqueIdentifier }) {
                let placement = next() % 4
                if placement < 3 { scrambled.items[MenuBarSection.Name.allCases[placement], default: []].append(item) }
            }
            manager.saveSectionOrder(from: scrambled)
            expect(manager.savedSectionOrder == original, "Partial or scrambled readings must preserve every saved placement")
        }
        // Discover new apps without moving existing or closed apps.
        let newcomer = Item(tag: Tag(namespace: "NewApp"))
        manager.saveSectionOrder(from: ItemCache(items: [.visible: [icons[4], newcomer, icons[0]], .hidden: [icons[1]]]))
        expect(manager.savedSectionOrder["hidden"] == original["hidden"], "New arrivals must not rewrite hidden items")
        expect(manager.savedSectionOrder["alwaysHidden"] == original["alwaysHidden"], "Closed apps must retain their order")
        expect(manager.savedSectionOrder["visible"] == [newcomer.uniqueIdentifier] + original["visible"]!, "New apps should be inserted by their surviving neighbor")
        // Only the native drag target is allowed to change in a bad snapshot.
        manager.savedSectionOrder = original
        manager.saveSectionOrder(from: ItemCache(items: [.visible: [icons[3], icons[4], icons[0], icons[1]]]),
                                 allowingChangesTo: [icons[3].uniqueIdentifier])
        expect(manager.savedSectionOrder["visible"] == [icons[3].uniqueIdentifier, icons[0].uniqueIdentifier, icons[1].uniqueIdentifier], "Native drag saves only its target")
        expect(manager.savedSectionOrder["hidden"] == [icons[2].uniqueIdentifier, icons[4].uniqueIdentifier], "Other visible readings must not escape hidden")
        // Explicit group moves must retain their selected order and survive recaching.
        manager.savedSectionOrder = original
        for item in [icons[2], icons[3]] {
            manager.recordLayoutMove(item: item, to: .leftOfItem(icons[0]), section: .visible)
        }
        let edited = manager.savedSectionOrder
        expect(edited["visible"] == [icons[2], icons[3], icons[0], icons[1]].map(\.uniqueIdentifier), "Group edits retain order")
        manager.saveSectionOrder(from: ItemCache(items: [.alwaysHidden: icons]))
        expect(manager.savedSectionOrder == edited, "A stale refresh cannot undo an explicit edit")
        manager.recordLayoutMove(item: icons[2], to: .rightOfItem(icons[1]), section: .visible)
        expect(manager.savedSectionOrder["visible"] == [icons[3], icons[0], icons[1], icons[2]].map(\.uniqueIdentifier), "Within section edits work")
        manager.savedSectionOrder = ["hidden": ["App2:Item:1"]]
        manager.saveSectionOrder(from: ItemCache(items: [.visible: [icons[2]]]))
        expect(manager.savedSectionOrder == ["hidden": [icons[2].uniqueIdentifier]], "Recreated identity must retain its section")
        manager.savedSectionOrder = original
        manager.triggerControlledIdentifiers = [icons[2].uniqueIdentifier]
        manager.saveSectionOrder(from: ItemCache(items: [.visible: [icons[2]]]))
        expect(manager.savedSectionOrder == original, "Automation observations must not overwrite permanent placement")
        manager.savedSectionOrder = original
        await manager.relocateItems(from: .hidden)
        expect(manager.savedSectionOrder["hidden"] == nil, "Section deletion removes the old saved section")
        expect(manager.savedSectionOrder["visible"] == original["hidden"]! + original["visible"]!, "Section deletion transfers closed apps too")
        let beforeCancellation = manager.savedSectionOrder
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            manager.saveSectionOrder(from: ItemCache(items: [.alwaysHidden: [newcomer]]))
        }.value
        expect(manager.savedSectionOrder == beforeCancellation, "Cancelled refreshes cannot write layout preferences")
        print("PASS: section deletion, cancelled refreshes, 3000 scrambled snapshots, temporary returns, startup, closed apps, new apps, native drag isolation, explicit edits, groups, recreated identities, and automation")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='hoarfrost-temporary-layout-test-') as folder:
    work = Path(folder)
    (work / 'Checks.swift').write_text(program)
    subprocess.run(['swiftc', '-parse-as-library', str(work / 'Checks.swift'), '-o', str(work / 'checks')], check=True)
    subprocess.run([str(work / 'checks')], check=True)
