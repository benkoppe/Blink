//
//  GestureSettingsManager.swift
//  Blink
//
//  Created by Ben on 3/31/26.
//

import AppKit
import Foundation
import ObservableDefaults

@MainActor @ObservableDefaults(autoInit: false)
final class GestureSettingsManager {
    @ObservableOnly private(set) var gestures: [SwipeGesture] = SwipeGestureID.allSlots.map {
        SwipeGesture(id: $0, action: nil)
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Ignore private let dispatcher: ActionDispatcher
    @Ignore private let generalSettings: GeneralSettingsManager
    @Ignore private let monitor = SwipeGestureMonitor()
    @Ignore private let systemSwipeSuppressor = SystemSwipeSuppressor()
    @Ignore private let overlayModePoller = OverlayModePoller()
    @Ignore private var lifecycleObservers: [NSObjectProtocol] = []
    @Ignore private var routingSnapshot = GestureRoutingSnapshot.unknown
    @Ignore private var selectedGestureRoute: GestureRoute?
    @Ignore private var missionControlSyntheticEnabled = true

    @DefaultsKey(userDefaultsKey: "settings.disableSystemSwipeGestures")
    var disableSystemSwipeGestures: Bool = true

    @DefaultsKey(userDefaultsKey: "settings.flipSwipeDirection")
    var flipSwipeDirection: Bool = false

    @DefaultsKey(userDefaultsKey: "settings.allowSameDirectionRepeat")
    var allowSameDirectionRepeat: Bool = false
    @DefaultsKey(userDefaultsKey: "settings.sameDirectionRepeatSensitivity")
    var sameDirectionRepeatSensitivity: Double = defaultSameDirectionRepeatSensitivity
    static let defaultSameDirectionRepeatSensitivity: Double = 0.06

    init(
        dispatcher: ActionDispatcher,
        generalSettings: GeneralSettingsManager
    ) {
        self.dispatcher = dispatcher
        self.generalSettings = generalSettings

        monitor.shouldIgnoreSwipe = { [weak self] in
            guard let self else { return true }
            return (selectedGestureRoute ?? currentRoute) == .system
        }
        systemSwipeSuppressor.routeForNewGesture = { [weak self] in
            self?.currentRoute ?? .system
        }
        systemSwipeSuppressor.onGestureMayBegin = { [weak self] in
            self?.requestOverlayRefresh()
        }
        systemSwipeSuppressor.onPotentialOverlayTransition = { [weak self] in
            self?.routingSnapshot = .unknown
            self?.requestOverlayRefresh()
        }
        systemSwipeSuppressor.onRouteSelected = { [weak self] route in
            guard let self else { return }
            selectedGestureRoute = route
            let mode = routingSnapshot.overlayMode
            Task {
                await DiagnosticsStore.shared.record(
                    "gesture-route",
                    "selected route=\(route.rawValue) overlay=\(mode.rawValue)"
                )
            }
        }
        systemSwipeSuppressor.onGestureEnded = { [weak self] in
            self?.selectedGestureRoute = nil
        }

        monitor.onSwipe = { [weak self] direction, fingerCount in
            self?.handleSwipe(direction: direction, fingerCount: fingerCount)
        }
        observerStarter()
    }

    func performSetup() {
        loadInitialState()
        observeLifecycle()
        observeGestures()
    }

    deinit {
        MainActor.assumeIsolated {
            let center = NSWorkspace.shared.notificationCenter
            lifecycleObservers.forEach(center.removeObserver)
            let overlayModePoller = overlayModePoller
            Task {
                await overlayModePoller.stop()
            }
        }
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
        let bindingsEnabled = generalSettings.bindingsEnabled
        monitor.allowSameDirectionRepeat = allowSameDirectionRepeat
        monitor.sameDirectionRepeatSensitivity = sameDirectionRepeatSensitivity
        monitor.flipSwipeDirection = flipSwipeDirection

        let anyEnabled = bindingsEnabled && gestures.contains { $0.action != nil }
        anyEnabled ? monitor.startMonitoring() : monitor.stopMonitoring()

        let shouldSuppressSystemSwipes = bindingsEnabled && disableSystemSwipeGestures
        shouldSuppressSystemSwipes
            ? systemSwipeSuppressor.startMonitoring() : systemSwipeSuppressor.stopMonitoring()

        setOverlayPollingEnabled(anyEnabled || shouldSuppressSystemSwipes)
    }

    private var currentRoute: GestureRoute {
        routingSnapshot.route(
            at: ProcessInfo.processInfo.systemUptime,
            missionControlSyntheticEnabled: missionControlSyntheticEnabled
        )
    }

    private func setOverlayPollingEnabled(_ enabled: Bool) {
        let poller = overlayModePoller
        if enabled {
            Task { [weak self] in
                await poller.start { [weak self] snapshot in
                    Task { @MainActor [weak self] in
                        self?.updateRoutingSnapshot(snapshot)
                    }
                }
            }
        } else {
            routingSnapshot = .unknown
            Task {
                await poller.stop()
            }
        }
    }

    private func requestOverlayRefresh() {
        let poller = overlayModePoller
        Task {
            await poller.refresh()
        }
    }

    private func updateRoutingSnapshot(_ snapshot: GestureRoutingSnapshot) {
        let previousMode = routingSnapshot.overlayMode
        routingSnapshot = snapshot
        if snapshot.overlayMode == .none {
            missionControlSyntheticEnabled = true
        }
        guard previousMode != snapshot.overlayMode else { return }

        Task {
            await DiagnosticsStore.shared.record(
                "overlay",
                "mode=\(snapshot.overlayMode.rawValue)"
            )
        }
    }

    private func observeLifecycle() {
        guard lifecycleObservers.isEmpty else { return }

        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ] {
            lifecycleObservers.append(
                center.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.routingSnapshot = .unknown
                        self?.requestOverlayRefresh()
                        self?.monitor.ensureMonitoring()
                        self?.systemSwipeSuppressor.ensureMonitoring()
                    }
                }
            )
        }
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
        let id = SwipeGestureID(direction: direction, fingerCount: fingerCount)
        guard let gesture = gesture(withID: id), let action = gesture.action else { return }
        dispatcher.dispatch(action, source: .gesture)
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

    func disableMissionControlSyntheticForCurrentSession() {
        guard missionControlSyntheticEnabled else { return }
        missionControlSyntheticEnabled = false
        selectedGestureRoute = nil
        Task {
            await DiagnosticsStore.shared.record(
                "gesture-route",
                "Mission Control synthetic path failed; falling back to macOS"
            )
        }
    }
}

// MARK: - Logger
extension Logger {
    fileprivate static let gestureSettingsManager = Logger(category: "GestureSettingsManager")
}
