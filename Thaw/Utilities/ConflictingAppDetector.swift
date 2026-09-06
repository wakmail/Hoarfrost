//
//  ConflictingAppDetector.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import AppKit

/// Detects other running menu bar management apps that may conflict with Thaw.
enum ConflictingAppDetector {
    /// Known menu bar management app bundle identifiers and their display names.
    private static let knownConflictingApps: [String: String] = [
        "com.jordanbaird.Ice": "Ice",
        "com.surteesstudios.Bartender": "Bartender",
        "com.dwarvesv.minimalbar": "Hidden Bar",
        "com.macpaw.CleanMyMac-setapp": "CleanMyMac Menu",
        "com.gaosun.BarTender": "iBar",
    ]

    /// A conflicting menu bar manager that is currently running.
    struct Conflict {
        let name: String
        let app: NSRunningApplication
    }

    /// Returns any conflicting menu bar managers currently running.
    @MainActor
    static func detectConflictingApps() -> [Conflict] {
        let runningApps = NSWorkspace.shared.runningApplications
        var conflicts: [Conflict] = []

        for app in runningApps {
            guard let bundleID = app.bundleIdentifier else { continue }
            if let name = knownConflictingApps[bundleID], !app.isTerminated {
                conflicts.append(Conflict(name: name, app: app))
            }
        }

        return conflicts
    }

    /// Asks each of the given apps to quit, then waits briefly for them to
    /// actually go away.
    ///
    /// `terminate()` is a request, not a kill: the app may put up a save
    /// dialog or simply take a moment. We wait a short while so the menu
    /// bar has settled before we start arranging it, but we never force
    /// quit another app on the user's behalf.
    /// Spins the run loop rather than awaiting, so that the launch sequence
    /// that follows this alert keeps running in its original order.
    @MainActor
    private static func quit(_ conflicts: [Conflict]) {
        for conflict in conflicts where !conflict.app.isTerminated {
            conflict.app.terminate()
        }

        let deadline = Date().addingTimeInterval(quitWaitTimeout)
        while Date() < deadline, !conflicts.allSatisfy(\.app.isTerminated) {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
    }

    /// How long to wait for a conflicting app to quit before carrying on.
    private static let quitWaitTimeout: TimeInterval = 5

    /// Shows a warning alert listing the conflicting apps, offering to quit
    /// them. Returns `true` if Hoarfrost should carry on.
    ///
    /// Quitting the other manager is the default button because it is the
    /// only choice that actually fixes anything: two managers both moving
    /// the same items fight each other, which shows up as icons landing in
    /// the wrong order or refusing to stay where they are put.
    @MainActor
    @discardableResult
    static func showWarningIfNeeded() -> Bool {
        let conflicts = detectConflictingApps()
        guard !conflicts.isEmpty else { return true }

        let appList = ListFormatter.localizedString(
            byJoining: conflicts.map(\.name)
        )
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Conflicting Menu Bar Manager Detected"
        )
        alert.informativeText = String(
            localized: """
            \(appList) is currently running. Running multiple menu bar \
            managers at the same time can cause display issues and unexpected \
            behavior.
            """
        )
        alert.addButton(withTitle: String(localized: "Quit \(appList)"))
        alert.addButton(withTitle: String(localized: "Continue Anyway"))
        alert.addButton(withTitle: String(localized: "Quit Hoarfrost"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            quit(conflicts)
            return true
        case .alertThirdButtonReturn:
            NSApp.terminate(nil)
            return false
        default:
            return true
        }
    }
}
