//
//  MenuBarLayoutSettingsPane.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import SwiftUI

struct MenuBarLayoutSettingsPane: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var itemManager: MenuBarItemManager

    @State private var loadDeadlineReached = false
    @State private var isResettingLayout = false
    @State private var resetStatus: ResetStatus?
    @State private var isConfirmingReset = false
    @State private var sectionBeingRenamed: String?
    @State private var sectionNameDraft = ""
    @State private var sectionBeingRemoved: String?

    private let diagLog = DiagLog(category: "MenuBarLayoutPane")

    private var hasItems: Bool {
        !itemManager.itemCache.managedItems.isEmpty
    }

    private var areControlItemsDisabledBySystem: Bool {
        itemManager.areControlItemsMissing
    }

    var body: some View {
        if !ScreenCapture.cachedCheckPermissions() {
            missingScreenRecordingPermissions
        } else if appState.menuBarManager.isMenuBarHiddenBySystemUserDefaults {
            cannotArrange
        } else {
            IceForm(spacing: 20) {
                header
                sectionsEditor
                layoutBars
                resetControls
            }
        }
    }

    private var sectionsEditor: some View {
        IceSection {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sections").font(.headline)
                ForEach(Array(appState.menuBarManager.sections.dropFirst()), id: \.name.id) { section in
                    HStack {
                        TextField("Section name", text: Binding(
                            get: { section.name.displayName },
                            set: { appState.menuBarManager.renameSection(id: section.name.id, to: $0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { section.revealStyle },
                            set: { appState.menuBarManager.setRevealStyle($0, forSectionID: section.name.id) }
                        )) {
                            ForEach(SectionRevealStyle.allCases, id: \.self) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                        Button {
                            appState.menuBarManager.moveSection(id: section.name.id, offset: -1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(section.name.rank == 1 || section.name.id == "alwaysHidden")
                        Button {
                            appState.menuBarManager.moveSection(id: section.name.id, offset: 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(section.name.id == "alwaysHidden" || appState.menuBarManager.sections.last?.name.id == "alwaysHidden" && section.name.rank == appState.menuBarManager.sections.count - 2)
                            .disabled(section.name.rank == appState.menuBarManager.sections.count - 1)
                        Button("Remove", role: .destructive) { sectionBeingRemoved = section.name.id }
                    }
                }
                Button("Add Section") { appState.menuBarManager.addSection() }
                Picker("Clicking empty menu bar space", selection: Binding(
                    get: { appState.menuBarManager.sectionsConfiguration.emptyBarClickBehavior },
                    set: { appState.menuBarManager.setEmptyBarClickBehavior($0) }
                )) {
                    // Split halves exists in code but is hidden: an invisible
                    // boundary proved too confusing to offer.
                    ForEach([EmptyBarClickBehavior.toggleFirst, .cycle], id: \.self) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
                if appState.menuBarManager.sectionsConfiguration.emptyBarClickBehavior == .cycle {
                    Toggle("Wait for extra clicks before opening, so fast multi clicks jump without flashing", isOn: Binding(
                        get: { appState.menuBarManager.sectionsConfiguration.cycleWaitsForMultiClicks },
                        set: { appState.menuBarManager.setCycleWaitsForMultiClicks($0) }
                    ))
                }
                Toggle("Attach the floating bar to the menu bar", isOn: Binding(
                    get: { appState.menuBarManager.sectionsConfiguration.iceBarAttachedToMenuBar },
                    set: { appState.menuBarManager.setIceBarAttachedToMenuBar($0) }
                ))
                Toggle("Show app icons in dropdowns instead of menu bar images", isOn: Binding(
                    get: { appState.menuBarManager.sectionsConfiguration.dropdownShowsAppIcons },
                    set: { appState.menuBarManager.setDropdownShowsAppIcons($0) }
                ))
                Toggle("Clicking the menu bar icon opens one dropdown with every section", isOn: Binding(
                    get: { appState.menuBarManager.sectionsConfiguration.iceIconOpensCombinedMenu },
                    set: { appState.menuBarManager.setIceIconOpensCombinedMenu($0) }
                ))
            }
        }
        .alert("Remove section?", isPresented: Binding(get: { sectionBeingRemoved != nil }, set: { if !$0 { sectionBeingRemoved = nil } })) {
            Button("Remove", role: .destructive) { if let id = sectionBeingRemoved { appState.menuBarManager.removeSection(id: id) }; sectionBeingRemoved = nil }
            Button("Cancel", role: .cancel) { sectionBeingRemoved = nil }
        } message: {
            Text("Items move to the neighbouring section.")
        }
    }

    private var header: some View {
        IceSection {
            VStack(spacing: 3) {
                Text("Drag to arrange your menu bar items into different sections.")
                    .font(.title3.bold())
                Text("Move the New Items badge to choose where newly detected items will appear.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Items can also be arranged by ⌘ Command + dragging them in the menu bar.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(15)
        }
    }

    private var layoutBars: some View {
        VStack(spacing: 20) {
            ForEach(appState.menuBarManager.sections.map(\.name), id: \.self) { section in
                layoutBar(for: section)
            }
        }
        .opacity(hasItems ? 1 : 0.75)
        .blur(radius: hasItems ? 0 : 5)
        .allowsHitTesting(hasItems)
        .overlay {
            if !hasItems {
                VStack(spacing: 8) {
                    if loadDeadlineReached {
                        VStack(spacing: 4) {
                            if areControlItemsDisabledBySystem {
                                Text("One or more section dividers are hidden by macOS")
                                Text("Check System Settings > Menu Bar and enable \(Constants.displayName)")
                                    .font(.calloutBox)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Unable to load menu bar items")
                            }
                        }
                    } else {
                        Text("Loading menu bar items…")
                    }
                    if loadDeadlineReached {
                        EmptyView()
                    } else {
                        ProgressView()
                    }
                }
            }
        }
        .task(id: hasItems) {
            loadDeadlineReached = false

            guard !hasItems, ScreenCapture.cachedCheckPermissions() else {
                return
            }

            diagLog.debug("Preloading menu bar layout caches (hasItems=\(self.hasItems), screenRecording=\(ScreenCapture.cachedCheckPermissions()))")

            // Run cache updates in the background to avoid blocking the UI
            Task {
                await itemManager.cacheItemsRegardless(skipRecentMoveCheck: true)
                diagLog.debug("Preload: itemCache after cacheItemsRegardless: managedItems=\(self.itemManager.itemCache.managedItems.count), visible=\(self.itemManager.itemCache[.visible].count), hidden=\(self.itemManager.itemCache[.hidden].count), alwaysHidden=\(self.itemManager.itemCache[.alwaysHidden].count)")
                await appState.imageCache.updateCacheWithoutChecks(sections: MenuBarSection.Name.allCases)
                diagLog.debug("Preload: imageCache after update: \(self.appState.imageCache.images.count) images")
            }

            try? await Task.sleep(for: .seconds(3))

            if !hasItems {
                loadDeadlineReached = true
                diagLog.error("Menu bar layout failed to load items after 3s timeout. cacheItems: \(itemManager.itemCache.managedItems.count), images: \(appState.imageCache.images.count), displayID: \(self.itemManager.itemCache.displayID.map { "\($0)" } ?? "nil")")
            }
        }
    }

    private var resetControls: some View {
        IceSection {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reset menu bar layout")
                        .font(.headline)
                    Text("Resets dividers and moves every movable item except the \(Constants.displayName) icon to hidden — just like a fresh install.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button {
                    isConfirmingReset = true
                } label: {
                    if isResettingLayout {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Reset Layout")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isResettingLayout || areControlItemsDisabledBySystem)
            }

            if let resetStatus {
                Text(resetStatus.message)
                    .font(.footnote)
                    .foregroundStyle(resetStatus.isError ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .alert("Reset menu bar layout?", isPresented: $isConfirmingReset) {
            Button("Reset", role: .destructive) {
                resetMenuBarLayout()
            }
            Button("Cancel", role: .cancel) {
                isConfirmingReset = false
            }
        } message: {
            Text("Restores divider defaults and moves every movable item except the \(Constants.displayName) icon to Hidden. Use this if the layout looks broken or items won’t load.")
        }
    }

    private var cannotArrange: some View {
        Text("\(Constants.displayName) cannot arrange menu bar items in automatically hidden menu bars.")
            .font(.title3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var missingScreenRecordingPermissions: some View {
        VStack {
            Text("Menu bar layout requires screen recording permissions.")
                .font(.title2)

            Button {
                appState.navigationState.settingsNavigationIdentifier = .advanced
            } label: {
                Text("Go to Advanced Settings")
            }
            .buttonStyle(.link)
        }
    }

    private var loadingMenuBarItems: some View {
        VStack {
            Text("Loading menu bar items…")
            ProgressView()
        }
        .font(.title)
    }

    @ViewBuilder
    private func layoutBar(for name: MenuBarSection.Name) -> some View {
        if
            let section = appState.menuBarManager.section(withName: name),
            section.isEnabled
        {
            VStack(alignment: .leading) {
            Text(name.localized)
                    .font(.headline)
                    .padding(.leading, 8)

                LayoutBar(imageCache: appState.imageCache, section: name)
            }
        }
    }

    private func resetMenuBarLayout() {
        isResettingLayout = true
        resetStatus = nil

        let manager = itemManager

        Task { @MainActor in
            do {
                let failedMoves = try await manager.resetLayoutToFreshState()
                if failedMoves == 0 {
                    resetStatus = .success
                } else {
                    resetStatus = .partialFailure(failedMoves)
                }
                isResettingLayout = false

                await manager.cacheItemsRegardless(skipRecentMoveCheck: true)
                await appState.imageCache.updateCacheWithoutChecks(sections: MenuBarSection.Name.allCases)
            } catch {
                resetStatus = .failure(error.localizedDescription)
                isResettingLayout = false
            }
        }
    }

    private enum ResetStatus {
        case success
        case partialFailure(Int)
        case failure(String)

        var message: String {
            switch self {
            case .success:
                String(localized: "Layout reset. Items were moved to the Hidden section.")
            case let .partialFailure(count):
                String(localized: "Reset completed with \(count) item(s) that could not be moved. Check the menu bar and try again if needed.")
            case let .failure(message):
                String(localized: "Reset failed: \(message)")
            }
        }

        var isError: Bool {
            switch self {
            case .failure, .partialFailure:
                true
            case .success:
                false
            }
        }
    }
}
