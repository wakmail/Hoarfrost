//
//  MouseHelpers.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import AppKit
import CoreGraphics
import Foundation

/// A namespace for mouse helper operations.
enum MouseHelpers {
    private static let diagLog = DiagLog(category: "MouseHelpers")
    private static let cursorLock = DispatchQueue(label: "MouseHelpers.cursorLock")
    /// Tokens remain owned until their scopes exit, including after recovery.
    struct CursorScope {
        fileprivate let id: UInt64
    }

    private static var nextScopeID: UInt64 = 0
    private static var activeCursorScopes = Set<UInt64>()
    private static var cursorGeneration: UInt64 = 0
    private static var cursorIsHidden = false
    private static var lastGoodLocation: CGPoint?
    @MainActor private static var cursorMovementMonitor: EventMonitor?
    private static var autoShowWorkItem: DispatchWorkItem?
    private static let defaultWatchdogTimeout: DispatchTimeInterval = .seconds(1)

    private static func formattedTimeout(_ interval: DispatchTimeInterval) -> String {
        switch interval {
        case let .seconds(s):
            return "\(s)s"
        case let .milliseconds(ms):
            return String(format: "%.3fs", Double(ms) / 1000)
        case let .microseconds(us):
            return String(format: "%.6fs", Double(us) / 1_000_000)
        case let .nanoseconds(ns):
            return String(format: "%.9fs", Double(ns) / 1_000_000_000)
        case .never:
            return "never"
        @unknown default:
            return "unknown"
        }
    }

    private static func scheduleAutoShow(after timeout: DispatchTimeInterval = defaultWatchdogTimeout) {
        let generation = cursorGeneration
        let workItem = DispatchWorkItem {
            forceShowCursor(generation: generation, reason: "watchdog timeout")
        }
        autoShowWorkItem?.cancel()
        autoShowWorkItem = workItem
        diagLog.debug("CURSORTRACE watchdog scheduled for \(formattedTimeout(timeout)) generation=\(generation)")
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    private static func cancelAutoShow() {
        autoShowWorkItem?.cancel()
        autoShowWorkItem = nil
    }

    private static func forceShowCursor(generation: UInt64, reason: String) {
        cursorLock.sync {
            guard generation == cursorGeneration, cursorIsHidden else {
                diagLog.info("CURSORTRACE ignored stale force show generation=\(generation) current=\(cursorGeneration)")
                return
            }
            diagLog.info("CURSORTRACE force show reason=\(reason) generation=\(generation) depth=\(activeCursorScopes.count)")
            // Revealing does not end outstanding scopes. They may still post
            // events, so live cursor readings remain untrusted until they exit.
            restoreCursorLocked(caller: reason)
            revealCursorLocked()
        }
    }

    /// Keeps the restore target current using real movement, including while
    /// an operation has the cursor parked. Our clicks and drags never enter here.
    @MainActor
    static func startMonitoringUserMovement() {
        guard cursorMovementMonitor == nil else { return }
        let monitor = EventMonitor.universal(for: .mouseMoved) { event in
            if let point = event.cgEvent?.location {
                cursorLock.sync {
                    if isOnAnyDisplay(point) {
                        lastGoodLocation = point
                        diagLog.debug("CURSORTRACE user movement to \(point.x),\(point.y) depth=\(activeCursorScopes.count)")
                    }
                }
            }
            return event
        }
        cursorMovementMonitor = monitor
        monitor.start()
        _ = captureRestorePoint()
        diagLog.info("CURSORTRACE user movement monitor started")
    }

    /// Returns the location of the mouse cursor in the coordinate
    /// space used by `AppKit`, with the origin at the bottom left
    /// of the screen.
    static var locationAppKit: CGPoint? {
        CGEvent(source: nil)?.unflippedLocation
    }

    /// Returns the location of the mouse cursor in the coordinate
    /// space used by `CoreGraphics`, with the origin at the top left
    /// of the screen.
    static var locationCoreGraphics: CGPoint? {
        // Raw callers must not promote our synthetic event positions.
        CGEvent(source: nil)?.location
    }

    /// Reads the free position and checks ownership in one critical section.
    static func captureRestorePoint() -> CGPoint? {
        cursorLock.sync { captureRestorePointLocked() }
    }

    /// Requires cursorLock, as do the other helpers with a Locked suffix.
    private static func captureRestorePointLocked() -> CGPoint? {
        if activeCursorScopes.isEmpty,
           let live = CGEvent(source: nil)?.location,
           isOnAnyDisplay(live)
        {
            lastGoodLocation = live
            diagLog.debug("CURSORTRACE capture free position \(live.x),\(live.y)")
        }
        return lastGoodLocation
    }

    /// Begins an individually owned park scope and captures before hiding.
    static func hideCursor(watchdogTimeout: DispatchTimeInterval? = nil, caller: String = #function) -> CursorScope {
        cursorLock.sync {
            diagLog.info("CURSORTRACE hide by \(caller) at \(CGEvent(source: nil)?.location.debugDescription ?? "?") depth=\(activeCursorScopes.count)")
            _ = captureRestorePointLocked()
            let beginsGeneration = activeCursorScopes.isEmpty || !cursorIsHidden
            nextScopeID += 1
            let scope = CursorScope(id: nextScopeID)
            activeCursorScopes.insert(scope.id)

            if beginsGeneration {
                cursorGeneration += 1
                if cursorIsHidden {
                    scheduleAutoShow(after: watchdogTimeout ?? defaultWatchdogTimeout)
                }
            }
            if !cursorIsHidden {
                let result = CGDisplayHideCursor(CGMainDisplayID())
                if result != .success {
                    diagLog.error("CGDisplayHideCursor failed with error code \(result.rawValue)")
                } else {
                    cursorIsHidden = true
                    scheduleAutoShow(after: watchdogTimeout ?? defaultWatchdogTimeout)
                }
            }
            diagLog.debug("CURSORTRACE scope began id=\(scope.id) generation=\(cursorGeneration) depth=\(activeCursorScopes.count)")
            return scope
        }
    }

    /// Ends only the supplied scope. Move and click owners restore even inside
    /// a batch; nested event helpers restore when the last scope exits.
    static func showCursor(_ scope: CursorScope, restoring: Bool = false, caller: String = #function) {
        cursorLock.sync {
            diagLog.info("CURSORTRACE show by \(caller) at \(CGEvent(source: nil)?.location.debugDescription ?? "?") depth=\(activeCursorScopes.count)")
            guard activeCursorScopes.remove(scope.id) != nil else {
                diagLog.info("CURSORTRACE ignored stale show id=\(scope.id) generation=\(cursorGeneration)")
                return
            }
            if restoring || activeCursorScopes.isEmpty || !cursorIsHidden {
                restoreCursorLocked(caller: caller)
            }
            if activeCursorScopes.isEmpty {
                revealCursorLocked()
            }
            diagLog.debug("CURSORTRACE scope ended id=\(scope.id) generation=\(cursorGeneration) depth=\(activeCursorScopes.count)")
        }
    }

    private static func restoreCursorLocked(caller: String) {
        let target: CGPoint
        if let lastGoodLocation, isOnAnyDisplay(lastGoodLocation) {
            target = lastGoodLocation
        } else {
            // The original display may have disconnected while we were parked.
            let bounds = CGDisplayBounds(CGMainDisplayID())
            target = CGPoint(x: bounds.midX, y: bounds.midY)
            diagLog.info("CURSORTRACE restore using main display center by \(caller)")
        }
        warpCursorLocked(to: target, caller: caller)
    }

    private static func revealCursorLocked() {
        cancelAutoShow()
        guard cursorIsHidden else { return }
        let result = CGDisplayShowCursor(CGMainDisplayID())
        if result != .success {
            diagLog.error("CGDisplayShowCursor failed with error code \(result.rawValue)")
            scheduleAutoShow()
        } else {
            cursorIsHidden = false
            diagLog.info("CURSORTRACE cursor revealed generation=\(cursorGeneration) depth=\(activeCursorScopes.count)")
        }
    }

    /// Puts the cursor back somewhere visible if it has been left off the
    /// edge of every display.
    static func rescueCursorIfOffScreen() {
        cursorLock.sync { rescueCursorIfOffScreenLocked() }
    }

    private static func rescueCursorIfOffScreenLocked() {
        guard
            let current = CGEvent(source: nil)?.location,
            !isOnAnyDisplay(current)
        else {
            return
        }
        guard
            let fallback = lastGoodLocation,
            isOnAnyDisplay(fallback)
        else {
            return
        }
        diagLog.error("Cursor was left off screen at \(current.x), \(current.y); restoring to \(fallback.x), \(fallback.y)")
        CGWarpMouseCursorPosition(fallback)
    }

    /// Moves the mouse cursor to the given point without generating
    /// events.
    ///
    /// - Parameter point: The point to move the cursor to in global
    ///   display coordinates.
    static func warpCursor(to point: CGPoint, caller: String = #function) {
        cursorLock.sync { warpCursorLocked(to: point, caller: caller) }
    }

    private static func warpCursorLocked(to point: CGPoint, caller: String) {
        diagLog.info("CURSORTRACE warp by \(caller) to \(point.x),\(point.y) from \(CGEvent(source: nil)?.location.debugDescription ?? "?")")
        // Refuse to put the cursor somewhere it cannot be seen.
        //
        // The positions handed to this are captured before an operation and
        // used after it, and a capture taken while another operation still
        // had the cursor parked off screen records exactly that: a point
        // far to the left of every display, since hidden items live at
        // large negative coordinates. Warping there clamps the pointer into
        // a screen corner, which is the pointer apparently teleporting to
        // the top left for no reason. Somewhere visible, even if it is not
        // where the pointer started, always beats a corner.
        // Rescue rather than refuse.
        //
        // Refusing was not enough. By the time a restore runs, our own
        // events have already taken the cursor off screen, so declining to
        // move it leaves it exactly where the bad warp would have put it:
        // clamped into a corner. The pointer has to be put somewhere real,
        // and the last position it was seen at on an actual display is the
        // best answer available.
        var target = point
        if !isOnAnyDisplay(target) {
            guard
                let fallback = lastGoodLocation,
                isOnAnyDisplay(fallback)
            else {
                diagLog.error("Cursor target \(point.x), \(point.y) is off screen and there is no known good position to fall back on")
                return
            }
            diagLog.error("Cursor target \(point.x), \(point.y) is off screen; restoring to \(fallback.x), \(fallback.y) instead")
            target = fallback
        }
        let result = CGWarpMouseCursorPosition(target)
        if result != .success {
            diagLog.error("CGWarpMouseCursorPosition failed with error code \(result.rawValue)")
        }
    }

    /// Whether the point lies inside one of the active displays, in the
    /// top left origin space that `CGWarpMouseCursorPosition` expects.
    private static func isOnAnyDisplay(_ point: CGPoint) -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            // No display list to check against, so do not block the warp.
            return true
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            return true
        }
        // Outset by a point, since a cursor resting against the far edge
        // of a display sits exactly on a boundary that `contains` excludes.
        return displays.prefix(Int(count)).contains {
            CGDisplayBounds($0).insetBy(dx: -1, dy: -1).contains(point)
        }
    }

    /// Connects or disconnects the positions of the mouse and cursor.
    ///
    /// - Parameter connected: A Boolean value that determines whether
    ///   to connect or disconnect the positions.
    static func associateMouseAndCursor(_ connected: Bool) {
        let result = CGAssociateMouseAndMouseCursorPosition(connected ? 1 : 0)
        if result != .success {
            diagLog.error("CGAssociateMouseAndMouseCursorPosition failed with error code \(result.rawValue)")
        }
    }

    /// Returns a Boolean value that indicates whether a mouse button
    /// is pressed.
    ///
    /// - Parameter button: The mouse button to check. Pass `nil` to
    ///   check all available mouse buttons (Quartz supports up to 32).
    static func isButtonPressed(_ button: CGMouseButton? = nil) -> Bool {
        let stateID = CGEventSourceStateID.combinedSessionState
        if let button {
            return CGEventSource.buttonState(stateID, button: button)
        }
        for n: UInt32 in 0 ... 31 {
            guard
                let button = CGMouseButton(rawValue: n),
                CGEventSource.buttonState(stateID, button: button)
            else {
                continue
            }
            return true
        }
        return false
    }

    /// Returns a Boolean value that indicates whether the last mouse
    /// movement event occurred within the given duration.
    ///
    /// - Parameter duration: The duration within which the last mouse
    ///   movement event must have occurred in order to return `true`.
    static func lastMovementOccurred(within duration: Duration) -> Bool {
        let stateID = CGEventSourceStateID.combinedSessionState
        let seconds = CGEventSource.secondsSinceLastEventType(stateID, eventType: .mouseMoved)
        return .seconds(seconds) <= duration
    }

    /// Returns a Boolean value that indicates whether the last scroll
    /// wheel event occurred within the given duration.
    ///
    /// - Parameter duration: The duration within which the last scroll
    ///   wheel event must have occurred in order to return `true`.
    static func lastScrollWheelOccurred(within duration: Duration) -> Bool {
        let stateID = CGEventSourceStateID.combinedSessionState
        let seconds = CGEventSource.secondsSinceLastEventType(stateID, eventType: .scrollWheel)
        return .seconds(seconds) <= duration
    }
}
