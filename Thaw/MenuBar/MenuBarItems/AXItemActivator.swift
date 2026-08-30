//
//  AXItemActivator.swift
//  Project: Hoarfrost
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Copyright (Hoarfrost) © 2026 wakmail
//  Licensed under the GNU GPLv3

import AXSwift
import Cocoa

/// AXSwift 0.3.2 has no messaging timeout helper, so bound each AX call
/// through the C API. A wedged app then costs the timeout, not forever.
private extension UIElement {
    func setMessagingTimeout(_ seconds: Float) throws {
        let error = AXUIElementSetMessagingTimeout(element, seconds)
        guard error == .success else {
            throw error
        }
    }
}

/// Activates a menu bar item by performing an accessibility action
/// (AXShowMenu, then AXPress) on its element instead of synthesizing mouse
/// events. Faster, and items with their own click handling behave as they
/// would for a real click. On any failure the caller falls back to the
/// synthetic click path.
@MainActor
enum AXItemActivator {
    enum ActivationError: Error {
        case elementNotFound
        case frameMismatch
        case actionFailed
    }

    private static let frameMatchTolerance: CGFloat = 10
    private static let messagingTimeout: Float = 0.25

    static func activate(item: MenuBarItem) async throws {
        guard let element = resolveElement(for: item) else {
            throw ActivationError.elementNotFound
        }

        try? element.setMessagingTimeout(messagingTimeout)
        guard let frame = AXHelpers.frame(for: element),
              framesMatch(frame, item.bounds, tolerance: frameMatchTolerance)
        else {
            throw ActivationError.frameMismatch
        }

        let snapshot = ClickReactionVerifier.snapshot(for: item)
        let worked = performFirstEffectiveAction(
            [.showMenu, .press],
            perform: { (try? element.performAction($0)) != nil },
            didReact: { ClickReactionVerifier.reactionSoFar(against: snapshot)?.didReact == true }
        )
        guard worked else {
            throw ActivationError.actionFailed
        }
    }

    static nonisolated func performFirstEffectiveAction<Action>(
        _ actions: [Action],
        perform: (Action) -> Bool,
        didReact: () -> Bool
    ) -> Bool {
        for action in actions {
            if perform(action) || didReact() {
                return true
            }
        }
        return false
    }

    private static func resolveElement(for item: MenuBarItem) -> UIElement? {
        let center = item.bounds.center
        try? systemWideElement.setMessagingTimeout(messagingTimeout)
        if let element = AXHelpers.element(at: center) {
            try? element.setMessagingTimeout(messagingTimeout)
            return element
        }

        let pid = item.sourcePID ?? item.ownerPID
        guard let runningApp = NSRunningApplication(processIdentifier: pid),
              let app = AXHelpers.application(for: runningApp),
              let extrasMenuBar = AXHelpers.extrasMenuBar(for: app)
        else {
            return nil
        }

        try? app.setMessagingTimeout(messagingTimeout)
        let children = AXHelpers.children(for: extrasMenuBar)
        let frames = children.map { AXHelpers.frame(for: $0) ?? .null }
        guard let index = candidateIndex(inFrames: frames, containing: center) else {
            return nil
        }
        return children[index]
    }

    static nonisolated func candidateIndex(inFrames frames: [CGRect], containing point: CGPoint) -> Int? {
        frames.firstIndex { $0.contains(point) }
    }

    static nonisolated func framesMatch(_ candidate: CGRect, _ target: CGRect, tolerance: CGFloat) -> Bool {
        candidate.insetBy(dx: -tolerance, dy: -tolerance).intersects(target)
    }
}
