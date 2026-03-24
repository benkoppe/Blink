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
    private let store: BindingStore
    private let monitor: SwipeGestureMonitor
    private let switcher: SpaceSwitcher

    init(
        store: BindingStore,
        monitor: SwipeGestureMonitor = SwipeGestureMonitor(),
        switcher: SpaceSwitcher
    ) {
        self.store = store
        self.monitor = monitor
        self.switcher = switcher

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
        // Monitor only when at least one swipe binding is enabled.
        let anyEnabled = store.swipeBindings.values.contains { $0.isEnabled }
        anyEnabled ? monitor.startMonitoring() : monitor.stopMonitoring()
    }

    private func handleSwipe(direction: SwipeDirection, fingerCount: Int) {
        let id = SwipeBindingID(direction: direction, fingerCount: fingerCount)
        guard let binding = store.swipeBinding(for: id), binding.isEnabled else { return }
        binding.action.execute(on: switcher)
    }
}
