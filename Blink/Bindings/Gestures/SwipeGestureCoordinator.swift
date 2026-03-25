//
//  SwipeGestureCoordinator.swift
//  Blink
//
//  Created by Ben on 3/24/26.
//

import Foundation
import Observation

/// Observes BindingStore for swipe binding changes and keeps SwipeGestureMonitor in sync.
/// Mirrors the structure of HotkeyCoordinator.
final class SwipeGestureCoordinator {
    private weak var appState: AppState?
    private let monitor: SwipeGestureMonitor

    init(
        appState: AppState,
        monitor: SwipeGestureMonitor = SwipeGestureMonitor(),
    ) {
        self.appState = appState
        self.monitor = monitor

        // Wire the callback once. It reads current store state at fire time,
        // so it never goes stale when bindings change.
        monitor.onSwipe = { [weak self] direction, fingerCount in
            self?.handleSwipe(direction: direction, fingerCount: fingerCount)
        }

        trackAndReconfigure()
    }

    // MARK: - Private
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
            Logger.swipeGestureCoordinator.error("Error registering all hotkeys: Missing app state")
            return
        }

        guard appState.settings.bindingsEnabled else {
            monitor.stopMonitoring()
            return
        }

        // Monitor only when at least one swipe binding is enabled.
        let anyEnabled = appState.bindingStore.swipeBindings.values.contains { $0.isEnabled }
        anyEnabled ? monitor.startMonitoring() : monitor.stopMonitoring()
    }

    private func handleSwipe(direction: SwipeDirection, fingerCount: Int) {
        guard let appState else { return }

        let id = SwipeBindingID(direction: direction, fingerCount: fingerCount)
        guard let binding = appState.bindingStore.swipeBinding(for: id), binding.isEnabled else {
            return
        }
        binding.action.execute(on: appState.spaceSwitcher)
    }
}

// MARK: - Logger

extension Logger {
    fileprivate static let swipeGestureCoordinator = Logger(category: "SwipeGestureCoordinator")
}
