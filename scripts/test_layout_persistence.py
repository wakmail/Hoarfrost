#!/usr/bin/env python3
"""Exercise the production native drag completion handler without moving the pointer."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Thaw/Events/HIDEventManager.swift').read_text()
handler = source[source.index('    private func handleMenuBarItemDragStop()'):source.index('    // MARK: Handle Menu Bar Item Drag Start')]
handler = handler.replace('private func', 'func').replace('.milliseconds(500)', '.milliseconds(10)')
program = r'''
import Foundation
@MainActor final class ItemManager {
    var saved: [String] = []
    var refreshes = 0
    var duringRefresh: (() -> Void)?
    func recordExternalMoveOperation() {}
    func cacheItemsRegardless(skipRecentMoveCheck: Bool) async {
        refreshes += 1
        duringRefresh?()
    }
    func saveExternalMove(of identifier: String) { saved.append(identifier) }
}
@MainActor final class AppState {
    let itemManager = ItemManager()
    var dragging: (() -> Bool)?
    var isDraggingMenuBarItem: Bool { dragging?() ?? false }
}
@MainActor final class HIDEventManager {
    var appState: AppState?
    var draggedItemIdentifier: String?
    var dragGeneration: UInt64 = 0
    var isDraggingMenuBarItem = false
''' + handler + r'''
}
@main struct Checks {
    @MainActor static func main() async throws {
        let app = AppState()
        let hid = HIDEventManager()
        hid.appState = app
        app.dragging = { [weak hid] in hid?.isDraggingMenuBarItem ?? false }
        func start(_ id: String?) {
            hid.dragGeneration += 1
            hid.draggedItemIdentifier = id
            hid.isDraggingMenuBarItem = true
        }
        func settle() async throws { try await Task.sleep(for: .milliseconds(50)) }
        func check(_ value: Bool, _ message: String) {
            guard value else { print("FAIL: " + message); exit(1) }
        }
        start("Karabiner")
        hid.handleMenuBarItemDragStop()
        hid.handleMenuBarItemDragStop()
        try await settle()
        check(app.itemManager.saved == ["Karabiner"], "One completed drag saves exactly its target once")
        start(nil)
        hid.handleMenuBarItemDragStop()
        try await settle()
        check(app.itemManager.saved == ["Karabiner"], "Unknown targets cannot authorize a layout change")
        start("LittleSnitch")
        hid.handleMenuBarItemDragStop()
        start("OtherIcon")
        try await settle()
        check(app.itemManager.saved == ["Karabiner"], "A newer drag invalidates an older pending save")
        hid.handleMenuBarItemDragStop()
        try await settle()
        check(app.itemManager.saved == ["Karabiner", "OtherIcon"], "The newer completed drag still saves")
        start("StaleIcon")
        app.itemManager.duringRefresh = { hid.dragGeneration += 1 }
        hid.handleMenuBarItemDragStop()
        try await settle()
        check(app.itemManager.saved == ["Karabiner", "OtherIcon"], "Input arriving during refresh invalidates the stale save")
        print("PASS: native drag target, duplicate mouse up, unknown target, overlapping drags, and input during refresh")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='hoarfrost-native-drag-save-') as scratch:
    work = Path(scratch)
    (work / 'Checks.swift').write_text(program)
    subprocess.run(['swiftc', '-parse-as-library', str(work / 'Checks.swift'), '-o', str(work / 'checks')], check=True)
    subprocess.run([str(work / 'checks')], check=True)
