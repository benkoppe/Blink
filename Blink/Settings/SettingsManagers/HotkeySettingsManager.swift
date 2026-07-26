import AppKit
import Foundation
import ObservableDefaults

@MainActor @ObservableDefaults(autoInit: false)
final class HotkeySettingsManager {
    private static let defaultsKey = "hotkeys"

    @ObservableOnly private(set) var hotkeys = BoundAction.allCases.map {
        Hotkey(keyCombination: nil, action: $0)
    }
    @ObservableOnly private(set) var monitoringState: HotkeyMonitoringState = .disabled

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private struct RegisteredBinding {
        let id: UInt32
        let keyCombination: KeyCombination
    }

    @Ignore private let registry: HotkeyRegistry
    @Ignore private let dispatcher: ActionDispatcher
    @Ignore private let generalSettings: GeneralSettingsManager
    @Ignore private var registeredBindings: [BoundAction: RegisteredBinding] = [:]
    @Ignore private var registrationFailures: [BoundAction: HotkeyRegistrationFailure] = [:]
    @Ignore private var recordingActions: Set<BoundAction> = []
    @Ignore private var lifecycleObservers: [NSObjectProtocol] = []
    @Ignore private var isShutdown = false

    init(
        registry: HotkeyRegistry,
        dispatcher: ActionDispatcher,
        generalSettings: GeneralSettingsManager
    ) {
        self.registry = registry
        self.dispatcher = dispatcher
        self.generalSettings = generalSettings
        self.monitoringState = registry.monitoringState
        registry.onMonitoringStateChanged = { [weak self] state in
            guard let self else { return }
            monitoringState = state
            refreshRegistrationStates()
        }
    }

    deinit {
        MainActor.assumeIsolated {
            registry.onMonitoringStateChanged = nil
            registeredBindings.values.forEach { registry.unregister($0.id) }
            let center = NSWorkspace.shared.notificationCenter
            lifecycleObservers.forEach(center.removeObserver)
        }
    }

    func performSetup() {
        guard !isShutdown else { return }
        loadInitialState()
        observeLifecycle()
        observeConfiguration()
    }

    @discardableResult
    func beginRecording(
        action: BoundAction,
        handler: @escaping (HotkeyKeyEvent) -> Void
    ) -> Bool {
        guard !isShutdown else { return false }
        recordingActions.insert(action)
        reconfigure()
        guard registry.beginRecording(handler: handler) else {
            recordingActions.remove(action)
            reconfigure()
            return false
        }
        return true
    }

    func endRecording(action: BoundAction) {
        registry.endRecording()
        recordingActions.remove(action)
        reconfigure()
    }

    /// Assigning a shortcut already owned by Blink swaps the two actions. The
    /// recorder therefore never leaves a newly-created duplicate disabled.
    func assignRecordedCombination(
        _ combination: KeyCombination,
        to action: BoundAction
    ) {
        guard let target = hotkey(withAction: action) else { return }
        let previous = target.keyCombination
        if let owner = hotkeys.first(where: {
            $0.action != action && $0.keyCombination == combination
        }) {
            owner.keyCombination = previous
        }
        target.keyCombination = combination
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

    private func observeLifecycle() {
        guard lifecycleObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            lifecycleObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, !self.isShutdown else { return }
                        self.registry.ensureMonitoring()
                        self.reconfigure()
                    }
                }
            )
        }
    }

    private func observeConfiguration() {
        guard !isShutdown else { return }
        withObservationTracking {
            _ = generalSettings.bindingsEnabled
            hotkeys.forEach { _ = $0.keyCombination }
            reconfigure()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !isShutdown else { return }
                persistHotkeys()
                observeConfiguration()
            }
        }
    }

    /// Reconciles individual registrations so recording or editing one action
    /// does not interrupt unrelated hotkeys.
    private func reconfigure() {
        guard !isShutdown else { return }
        let duplicateConflicts = duplicateConflictsByAction()
        registrationFailures = duplicateConflicts.mapValues {
            .duplicateBinding(conflictingActions: $0)
        }

        let desiredCombinations: [BoundAction: KeyCombination] = Dictionary(
            uniqueKeysWithValues: hotkeys.compactMap { hotkey in
                guard
                    generalSettings.bindingsEnabled,
                    let combination = hotkey.keyCombination,
                    !recordingActions.contains(hotkey.action),
                    duplicateConflicts[hotkey.action] == nil
                else { return nil }
                return (hotkey.action, combination)
            }
        )

        for action in BoundAction.allCases {
            guard let registered = registeredBindings[action] else { continue }
            if desiredCombinations[action] != registered.keyCombination {
                registry.unregister(registered.id)
                registeredBindings.removeValue(forKey: action)
            }
        }

        if desiredCombinations.isEmpty && registeredBindings.isEmpty {
            registry.stopMonitoring()
        }

        let actionsNeedingRegistration = BoundAction.allCases.filter {
            registeredBindings[$0] == nil && desiredCombinations[$0] != nil
        }
        let monitorIsReady = actionsNeedingRegistration.isEmpty
            || registry.prepareForRegistration()

        for action in actionsNeedingRegistration {
            guard let combination = desiredCombinations[action] else { continue }
            guard monitorIsReady else {
                registrationFailures[action] = .monitoringUnavailable(.eventTapUnavailable)
                continue
            }

            switch registry.registerPrepared(keyCombination: combination, handler: { [weak dispatcher] in
                dispatcher?.dispatch(action.spaceSwitchAction, source: .hotkey)
            }) {
            case .success(let id):
                registeredBindings[action] = RegisteredBinding(
                    id: id,
                    keyCombination: combination
                )
            case .failure(.monitoringFailed(let reason)):
                registrationFailures[action] = .monitoringUnavailable(reason)
            case .failure(.duplicate):
                registrationFailures[action] = .registryConflict
            case .failure(.notConfigured):
                break
            }
        }

        monitoringState = registry.monitoringState
        refreshRegistrationStates(duplicateConflicts: duplicateConflicts)
    }

    private func refreshRegistrationStates(
        duplicateConflicts: [BoundAction: [BoundAction]]? = nil
    ) {
        let conflicts = duplicateConflicts ?? duplicateConflictsByAction()

        for hotkey in hotkeys {
            let state: HotkeyRegistrationState
            if !generalSettings.bindingsEnabled
                || !hotkey.isConfigured
                || recordingActions.contains(hotkey.action)
            {
                state = .disabled
            } else if let conflictingActions = conflicts[hotkey.action] {
                state = .failed(.duplicateBinding(conflictingActions: conflictingActions))
            } else if let failure = registrationFailures[hotkey.action] {
                state = .failed(failure)
            } else if registeredBindings[hotkey.action] != nil {
                switch monitoringState {
                case .active:
                    state = .active
                case .failed(let reason):
                    state = .failed(.monitoringUnavailable(reason))
                case .disabled:
                    state = .failed(.monitoringUnavailable(.eventTapUnavailable))
                }
            } else if case .failed(let reason) = monitoringState {
                state = .failed(.monitoringUnavailable(reason))
            } else {
                state = .disabled
            }
            hotkey.setRegistrationState(state)
        }
    }

    /// Duplicate combinations reject every involved action. No action receives
    /// an implicit priority based on registration or dictionary iteration order.
    private func duplicateConflictsByAction() -> [BoundAction: [BoundAction]] {
        var result: [BoundAction: [BoundAction]] = [:]
        for hotkey in hotkeys {
            guard let combination = hotkey.keyCombination else { continue }
            let matchingActions = hotkeys.compactMap { candidate in
                candidate.keyCombination == combination ? candidate.action : nil
            }
            guard matchingActions.count > 1 else { continue }
            result[hotkey.action] = matchingActions.filter { $0 != hotkey.action }
        }
        return result
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

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        registry.endRecording()
        recordingActions.removeAll()
        registeredBindings.values.forEach { registry.unregister($0.id) }
        registeredBindings.removeAll()
        registry.shutdown()

        let center = NSWorkspace.shared.notificationCenter
        lifecycleObservers.forEach(center.removeObserver)
        lifecycleObservers.removeAll()
        monitoringState = .disabled
        refreshRegistrationStates()
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
