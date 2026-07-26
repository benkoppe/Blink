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
    private struct OverlayTransition {
        let previousMode: OverlayMode?
        let expiresAtUptime: TimeInterval
    }

    private static let overlayTransitionSettlementDuration: TimeInterval = 1

    @ObservableOnly private(set) var gestures: [SwipeGesture] = SwipeGestureID.allSlots.map {
        SwipeGesture(id: $0, action: nil)
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Ignore private let dispatcher: ActionDispatcher
    @Ignore private let generalSettings: GeneralSettingsManager
    @Ignore private let missionControlCapability: MissionControlSyntheticCapability
    @Ignore private let displayLocator: DisplayLocator
    @Ignore private let overlayDetector: CoreGraphicsOverlayDetector
    @Ignore private let monitor = SwipeGestureMonitor()
    @Ignore private let systemSwipeSuppressor = SystemSwipeSuppressor()
    @Ignore private let overlayModeSampler: OverlayModeSampler
    @Ignore private var lifecycleObservers: [NSObjectProtocol] = []
    @Ignore private var displayObservers: [NSObjectProtocol] = []
    @Ignore private var capabilityConsumer: Task<Void, Never>?
    @Ignore private var routingState = OverlayRoutingLeaseState()
    @Ignore private var gestureGeneration: UInt64 = 0
    @Ignore private var overlaySamplingEnabled = false
    @Ignore private var systemSwipeSuppressionEnabled = false
    @Ignore private var selectedGestureContext: GestureSessionContext?
    @Ignore private var overlayTransition: OverlayTransition?

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
            if let selectedGestureContext {
                if selectedGestureContext.route == .pending {
                    return promotePendingGestureContext(selectedGestureContext)
                }
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
            DiagnosticsStore.shared.record(
                "gesture-route",
                "selected route=\(route.rawValue) overlay=\(mode.rawValue)"
            )
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
                    DiagnosticsStore.shared.record(
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
        let generation = routingState.invalidate()
        selectedGestureContext = nil
        overlayTransition = nil
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

    private func requestOverlayRefresh() {
        guard overlaySamplingEnabled else { return }
        let generation = routingState.generation
        if let lease = routingState.lease,
            lease.generation == generation,
            (try? displayLocator.cursorDisplayID()) == lease.targetDisplayID,
            !OverlayRoutingFreshnessPolicy.standard.shouldRenewOpportunistically(
                lease,
                at: ProcessInfo.processInfo.systemUptime
            )
        {
            return
        }

        let sampler = overlayModeSampler
        Task {
            await sampler.opportunisticRefresh(generation: generation)
        }
    }

    private func invalidateOverlayStateAndRefresh() {
        let uptime = ProcessInfo.processInfo.systemUptime
        let previousMode = overlayTransition?.previousMode
            ?? routingState.lease?.overlayMode
        overlayTransition = OverlayTransition(
            previousMode: previousMode,
            expiresAtUptime: uptime + Self.overlayTransitionSettlementDuration
        )
        let generation = routingState.invalidate()
        guard overlaySamplingEnabled else { return }

        startOverlaySampler(
            generation: generation,
            settlesTransition: true
        )
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
        let previousMode = routingState.lease?.overlayMode ?? .unknown
        guard routingState.accept(lease) else { return }
        let transitionIsPending = overlayTransitionIsPending(
            observedMode: lease.overlayMode,
            at: lease.sampledAtUptime
        )
        missionControlCapability.observeOverlay(lease.overlayMode)
        if !transitionIsPending {
            updateSelectedGestureContext(from: lease)
        }
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
                MainActor.assumeIsolated {
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
        let uptime = ProcessInfo.processInfo.systemUptime
        if routingState.requiresSynchronousRefresh(
            currentDisplayID: displayID,
            at: uptime
        ) {
            let overlayMode = overlayDetector.detect(on: displayID)
            if overlayTransitionIsPending(
                observedMode: overlayMode,
                at: uptime
            ) {
                return .pending(
                    generation: gestureGeneration,
                    targetDisplayID: displayID,
                    capturedOverlayMode: overlayMode,
                    missionControlSyntheticState: missionControlCapability.state
                )
            }
            if overlayMode != .unknown {
                missionControlCapability.observeOverlay(overlayMode)
                return .observed(
                    generation: gestureGeneration,
                    targetDisplayID: displayID,
                    overlayMode: overlayMode,
                    missionControlSyntheticState: missionControlCapability.state
                )
            }
        }
        return routingState.makeContext(
            sessionGeneration: gestureGeneration,
            currentDisplayID: displayID,
            at: uptime,
            missionControlSyntheticState: missionControlCapability.state
        )
    }

    private func updateSelectedGestureContext(from lease: OverlayRoutingLease) {
        guard
            let selectedGestureContext,
            selectedGestureContext.route != .system,
            selectedGestureContext.targetDisplayID == lease.targetDisplayID
        else {
            return
        }
        let updatedContext = GestureSessionContext.observed(
            generation: selectedGestureContext.generation,
            targetDisplayID: lease.targetDisplayID,
            overlayMode: lease.overlayMode,
            missionControlSyntheticState: missionControlCapability.state
        )
        guard updatedContext.isAuthoritativeBlinkContext else { return }
        self.selectedGestureContext = updatedContext
    }

    private func promotePendingGestureContext(
        _ pendingContext: GestureSessionContext
    ) -> GestureSessionContext {
        let uptime = ProcessInfo.processInfo.systemUptime
        let observedMode = routingState.lease?.overlayMode
        guard
            (try? displayLocator.cursorDisplayID()) == pendingContext.targetDisplayID,
            !overlayTransitionIsPending(observedMode: observedMode, at: uptime)
        else {
            return pendingContext
        }
        let context = routingState.makeContext(
            sessionGeneration: pendingContext.generation,
            currentDisplayID: pendingContext.targetDisplayID,
            at: uptime,
            missionControlSyntheticState: missionControlCapability.state
        )
        guard context.isAuthoritativeBlinkContext else { return pendingContext }
        selectedGestureContext = context
        return context
    }

    private func overlayTransitionIsPending(
        observedMode: OverlayMode?,
        at uptime: TimeInterval
    ) -> Bool {
        guard let transition = overlayTransition else { return false }
        guard uptime < transition.expiresAtUptime else {
            overlayTransition = nil
            return false
        }
        if let observedMode,
            observedMode != .unknown,
            let previousMode = transition.previousMode,
            observedMode != previousMode
        {
            overlayTransition = nil
            return false
        }
        return true
    }

    private func gestureContextIsValid(_ context: GestureSessionContext) -> Bool {
        generalSettings.bindingsEnabled
            && selectedGestureContext == context
            && context.isValidForDispatch(
                currentDisplayID: try? displayLocator.cursorDisplayID(),
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
