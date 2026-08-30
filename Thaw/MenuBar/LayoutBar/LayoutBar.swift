//
//  LayoutBar.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import SwiftUI

struct LayoutBar: View {
    private struct Representable: NSViewRepresentable {
        let appState: AppState
        let section: MenuBarSection.Name

        func makeNSView(context _: Context) -> LayoutBarScrollView {
            LayoutBarScrollView(appState: appState, section: section)
        }

        func updateNSView(_: LayoutBarScrollView, context _: Context) {}
    }

    @EnvironmentObject var appState: AppState
    @ObservedObject var imageCache: MenuBarItemImageCache

    let section: MenuBarSection.Name

    private var backgroundShape: some InsettableShape {
        if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
        } else {
            RoundedRectangle(cornerRadius: 9, style: .circular)
        }
    }

    var body: some View {
        mainContent
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            .menuBarItemContainer(appState: appState)
            .containerShape(backgroundShape)
            .clipShape(backgroundShape)
            .contentShape([.interaction, .focusEffect], backgroundShape)
            .overlay {
                backgroundShape
                    .strokeBorder(.quaternary)
            }
            .overlay {
                if section.isVisible, visibleItemsReachNotch {
                    NotchIndicatorOverlay()
                        .allowsHitTesting(false)
                }
            }
    }

    /// Whether the visible items are wide enough to run into the notch.
    /// Visible items sit against the right edge, so only their total width
    /// against the space right of the notch matters.
    private var visibleItemsReachNotch: Bool {
        guard
            let screen = NSScreen.main,
            let notch = screen.frameOfNotch
        else {
            return false
        }
        let available = screen.frame.maxX - notch.maxX - MenuBarSection.notchGap
        let visibleWidth = appState.itemManager.itemCache[.visible].reduce(0) { $0 + $1.bounds.width }
        // A collapsed divider reports its pushing width, so count each
        // divider that is in the menu bar at its normal size instead.
        let controlWidth = CGFloat(appState.menuBarManager.sections.filter { $0.isEnabled }.count) * 22
        return visibleWidth + controlWidth > available
    }

    @ViewBuilder
    private var mainContent: some View {
        if imageCache.cacheFailed(for: section) {
            // Avoid flicker during rapid cache refreshes; hold a blank placeholder instead of the error text.
            Color.clear
                .frame(height: 20)
        } else {
            Representable(appState: appState, section: section)
        }
    }
}
