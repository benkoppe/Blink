//
//  HotkeySettingsManager.swift
//  Blink
//
//  Created by Ben on 3/26/26.
//

import Foundation
import Observation

@MainActor @Observable
final class HotkeySettingsManager {
    /// All hotkeys.
    private(set) var hotkeys = BoundAction.allCases.map { action in
        Hotkey(keyCombination: nil, action: action)
    }

    /// Encoder for hotkeys.
    private let encoder = JSONEncoder()

    /// Decoder for hotkeys.
    private let decoder = JSONDecoder()

    /// The shared app state.
    @ObservationIgnored private(set) weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func performSetup() {
        loadInitialState()
        observeHotkeys()
    }

    // MARK: - Setup

    private func loadInitialState() {
        guard let appState else { return }

        let dict = UserDefaults.standard.dictionary(forKey: "hotkeys") as? [String: Data]

        for hotkey in hotkeys {
            hotkey.assignAppState(appState)

            if let data = dict?[hotkey.action.rawValue] {
                do {
                    hotkey.keyCombination = try decoder.decode(
                        KeyCombination.self,
                        from: data
                    )
                } catch {
                    Logger.hotkeySettingsManager.error("Error decoding hotkey: \(error)")
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

    // MARK: - Persistence

    private func persistHotkeys() {
        guard let appState else { return }

        var dict = [String: Data]()

        for hotkey in hotkeys {
            hotkey.assignAppState(appState)

            do {
                dict[hotkey.action.rawValue] = try encoder.encode(hotkey.keyCombination)
            } catch {
                Logger.hotkeySettingsManager.error("Error encoding hotkey: \(error)")
            }
        }

        UserDefaults.standard.set(dict, forKey: "hotkeys")
    }

    // MARK: - Public API

    func hotkey(withAction action: BoundAction) -> Hotkey? {
        hotkeys.first { $0.action == action }
    }
}

// MARK: - Logger
extension Logger {
    fileprivate static let hotkeySettingsManager = Logger(category: "HotkeySettingsManager")
}
