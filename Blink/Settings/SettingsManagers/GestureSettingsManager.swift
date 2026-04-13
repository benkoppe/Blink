//
//  GestureSettingsManager.swift
//  Blink
//
//  Created by Ben on 3/31/26.
//

import Foundation
import ObservableDefaults

@MainActor @ObservableDefaults(autoInit: false)
final class GestureSettingsManager {
    @ObservableOnly private(set) var gestures: [SwipeGesture] = SwipeGestureID.allSlots.map {
        SwipeGesture(id: $0, action: nil)
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Ignore private(set) weak var appState: AppState?
    @Ignore private let monitor = SwipeGestureMonitor()
    @Ignore private let systemSwipeSuppressor = SystemSwipeSuppressor()

    @DefaultsKey(userDefaultsKey: "settings.disableSystemSwipeGestures")
    var disableSystemSwipeGestures: Bool = true

    @DefaultsKey(userDefaultsKey: "settings.allowSameDirectionRepeat")
    var allowSameDirectionRepeat: Bool = false
    @DefaultsKey(userDefaultsKey: "settings.sameDirectionRepeatSensitivity")
    var sameDirectionRepeatSensitivity: Double = defaultSameDirectionRepeatSensitivity
    static let defaultSameDirectionRepeatSensitivity: Double = 0.06

    init(appState: AppState) {
        self.appState = appState
        monitor.onSwipe = { [weak self] direction, fingerCount in
            self?.handleSwipe(direction: direction, fingerCount: fingerCount)
        }
        observerStarter()
    }

    func performSetup() {
        loadInitialState()
        observeGestures()
    }

    // MARK - Setup
    private func loadInitialState() {
        let dict = UserDefaults.standard.dictionary(forKey: "swipeGestures") as? [String: Data]
        for gesture in gestures {
            if let data = dict?[gesture.id.defaultsKey] {
                do {
                    gesture.action = try decoder.decode(BoundAction?.self, from: data)
                } catch {
                    Logger.gestureSettingsManager.error("Error decoding gesture action: \(error)")
                    gesture.action = gesture.id.defaultAction
                }
            } else {
                gesture.action = gesture.id.defaultAction
            }
        }
    }

    // MARK - Observation

    private func observeGestures() {
        withObservationTracking {
            reconfigure()
            for gesture in gestures { _ = gesture.action }
        } onChange: { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.persistGestures()
                self?.observeGestures()
            }
        }
    }

    private func reconfigure() {
        guard let appState else {
            Logger.gestureSettingsManager.error("Missing app state")
            monitor.stopMonitoring()
            systemSwipeSuppressor.stopMonitoring()
            return
        }

        let bindingsEnabled = appState.settingsManager.generalSettingsManager.bindingsEnabled
        monitor.allowSameDirectionRepeat = allowSameDirectionRepeat
        monitor.sameDirectionRepeatSensitivity = sameDirectionRepeatSensitivity

        let anyEnabled = bindingsEnabled && gestures.contains { $0.action != nil }
        anyEnabled ? monitor.startMonitoring() : monitor.stopMonitoring()

        let shouldSuppressSystemSwipes = bindingsEnabled && disableSystemSwipeGestures
        shouldSuppressSystemSwipes
            ? systemSwipeSuppressor.startMonitoring() : systemSwipeSuppressor.stopMonitoring()
    }

    // MARK - Persistence

    private func persistGestures() {
        var dict = [String: Data]()
        for gesture in gestures {
            do {
                dict[gesture.id.defaultsKey] = try encoder.encode(gesture.action)
            } catch {
                Logger.gestureSettingsManager.error("Error encoding gesture action: \(error)")
            }
        }
        UserDefaults.standard.set(dict, forKey: "swipeGestures")
    }

    // MARK - Swipe handling

    private func handleSwipe(direction: SwipeDirection, fingerCount: Int) {
        guard let appState else { return }
        let id = SwipeGestureID(direction: direction, fingerCount: fingerCount)
        guard let gesture = gesture(withID: id), let action = gesture.action else { return }
        action.execute(appState: appState)
    }

    // MARK: - Public API

    func gesture(withID id: SwipeGestureID) -> SwipeGesture? {
        gestures.first { $0.id == id }
    }

    func resetGesture(withID id: SwipeGestureID) {
        gesture(withID: id)?.action = id.defaultAction
    }

    func resetAllGestures() {
        for gesture in gestures {
            gesture.action = gesture.id.defaultAction
        }
    }
}

// MARK: - Logger
extension Logger {
    fileprivate static let gestureSettingsManager = Logger(category: "GestureSettingsManager")
}
