//
//  GestureSettingsManager.swift
//  Blink
//
//  Created by Ben on 3/31/26.
//

import Foundation
import Observation

@MainActor @Observable
final class GestureSettingsManager {
    @ObservationIgnored private(set) weak var appState: AppState?
    @ObservationIgnored private let monitor = SwipeGestureMonitor()

    init(appState: AppState) {
        self.appState = appState
        monitor.onSwipe = { [weak self] direction, fingerCount in
            self?.handleSwipe(direction: direction, fingerCount: fingerCount)
        }
    }

    func performSetup() {
        trackAndReconfigure()
    }

    // MARK - Observation

    private func trackAndReconfigure() {
        withObservationTracking {
            reconfigure()
        } onChange: { [weak self] in
            guard let self else { return }
            Task { @MainActor [self] in
                self.trackAndReconfigure()
            }
        }
    }

    private func reconfigure() {
        guard let appState else {
            Logger.gestureSettingsManager.error("Missing app state")
            return
        }

        guard appState.settings.bindingsEnabled else {
            monitor.stopMonitoring()
            return
        }

        let anyEnabled = appState.bindingStore.swipeBindings.values.contains { $0.isEnabled }
        anyEnabled ? monitor.startMonitoring() : monitor.stopMonitoring()
    }

    // MARK - Swipe handling

    private func handleSwipe(direction: SwipeDirection, fingerCount: Int) {
        guard let appState else { return }
        let id = SwipeBindingID(direction: direction, fingerCount: fingerCount)
        guard let binding = appState.bindingStore.swipeBinding(for: id), binding.isEnabled else {
            return
        }
        binding.action.execute(appState: appState)
    }
}

// MARK: - Logger
extension Logger {
    fileprivate static let gestureSettingsManager = Logger(category: "GestureSettingsManager")
}
