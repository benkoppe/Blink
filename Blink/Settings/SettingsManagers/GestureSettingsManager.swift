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
    @Ignore private let monitor = SwipeGestureMonitor()
    @Ignore private let systemSwipeSuppressor = SystemSwipeSuppressor()
    @Ignore private let displayLocator: any DisplayLocating
    @Ignore private let overlayDetector: CoreGraphicsOverlayDetector
    @Ignore private let overlayModeSampler: OverlayModeSampler
    @Ignore private var lifecycleObservers: [NSObjectProtocol] = []
    @Ignore private var displayObservers: [NSObjectProtocol] = []
    @Ignore private var routingState = OverlayRoutingLeaseState()
    @Ignore private var gestureGeneration: UInt64 = 0
    @Ignore private var overlaySamplingEnabled = false
    @Ignore private var systemSwipeSuppressionEnabled = false
    @Ignore private var touchRoutingCoordinator = TouchRoutingSessionCoordinator()
    @Ignore private var isShutdown = false

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
        let displayLocator = DisplayLocator()
        let overlayDetector = CoreGraphicsOverlayDetector(displayLocator: displayLocator)
        self.displayLocator = displayLocator
        self.overlayDetector = overlayDetector
        self.overlayModeSampler = OverlayModeSampler(
            displayLocator: displayLocator,
            detector: overlayDetector
        )

        monitor.contextForRecognition = { [weak self] in
            guard let self else { return nil }
            if let context = touchRoutingCoordinator.selectedContext {
                return context
            }
            guard !systemSwipeSuppressionEnabled else { return nil }
            return bindCachedGestureContextIfNeeded()
        }
        monitor.isContextValidBeforeDispatch = { [weak self] context in
            self?.gestureContextIsValid(context) ?? false
        }
        monitor.onRecognitionSessionBegan = { [weak self] id in
            self?.beginTouchRoutingSession(id: id)
        }
        monitor.onRecognitionSessionEnded = { [weak self] id in
            self?.endTouchRoutingSession(id: id)
        }
        systemSwipeSuppressor.contextForNewGesture = { [weak self] in
            self?.contextForDockSegment()
        }
        systemSwipeSuppressor.onPotentialOverlayTransition = { [weak self] in
            self?.invalidateOverlayStateAndRefresh()
        }
        systemSwipeSuppressor.onContextSelected = { context in
            let route = context?.route.rawValue ?? "system"
            let overlay = context?.capturedOverlayMode.rawValue ?? "unavailable"
            DispatchQueue.main.async {
                DiagnosticsStore.shared.record(
                    "gesture-route",
                    "selected route=\(route) overlay=\(overlay)"
                )
            }
        }
        systemSwipeSuppressor.onMonitoringInterrupted = { [weak self] in
            self?.interruptTouchRoutingSession()
            self?.monitor.invalidateRecognition()
        }

        monitor.onSwipe = { [weak self] context, direction, fingerCount in
            self?.handleSwipe(
                context: context,
                direction: direction,
                fingerCount: fingerCount
            )
        }
        observerStarter()
    }

    func performSetup() {
        guard !isShutdown else { return }
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
            let overlayModeSampler = overlayModeSampler
            Task {
                await overlayModeSampler.stop(generation: .max)
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
        guard !isShutdown else { return }
        withObservationTracking {
            reconfigure()
            for gesture in gestures { _ = gesture.action }
        } onChange: { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, !isShutdown else { return }
                persistGestures()
                observeGestures()
            }
        }
    }

    private func reconfigure() {
        guard !isShutdown else { return }
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

        // Suppressed gestures take an authoritative boundary observation.
        // Background sampling is only needed when recognition runs without
        // the suppressing tap, so the two paths never contend with each other.
        setOverlaySamplingEnabled(anyEnabled && !shouldSuppressSystemSwipes)
    }

    private func setOverlaySamplingEnabled(_ enabled: Bool) {
        guard overlaySamplingEnabled != enabled else { return }
        overlaySamplingEnabled = enabled
        let generation = routingState.invalidate()
        interruptTouchRoutingSession()
        let sampler = overlayModeSampler

        if enabled {
            startOverlaySampler(
                generation: generation,
                settlesTransition: false
            )
        } else {
            Task {
                await sampler.stop(generation: generation)
            }
        }
    }

    private func invalidateOverlayStateAndRefresh() {
        let generation = routingState.invalidate()
        // Input-time ownership remains fixed until physical finger-up. The
        // invalidation applies only to future touch sessions.
        guard overlaySamplingEnabled else { return }
        startOverlaySampler(generation: generation, settlesTransition: true)
    }

    private func startOverlaySampler(
        generation: UInt64,
        settlesTransition: Bool
    ) {
        let sampler = overlayModeSampler
        Task { [weak self] in
            await sampler.start(
                generation: generation,
                settlesTransition: settlesTransition
            ) { [weak self] lease in
                Task { @MainActor [weak self] in
                    self?.updateRoutingLease(lease)
                }
            }
        }
    }

    private func updateRoutingLease(_ lease: OverlayRoutingLease) {
        guard !isShutdown else { return }
        let previousMode = routingState.lease?.overlayMode ?? .unknown
        guard routingState.accept(lease) else { return }
        missionControlCapability.observeOverlay(
            lease.overlayMode,
            on: lease.targetDisplayID,
            sampledAtUptime: lease.sampledAtUptime
        )
        guard previousMode != lease.overlayMode else { return }

        DiagnosticsStore.shared.record(
            "overlay",
            "mode=\(lease.overlayMode.rawValue)"
        )
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
                    MainActor.assumeIsolated {
                        guard let self, !self.isShutdown else { return }
                        self.invalidateOverlayStateAndRefresh()
                        self.monitor.ensureMonitoring()
                        self.systemSwipeSuppressor.ensureMonitoring()
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
                MainActor.assumeIsolated {
                    guard let self, !self.isShutdown else { return }
                    self.invalidateOverlayStateAndRefresh()
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

    private func beginTouchRoutingSession(id: UInt64) {
        touchRoutingCoordinator.beginTouchSession(id: id)
    }

    private func endTouchRoutingSession(id: UInt64) {
        _ = touchRoutingCoordinator.endTouchSession(id: id)
    }

    private func interruptTouchRoutingSession() {
        touchRoutingCoordinator.interrupt()
    }

    private func contextForDockSegment() -> GestureSessionContext? {
        if touchRoutingCoordinator.hasOwnershipDecision {
            return touchRoutingCoordinator.selectedContext
        }
        let context = selectSuppressionContext()
        touchRoutingCoordinator.bindContext(context)
        return context
    }

    private func bindCachedGestureContextIfNeeded() -> GestureSessionContext? {
        if touchRoutingCoordinator.hasOwnershipDecision {
            return touchRoutingCoordinator.selectedContext
        }
        let context = selectGestureContext()
        touchRoutingCoordinator.bindContext(context)
        return context
    }

    /// Dock requires an ownership answer from its `began` callback. A cached
    /// observation cannot prove that an unobserved Exposé transition did not
    /// occur, so ownership uses one authoritative boundary observation rather
    /// than a timeout, pending route, or stale lease.
    private func selectSuppressionContext() -> GestureSessionContext? {
        guard
            systemSwipeSuppressionEnabled,
            let displayID = try? displayLocator.cursorDisplayID()
        else {
            return nil
        }

        gestureGeneration &+= 1
        let sampledAtUptime = ProcessInfo.processInfo.systemUptime
        let overlayMode = overlayDetector.detect(on: displayID)
        guard overlayMode != .unknown else { return nil }

        missionControlCapability.observeOverlay(
            overlayMode,
            on: displayID,
            sampledAtUptime: sampledAtUptime
        )
        return .observed(
            generation: gestureGeneration,
            targetDisplayID: displayID,
            overlayMode: overlayMode,
            missionControlSyntheticState: missionControlCapability.state
        )
    }

    private func selectGestureContext() -> GestureSessionContext? {
        gestureGeneration &+= 1
        return routingState.makeContext(
            sessionGeneration: gestureGeneration,
            at: ProcessInfo.processInfo.systemUptime,
            missionControlSyntheticState: missionControlCapability.state
        )
    }

    private func gestureContextIsValid(_ context: GestureSessionContext) -> Bool {
        generalSettings.bindingsEnabled
            && touchRoutingCoordinator.selectedContext == context
            && context.isValidForDispatch(
                currentDisplayID: context.targetDisplayID,
                currentMissionControlSyntheticState: missionControlCapability.state
            )
    }

    private func handleSwipe(
        context: GestureSessionContext,
        direction: SwipeDirection,
        fingerCount: Int
    ) {
        guard gestureContextIsValid(context) else { return }
        let id = SwipeGestureID(direction: direction, fingerCount: fingerCount)
        guard let gesture = gesture(withID: id), let action = gesture.action else { return }
        dispatcher.dispatch(action.spaceSwitchAction, gestureContext: context)
    }

    // MARK: - Public API

    func shutdown() async {
        guard !isShutdown else { return }
        isShutdown = true
        monitor.stopMonitoring()
        systemSwipeSuppressor.stopMonitoring()
        overlaySamplingEnabled = false
        interruptTouchRoutingSession()
        let generation = routingState.invalidate()
        await overlayModeSampler.stop(generation: generation)

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        lifecycleObservers.forEach(workspaceCenter.removeObserver)
        lifecycleObservers.removeAll()
        let defaultCenter = NotificationCenter.default
        displayObservers.forEach(defaultCenter.removeObserver)
        displayObservers.removeAll()
    }

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
