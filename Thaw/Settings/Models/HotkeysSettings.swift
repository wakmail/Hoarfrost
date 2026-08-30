//
//  HotkeysSettings.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Combine
import Foundation

/// Model for the app's Hotkeys settings.
@MainActor
final class HotkeysSettings: ObservableObject {
    private let diagLog = DiagLog(category: "HotkeysSettings")
    /// The app's hotkey registry.
    let registry = HotkeyRegistry()

    /// The app's hotkeys.
    var hotkeys = HotkeyAction.settingsActions.map { action in
        Hotkey(action: action)
    }

    /// Encoder for properties.
    private let encoder = JSONEncoder()

    /// Decoder for properties.
    private let decoder = JSONDecoder()

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// Performs the initial setup of the model.
    func performSetup(with appState: AppState) {
        self.appState = appState
        let customActions = appState.menuBarManager.sections
            .filter { !$0.name.isDefault }
            .compactMap { $0.name.hotkeyAction }
        hotkeys.append(contentsOf: customActions.map { Hotkey(action: $0) })
        for hotkey in hotkeys {
            hotkey.performSetup(with: appState)
        }
        loadInitialState()
        configureCancellables()
    }

    /// Creates and registers a hotkey for a section added at runtime.
    func addHotkey(for action: HotkeyAction) {
        guard let appState, hotkey(withAction: action) == nil else { return }
        let hotkey = Hotkey(action: action)
        hotkeys.append(hotkey)
        hotkey.performSetup(with: appState)
        observe(hotkey)
    }

    /// Unregisters and forgets the hotkey for a removed section.
    func removeHotkey(for action: HotkeyAction) {
        guard let index = hotkeys.firstIndex(where: { $0.action == action }) else { return }
        let hotkey = hotkeys.remove(at: index)
        hotkey.keyCombination = nil
        withMutableCopy(of: Defaults.dictionary(forKey: .hotkeys) ?? [:]) { dictionary in
            dictionary[action.rawValue] = nil
            Defaults.set(dictionary, forKey: .hotkeys)
        }
    }

    /// Loads the model's initial state.
    private func loadInitialState() {
        guard
            let dictionary = Defaults.dictionary(forKey: .hotkeys) as? [String: Data],
            !dictionary.isEmpty
        else {
            return
        }
        for hotkey in hotkeys {
            guard let data = dictionary[hotkey.action.rawValue] else {
                continue
            }
            do {
                if let keyCombination = try decoder.decode(KeyCombination?.self, from: data) {
                    hotkey.keyCombination = keyCombination
                }
            } catch {
                diagLog.error("Error decoding hotkey: \(error)")
            }
        }
    }

    /// Configures the internal observers for the model.
    private func configureCancellables() {
        cancellables.removeAll()
        for hotkey in hotkeys {
            observe(hotkey)
        }
    }

    /// Persists the hotkey's key combination whenever it changes.
    private func observe(_ hotkey: Hotkey) {
        hotkey.$keyCombination
            .encode(encoder: encoder)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completion in
                if case let .failure(error) = completion {
                    self?.diagLog.error("Error encoding hotkey: \(error)")
                }
            } receiveValue: { data in
                withMutableCopy(of: Defaults.dictionary(forKey: .hotkeys) ?? [:]) { dictionary in
                    dictionary[hotkey.action.rawValue] = data
                    Defaults.set(dictionary, forKey: .hotkeys)
                }
            }
            .store(in: &cancellables)
    }

    /// Returns the hotkey with the given action.
    func hotkey(withAction action: HotkeyAction) -> Hotkey? {
        hotkeys.first { $0.action == action }
    }
}
