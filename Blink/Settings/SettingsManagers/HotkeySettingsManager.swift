//
//  HotkeySettingsManager.swift
//  Blink
//
//  Created by Ben on 3/26/26.
//

import Foundation
import ObservableDefaults

@MainActor @ObservableDefaults(autoInit: false)
final class HotkeySettingsManager {
    private static let hotkeysDefaultsKey = "hotkeys"

    /// All hotkeys.
    @ObservableOnly private(set) var hotkeys = BoundAction.allCases.map { action in
        Hotkey(keyCombination: nil, action: action)
    }

    /// Encoder for hotkeys.
    private let encoder = JSONEncoder()

    /// Decoder for hotkeys.
    private let decoder = JSONDecoder()

    /// The shared app state.
    @Ignore private(set) weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func performSetup() {
        loadInitialState()
        observeHotkeys()
        observeEnabled()
    }

    // MARK: - Setup

    private func loadInitialState() {
        guard let appState else { return }

        let dict =
            UserDefaults.standard.dictionary(forKey: Self.hotkeysDefaultsKey) as? [String: Data]

        for hotkey in hotkeys {
            hotkey.assignAppState(appState)

            if let data = dict?[hotkey.action.rawValue] {
                do {
                    let keyCombination = try decoder.decode(
                        KeyCombination?.self,
                        from: data
                    )
                    hotkey.keyCombination =
                        keyCombination == hotkey.action.defaultKeyCombination
                        ? hotkey.action.defaultKeyCombination
                        : keyCombination
                } catch {
                    Logger.hotkeySettingsManager.error("Error decoding hotkey: \(error)")
                    hotkey.keyCombination = hotkey.action.defaultKeyCombination
                }
            } else {
                hotkey.keyCombination = hotkey.action.defaultKeyCombination
            }
        }
    }

    // MARK: - Observation

    private func observeHotkeys() {
        withObservationTracking {
            // Track nested changes
            for hotkey in hotkeys {
                _ = hotkey.keyCombination
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.persistHotkeys()
                self?.observeHotkeys()  // re-arm
            }
        }
    }

    private func observeEnabled() {
        withObservationTracking {
            reconfigure()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.reconfigure()
                self?.observeEnabled()
            }
        }
    }

    private func reconfigure() {
        guard let appState else { return }
        if appState.settingsManager.generalSettingsManager.bindingsEnabled {
            for hotkey in hotkeys { hotkey.enable() }
        } else {
            for hotkey in hotkeys { hotkey.disable() }
        }
    }

    // MARK: - Persistence

    private func persistHotkeys() {
        guard let appState else { return }

        var dict = [String: Data]()

        for hotkey in hotkeys {
            hotkey.assignAppState(appState)

            guard hotkey.keyCombination != hotkey.action.defaultKeyCombination else {
                continue
            }

            do {
                dict[hotkey.action.rawValue] = try encoder.encode(hotkey.keyCombination)
            } catch {
                Logger.hotkeySettingsManager.error("Error encoding hotkey: \(error)")
            }
        }

        if dict.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.hotkeysDefaultsKey)
        } else {
            UserDefaults.standard.set(dict, forKey: Self.hotkeysDefaultsKey)
        }
    }

    // MARK: - Public API

    func hotkey(withAction action: BoundAction) -> Hotkey? {
        hotkeys.first { $0.action == action }
    }

    func resetHotkey(withAction action: BoundAction) {
        hotkey(withAction: action)?.keyCombination = action.defaultKeyCombination
    }

    func resetAllHotkeys() {
        for hotkey in hotkeys {
            hotkey.keyCombination = hotkey.action.defaultKeyCombination
        }
    }
}

// MARK: - Logger
extension Logger {
    fileprivate static let hotkeySettingsManager = Logger(category: "HotkeySettingsManager")
}
