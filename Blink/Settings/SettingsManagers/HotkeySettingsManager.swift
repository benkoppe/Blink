import Foundation
import ObservableDefaults

@MainActor @ObservableDefaults(autoInit: false)
final class HotkeySettingsManager {
    private static let defaultsKey = "hotkeys"

    @ObservableOnly private(set) var hotkeys = BoundAction.allCases.map {
        Hotkey(keyCombination: nil, action: $0)
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Ignore private let registry: HotkeyRegistry
    @Ignore private let dispatcher: ActionDispatcher
    @Ignore private let generalSettings: GeneralSettingsManager
    @Ignore private var registrationIDs: [BoundAction: UInt32] = [:]
    @Ignore private var recordingActions: Set<BoundAction> = []

    init(
        registry: HotkeyRegistry,
        dispatcher: ActionDispatcher,
        generalSettings: GeneralSettingsManager
    ) {
        self.registry = registry
        self.dispatcher = dispatcher
        self.generalSettings = generalSettings
    }

    deinit {
        MainActor.assumeIsolated {
            registrationIDs.values.forEach(registry.unregister)
        }
    }

    func performSetup() {
        loadInitialState()
        observeConfiguration()
    }

    func setRecording(_ isRecording: Bool, action: BoundAction) {
        if isRecording {
            recordingActions.insert(action)
        } else {
            recordingActions.remove(action)
        }
        reconfigure()
    }

    private func loadInitialState() {
        let values = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: Data]

        for hotkey in hotkeys {
            guard let data = values?[hotkey.action.rawValue] else {
                hotkey.keyCombination = hotkey.action.defaultKeyCombination
                continue
            }

            do {
                hotkey.keyCombination = try decoder.decode(KeyCombination?.self, from: data)
            } catch {
                Logger.hotkeySettingsManager.error("Error decoding hotkey: \(error)")
                hotkey.keyCombination = hotkey.action.defaultKeyCombination
            }
        }
    }

    private func observeConfiguration() {
        withObservationTracking {
            _ = generalSettings.bindingsEnabled
            hotkeys.forEach { _ = $0.keyCombination }
            reconfigure()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.persistHotkeys()
                self?.observeConfiguration()
            }
        }
    }

    private func reconfigure() {
        registrationIDs.values.forEach(registry.unregister)
        registrationIDs.removeAll()

        guard generalSettings.bindingsEnabled else { return }

        for hotkey in hotkeys where !recordingActions.contains(hotkey.action) {
            guard hotkey.keyCombination != nil else { continue }

            let action = hotkey.action
            registrationIDs[action] = registry.register(
                hotkey: hotkey,
                eventKind: .keyDown
            ) { [weak dispatcher] in
                dispatcher?.dispatch(action, source: .hotkey)
            }
        }
    }

    private func persistHotkeys() {
        var values: [String: Data] = [:]

        for hotkey in hotkeys {
            guard hotkey.keyCombination != hotkey.action.defaultKeyCombination else {
                continue
            }

            do {
                values[hotkey.action.rawValue] = try encoder.encode(hotkey.keyCombination)
            } catch {
                Logger.hotkeySettingsManager.error("Error encoding hotkey: \(error)")
            }
        }

        if values.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        } else {
            UserDefaults.standard.set(values, forKey: Self.defaultsKey)
        }
    }

    func hotkey(withAction action: BoundAction) -> Hotkey? {
        hotkeys.first { $0.action == action }
    }

    func resetHotkey(withAction action: BoundAction) {
        hotkey(withAction: action)?.keyCombination = action.defaultKeyCombination
    }

    func resetAllHotkeys() {
        hotkeys.forEach { $0.keyCombination = $0.action.defaultKeyCombination }
    }
}

extension Logger {
    fileprivate static let hotkeySettingsManager = Logger(category: "HotkeySettingsManager")
}
