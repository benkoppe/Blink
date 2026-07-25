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
    @Ignore private let missionControlCapability: MissionControlSyntheticCapability
    @Ignore private let displayLocator = DisplayLocator()
    @Ignore private let monitor = SwipeGestureMonitor()
    @Ignore private let systemSwipeSuppressor = SystemSwipeSuppressor()
    @Ignore private let overlayModeSampler = OverlayModeSampler()
    @Ignore private var lifecycleObservers: [NSObjectProtocol] = []
    @Ignore private var displayObservers: [NSObjectProtocol] = []
    @Ignore private var capabilityConsumer: Task<Void, Never>?
    @Ignore private var routingSnapshot = GestureRoutingSnapshot.unknown
    @Ignore private var routingGeneration: UInt64 = 0
    @Ignore private var gestureGeneration: UInt64 = 0
    @Ignore private var overlaySamplingEnabled = false
    @Ignore private var systemSwipeSuppressionEnabled = false
    @Ignore private var selectedGestureContext: GestureSessionContext?

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
        generalSettings: GeneralSettingsManager,
        missionControlCapability: MissionControlSyntheticCapability
    ) {
        self.dispatcher = dispatcher
        self.generalSettings = generalSettings
        self.missionControlCapability = missionControlCapability

        monitor.contextForRecognition = { [weak self] in
            guard let self else { return nil }
            if let selectedGestureContext {
                return selectedGestureContext
            }
            guard !systemSwipeSuppressionEnabled else { return nil }
            let context = selectGestureContext()
            selectedGestureContext = context
            return context
        }
        monitor.isContextValidBeforeDispatch = { [weak self] context in
            self?.gestureContextIsValid(context) ?? false
        }
        monitor.onRecognitionSessionEnded = { [weak self] in
            guard self?.systemSwipeSuppressionEnabled == false else { return }
            self?.selectedGestureContext = nil
        }
        systemSwipeSuppressor.contextForNewGesture = { [weak self] in
            self?.selectGestureContext()
        }
        systemSwipeSuppressor.onGestureMayBegin = { [weak self] in
            self?.requestOverlayRefresh()
        }
        systemSwipeSuppressor.onPotentialOverlayTransition = { [weak self] in
            self?.invalidateOverlayStateAndRefresh()
        }
        systemSwipeSuppressor.onContextSelected = { [weak self] context in
            guard let self else { return }
            selectedGestureContext = context
            let route = context?.route ?? .system
            let mode = context?.capturedOverlayMode ?? .unknown
            Task {
                await DiagnosticsStore.shared.record(
                    "gesture-route",
                    "selected route=\(route.rawValue) overlay=\(mode.rawValue)"
                )
            }
        }
        systemSwipeSuppressor.onGestureEnded = { [weak self] in
            self?.selectedGestureContext = nil
        }

        monitor.onSwipe = { [weak self] context, direction, fingerCount in
            self?.handleSwipe(
                context: context,
                direction: direction,
                fingerCount: fingerCount
            )
        }
        capabilityConsumer = Task { @MainActor [weak self, missionControlCapability] in
            for await state in missionControlCapability.changes {
                guard !Task.isCancelled else { break }
                if state == .unavailableUntilOverlayExit,
                    let context = self?.selectedGestureContext,
                    context.requiredPostingMode == .missionControl
                {
                    await DiagnosticsStore.shared.record(
                        "gesture-route",
                        "Mission Control capability changed during session=\(context.generation); dispatch will be rejected"
                    )
                }
            }
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
            let workspaceCenter = NSWorkspace.shared.notificationCenter
            lifecycleObservers.forEach(workspaceCenter.removeObserver)
            let defaultCenter = NotificationCenter.default
            displayObservers.forEach(defaultCenter.removeObserver)
            capabilityConsumer?.cancel()
            let overlayModeSampler = overlayModeSampler
            Task {
                await overlayModeSampler.stop()
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
        systemSwipeSuppressionEnabled = shouldSuppressSystemSwipes
        shouldSuppressSystemSwipes
            ? systemSwipeSuppressor.startMonitoring() : systemSwipeSuppressor.stopMonitoring()

        setOverlaySamplingEnabled(anyEnabled || shouldSuppressSystemSwipes)
    }

    private func setOverlaySamplingEnabled(_ enabled: Bool) {
        guard overlaySamplingEnabled != enabled else { return }
        overlaySamplingEnabled = enabled
        let sampler = overlayModeSampler
        if enabled {
            routingGeneration &+= 1
            let generation = routingGeneration
            routingSnapshot = .unknown
            Task { [weak self] in
                await sampler.start(generation: generation) { [weak self] snapshot in
                    Task { @MainActor [weak self] in
                        self?.updateRoutingSnapshot(snapshot)
                    }
                }
            }
        } else {
            routingGeneration &+= 1
            routingSnapshot = .unknown
            selectedGestureContext = nil
            Task {
                await sampler.stop()
            }
        }
    }

    private func requestOverlayRefresh() {
        let sampler = overlayModeSampler
        let generation = routingGeneration
        Task {
            await sampler.refresh(generation: generation)
        }
    }

    private func invalidateOverlayStateAndRefresh() {
        routingGeneration &+= 1
        let generation = routingGeneration
        routingSnapshot = .unknown
        let sampler = overlayModeSampler
        Task {
            await sampler.invalidate(generation: generation)
            await sampler.refresh(generation: generation)
        }
    }

    private func updateRoutingSnapshot(_ snapshot: GestureRoutingSnapshot) {
        guard snapshot.generation == routingGeneration else { return }
        let previousMode = routingSnapshot.overlayMode
        routingSnapshot = snapshot
        missionControlCapability.observeOverlay(snapshot.overlayMode)
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
                        self?.invalidateOverlayStateAndRefresh()
                        self?.monitor.ensureMonitoring()
                        self?.systemSwipeSuppressor.ensureMonitoring()
                    }
                }
            )
        }

        let defaultCenter = NotificationCenter.default
        displayObservers.append(
            defaultCenter.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.invalidateOverlayStateAndRefresh()
                }
            }
        )
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

    private func selectGestureContext() -> GestureSessionContext? {
        guard let displayID = try? displayLocator.cursorDisplayID() else {
            return nil
        }
        gestureGeneration &+= 1
        return routingSnapshot.makeContext(
            sessionGeneration: gestureGeneration,
            currentDisplayID: displayID,
            at: ProcessInfo.processInfo.systemUptime,
            missionControlSyntheticState: missionControlCapability.state
        )
    }

    private func gestureContextIsValid(_ context: GestureSessionContext) -> Bool {
        guard
            generalSettings.bindingsEnabled,
            selectedGestureContext == context,
            context.isAuthoritativeBlinkContext,
            (try? displayLocator.cursorDisplayID()) == context.targetDisplayID,
            routingSnapshot.generation == routingGeneration,
            routingSnapshot.targetDisplayID == context.targetDisplayID,
            routingSnapshot.overlayMode == context.capturedOverlayMode
        else {
            return false
        }
        return context.requiredPostingMode != .missionControl
            || missionControlCapability.state == .available
    }

    private func handleSwipe(
        context: GestureSessionContext,
        direction: SwipeDirection,
        fingerCount: Int
    ) {
        guard gestureContextIsValid(context) else { return }
        let id = SwipeGestureID(direction: direction, fingerCount: fingerCount)
        guard let gesture = gesture(withID: id), let action = gesture.action else { return }
        dispatcher.dispatch(action, gestureContext: context)
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
