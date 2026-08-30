//
//  ClickReactionVerifier.swift
//  Project: Hoarfrost
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Copyright (Hoarfrost) © 2026 Preston Chen
//  Licensed under the GNU GPLv3

import CoreGraphics
import Foundation

nonisolated enum ClickReactionVerifier {
    enum Reaction: Equatable {
        case openedInterface(CGWindowID)
        case itemChanged
        case unobserved

        var didReact: Bool { self != .unobserved }

        var openedWindowID: CGWindowID? {
            if case let .openedInterface(windowID) = self {
                return windowID
            }
            return nil
        }
    }

    struct Snapshot {
        let pids: Set<pid_t>
        let itemWindowID: CGWindowID
        let itemBounds: CGRect
        let onScreenWindowIDs: Set<CGWindowID>
    }

    private static let budget = Duration.milliseconds(250)
    private static let pollInterval = Duration.milliseconds(20)
    private static let boundsEpsilon: CGFloat = 1

    static func snapshot(for item: MenuBarItem) -> Snapshot {
        Snapshot(
            pids: Set([item.ownerPID, item.sourcePID].compactMap(\.self)),
            itemWindowID: item.windowID,
            itemBounds: item.bounds,
            onScreenWindowIDs: Set(Bridging.getWindowList(option: .onScreen))
        )
    }

    static func verify(against snapshot: Snapshot) async -> Reaction {
        let deadline = ContinuousClock.now.advanced(by: budget)
        while true {
            if let reaction = observe(snapshot) {
                return reaction
            }
            guard ContinuousClock.now < deadline else {
                return .unobserved
            }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return .unobserved
            }
        }
    }

    static func reactionSoFar(against snapshot: Snapshot) -> Reaction? {
        observe(snapshot)
    }

    private static func observe(_ snapshot: Snapshot) -> Reaction? {
        let newWindowIDs = Bridging.getWindowList(option: .onScreen)
            .filter { !snapshot.onScreenWindowIDs.contains($0) }
        if !newWindowIDs.isEmpty {
            let candidates = WindowInfo.createWindows(from: newWindowIDs)
            if let window = interfaceWindow(among: candidates, ownedBy: snapshot.pids) {
                return .openedInterface(window.windowID)
            }
        }

        if itemChanged(snapshot) {
            return .itemChanged
        }
        return nil
    }

    static func interfaceWindow(among candidates: [WindowInfo], ownedBy pids: Set<pid_t>) -> WindowInfo? {
        let owned = candidates.filter { pids.contains($0.ownerPID) }
        return owned.first(where: \.isMenuRelated) ?? owned.first
    }

    static func itemChanged(from before: CGRect, to after: CGRect?) -> Bool {
        guard let after else { return true }
        return abs(after.width - before.width) > boundsEpsilon ||
            abs(after.height - before.height) > boundsEpsilon
    }

    private static func itemChanged(_ snapshot: Snapshot) -> Bool {
        guard Bridging.isWindowOnScreen(snapshot.itemWindowID) else {
            return snapshot.onScreenWindowIDs.contains(snapshot.itemWindowID)
        }
        return itemChanged(
            from: snapshot.itemBounds,
            to: Bridging.getWindowBounds(for: snapshot.itemWindowID)
        )
    }
}
