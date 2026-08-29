//
//  WindowCaptureBackend.swift
//  Project: Hoarfrost
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Copyright (Hoarfrost) © 2026 Preston Chen
//  Licensed under the GNU GPLv3

import CoreGraphics
import Foundation

/// The one capability that differs between macOS releases: turning a list of
/// menu bar window IDs into an image.
///
/// Everything else in the app is ordinary AppKit and does not care which
/// backend is in use. Keep OS specific capture code behind this protocol so
/// the rest of the codebase never branches on the OS version for capture.
protocol WindowCaptureBackend: Sendable {
    /// A short name for logs and the advanced settings pane.
    var name: String { get }

    /// Captures a composite image of the given windows, front to back.
    ///
    /// - Parameters:
    ///   - windowIDs: The identifiers of the windows to capture.
    ///   - screenBounds: The bounds to capture in screen coordinates, or
    ///     `.null` for the minimum rectangle enclosing the windows.
    ///   - option: Options that specify which parts of the windows are captured.
    func captureWindows(_ windowIDs: [CGWindowID], screenBounds: CGRect, option: CGWindowImageOption) -> CGImage?
}

// MARK: - CGWindowList backend (macOS 14 and later)

/// Captures through the deprecated `CGWindowListCreateImageFromArray`.
///
/// Deprecated since macOS 14 but still functional on 14 and 15. This is the
/// path Ice and Thaw 1.x used.
struct CGWindowListCaptureBackend: WindowCaptureBackend {
    let name = "CGWindowList"

    func captureWindows(_ windowIDs: [CGWindowID], screenBounds: CGRect, option: CGWindowImageOption) -> CGImage? {
        guard let array = Bridging.createCGWindowArray(with: windowIDs) else {
            return nil
        }
        return CGImage(windowListFromArrayScreenBounds: screenBounds, windowArray: array as CFArray, imageOption: option)
    }
}

// MARK: - SkyLight backend (macOS 15 and later, required on 26)

/// Captures through the private `SLWindowListCreateImageFromArray` in the
/// SkyLight framework, loaded with `dlsym` so there is no link time
/// dependency. This is the path Thaw 2.x uses and the only one that works on
/// macOS 26. The symbol also resolves on macOS 15.
struct SkyLightCaptureBackend: WindowCaptureBackend {
    let name = "SkyLight"

    private typealias CreateImageFromArrayFn = @convention(c) (
        CGRect,
        CFArray,
        CGWindowImageOption
    ) -> Unmanaged<CGImage>?

    private static let diagLog = DiagLog(category: "SkyLightCaptureBackend")

    private static let createImageFromArray: CreateImageFromArrayFn? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else {
            diagLog.error("Failed to open SkyLight framework")
            return nil
        }
        guard let sym = dlsym(handle, "SLWindowListCreateImageFromArray") else {
            diagLog.error("SLWindowListCreateImageFromArray not found in SkyLight")
            return nil
        }
        return unsafeBitCast(sym, to: CreateImageFromArrayFn.self)
    }()

    /// Whether the SkyLight capture symbol resolves on this system.
    static var isAvailable: Bool {
        createImageFromArray != nil
    }

    func captureWindows(_ windowIDs: [CGWindowID], screenBounds: CGRect, option: CGWindowImageOption) -> CGImage? {
        guard
            let fn = Self.createImageFromArray,
            let array = Bridging.createCGWindowArray(with: windowIDs)
        else {
            return nil
        }
        return fn(screenBounds, array as CFArray, option)?.takeRetainedValue()
    }
}

// MARK: - Selection

/// Chooses which backend the app uses.
enum WindowCaptureBackendSelection: String, CaseIterable {
    /// SkyLight when its symbol resolves, otherwise CGWindowList.
    case automatic
    case skyLight
    case cgWindowList

    /// User defaults key for overriding the automatic choice.
    static let defaultsKey = "CaptureBackend"

    static var current: WindowCaptureBackendSelection {
        guard
            let raw = UserDefaults.standard.string(forKey: defaultsKey),
            let selection = WindowCaptureBackendSelection(rawValue: raw)
        else {
            return .automatic
        }
        return selection
    }

    func makeBackend() -> any WindowCaptureBackend {
        switch self {
        case .skyLight:
            return SkyLightCaptureBackend()
        case .cgWindowList:
            return CGWindowListCaptureBackend()
        case .automatic:
            if SkyLightCaptureBackend.isAvailable {
                return SkyLightCaptureBackend()
            }
            return CGWindowListCaptureBackend()
        }
    }
}
