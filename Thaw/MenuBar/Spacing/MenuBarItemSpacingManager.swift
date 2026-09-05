//
//  MenuBarItemSpacingManager.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa
import Combine
import os.lock

/// Manager for menu bar item spacing.
@MainActor
final class MenuBarItemSpacingManager {
    private static nonisolated let diagLog = DiagLog(category: "MenuBarItemSpacingManager")
    /// UserDefaults keys.
    private enum Key: String {
        case spacing = "NSStatusItemSpacing"
        case padding = "NSStatusItemSelectionPadding"

        /// The default value for the key.
        var defaultValue: Int {
            switch self {
            case .spacing: 16
            case .padding: 16
            }
        }
    }

    /// An error that groups multiple failed app relaunches.
    private struct GroupedRelaunchError: LocalizedError {
        let failedApps: [String]

        var errorDescription: String? {
            "The following applications failed to quit and were not restarted:\n"
                + failedApps.joined(separator: "\n")
        }

        var recoverySuggestion: String? {
            "You may need to log out for the changes to take effect."
        }
    }

    /// Delay before force terminating an app.
    private let forceTerminateDelay = 1

    /// The offset to apply to the default spacing and padding.
    /// Does not take effect until ``applyOffset()`` is called.
    var offset = 0

    /// Runs a command with the given arguments.
    ///
    /// The command name is passed as the first argument because the
    /// configured executable is `env`, which resolves it.
    private func runCommand(_ command: String, with arguments: [String])
        async throws
    {
        try await run(
            executable: Constants.menuBarItemSpacingExecutableURL,
            arguments: CollectionOfOne(command) + arguments
        )
    }

    /// Runs the executable at the given URL with the given arguments.
    private func run(executable executableURL: URL, arguments: [String])
        async throws
    {
        let process = Process()

        process.executableURL = executableURL
        process.arguments = arguments

        let task = Task.detached {
            try process.run()
            process.waitUntilExit()
        }

        return try await task.value
    }

    /// Removes the value for the specified key.
    private func removeValue(forKey key: Key) async throws {
        try await runCommand(
            "defaults",
            with: ["-currentHost", "delete", "-globalDomain", key.rawValue]
        )
    }

    /// Sets the value for the specified key to the key's default value plus the given offset.
    private func setOffset(_ offset: Int, forKey key: Key) async throws {
        try await runCommand(
            "defaults",
            with: [
                "-currentHost", "write", "-globalDomain", key.rawValue, "-int",
                String(key.defaultValue + offset),
            ]
        )
    }

    /// Asynchronously signals the given app to quit.
    private func signalAppToQuit(_ app: NSRunningApplication) async throws {
        if app.isTerminated {
            MenuBarItemSpacingManager.diagLog.debug(
                "Application \"\(app.logString)\" is already terminated"
            )
            return
        } else {
            MenuBarItemSpacingManager.diagLog.debug(
                "Signaling application \"\(app.logString)\" to quit"
            )
        }

        app.terminate()

        var cancellable: AnyCancellable?
        let didResume = OSAllocatedUnfairLock(initialState: false)
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task {
                try await Task.sleep(for: .seconds(forceTerminateDelay))
                if !app.isTerminated {
                    MenuBarItemSpacingManager.diagLog.debug(
                        """
                        Application \"\(app.logString)\" did not terminate within \
                        \(self.forceTerminateDelay) seconds, attempting to force terminate
                        """
                    )
                    app.forceTerminate()

                    // Failsafe: if KVO doesn't fire after force terminate, resume anyway to prevent hang
                    try? await Task.sleep(for: .seconds(1))
                    cancellable?.cancel()
                    if didResume.tryClaimOnce() {
                        continuation.resume()
                    }
                }
            }

            cancellable = app.publisher(for: \.isTerminated).sink { isTerminated in
                guard
                    isTerminated
                else {
                    return
                }
                timeoutTask.cancel()
                cancellable?.cancel()
                MenuBarItemSpacingManager.diagLog.debug(
                    "Application \"\(app.logString)\" terminated successfully"
                )
                if didResume.tryClaimOnce() {
                    continuation.resume()
                }
            }
        }
    }

    /// Asynchronously launches the app at the given URL.
    private nonisolated func launchApp(
        at applicationURL: URL,
        bundleIdentifier: String
    ) async throws {
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleIdentifier
        }) {
            MenuBarItemSpacingManager.diagLog.debug(
                "Application \"\(app.logString)\" is already open, so skipping launch"
            )
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        configuration.promptsUserIfNeeded = false
        try await NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: configuration
        )
    }

    /// The launchd label that owns the given app's executable, or `nil`
    /// when the app is not launched by a system LaunchAgent.
    private func launchdLabel(for app: NSRunningApplication) -> String? {
        guard let executableURL = app.executableURL else {
            return nil
        }
        return SystemLaunchAgentIndex.system.label(forExecutableAt: executableURL)
    }

    /// Restarts the launchd job with the given label in the calling user's
    /// GUI domain.
    ///
    /// `kickstart -k` kills the running instance and starts a fresh one
    /// with launchd as its parent, which is the whole point: it is the only
    /// way to bring a launch constrained agent back, and it replaces the
    /// terminate then launch pair rather than supplementing it.
    private func kickstartLaunchAgent(label: String) async throws {
        let target = "gui/\(getuid())/\(label)"
        try await run(
            executable: Constants.launchctlExecutableURL,
            arguments: ["kickstart", "-k", target]
        )
        MenuBarItemSpacingManager.diagLog.debug("Kickstarted launchd job \(target)")
    }

    /// Asynchronously relaunches the given app.
    private func relaunchApp(_ app: NSRunningApplication) async throws {
        struct RelaunchError: Error {}

        // System LaunchAgents (Spotlight, Dock, WindowManager and friends)
        // can carry a launch constraint permitting launchd as their only
        // launching parent. Terminating one and launching its bundle
        // ourselves gets the new process SIGKILLed at exec (CODESIGNING,
        // "Launch Constraint Violation"), and because terminate() counts as
        // a *successful* exit, an agent with KeepAlive.SuccessfulExit=false
        // (Spotlight's setting) is never respawned by launchd either. The
        // item then stays gone until the machine is rebooted. Restart these
        // through launchd instead. Ported from Thaw upstream #720.
        if let label = launchdLabel(for: app) {
            try await kickstartLaunchAgent(label: label)
            return
        }

        guard
            let url = app.bundleURL,
            let bundleIdentifier = app.bundleIdentifier
        else {
            throw RelaunchError()
        }
        try await signalAppToQuit(app)
        if app.isTerminated {
            try await launchApp(at: url, bundleIdentifier: bundleIdentifier)
        } else {
            throw RelaunchError()
        }
    }

    /// Applies the current ``offset``.
    ///
    /// - Note: Calling this restarts all apps with a menu bar item.
    func applyOffset() async throws {
        if offset == 0 {
            try await removeValue(forKey: .spacing)
            try await removeValue(forKey: .padding)
        } else {
            try await setOffset(offset, forKey: .spacing)
            try await setOffset(offset, forKey: .padding)
        }

        try? await Task.sleep(for: .milliseconds(100))

        let items = await MenuBarItem.getMenuBarItems(option: .activeSpace)
        let pids = Set(items.map { $0.sourcePID ?? $0.ownerPID })

        var failedApps = [String]()

        await withTaskGroup(of: Void.self) { group in
            for pid in pids {
                guard
                    let app = NSRunningApplication(processIdentifier: pid),
                    app.bundleIdentifier != "com.apple.controlcenter", // ControlCenter handles its own relaunch, so skip it.
                    app != .current
                else {
                    // Skip this PID, do not break: breaking aborts the
                    // entire wave on the first skipped item, leaving most
                    // apps un-relaunched depending on Set iteration order.
                    continue
                }
                group.addTask { @MainActor in
                    do {
                        try await self.relaunchApp(app)
                    } catch {
                        guard let name = app.localizedName else {
                            return
                        }
                        if app.bundleIdentifier == "com.apple.Spotlight" {
                            // Spotlight automatically relaunches, so only consider it a failure if it never quit.
                            if let latestSpotlightInstance =
                                NSRunningApplication.runningApplications(
                                    withBundleIdentifier: "com.apple.Spotlight"
                                ).first,
                                latestSpotlightInstance.processIdentifier
                                == app.processIdentifier
                            {
                                failedApps.append(name)
                            }
                        } else {
                            failedApps.append(name)
                        }
                    }
                }
            }
        }

        try? await Task.sleep(for: .milliseconds(100))

        if let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.controlcenter"
        ).first {
            do {
                try await signalAppToQuit(app)
            } catch {
                if let name = app.localizedName {
                    failedApps.append(name)
                }
            }
        }

        if !failedApps.isEmpty {
            throw GroupedRelaunchError(failedApps: failedApps)
        }
    }
}

private extension NSRunningApplication {
    /// A string to use for logging purposes.
    var logString: String {
        localizedName ?? bundleIdentifier ?? "<NIL>"
    }
}
