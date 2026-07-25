import Foundation

nonisolated enum GestureRoute: String, Equatable, Sendable {
    case blink
    case system
}

nonisolated struct GestureSessionContext: Equatable, Sendable {
    let generation: UInt64
    let route: GestureRoute
    let targetDisplayID: DisplayID
    let capturedOverlayMode: OverlayMode
    let missionControlSyntheticState: MissionControlSyntheticState
    let requiredPostingMode: SpaceSwitchMode?

    var isAuthoritativeBlinkContext: Bool {
        guard route == .blink else { return false }
        switch (capturedOverlayMode, requiredPostingMode) {
        case (.none, .instant), (.missionControl, .missionControl):
            return missionControlSyntheticState == .available
                || requiredPostingMode == .instant
        default:
            return false
        }
    }
}

nonisolated struct GestureRoutingSnapshot: Equatable, Sendable {
    private static let maximumAge: TimeInterval = 0.3

    let overlayMode: OverlayMode
    let sampledAtUptime: TimeInterval
    let targetDisplayID: DisplayID?
    let generation: UInt64

    init(
        overlayMode: OverlayMode,
        sampledAtUptime: TimeInterval,
        targetDisplayID: DisplayID? = nil,
        generation: UInt64 = 0
    ) {
        self.overlayMode = overlayMode
        self.sampledAtUptime = sampledAtUptime
        self.targetDisplayID = targetDisplayID
        self.generation = generation
    }

    static let unknown = GestureRoutingSnapshot(
        overlayMode: .unknown,
        sampledAtUptime: 0
    )

    func route(
        at uptime: TimeInterval,
        missionControlSyntheticState: MissionControlSyntheticState = .available
    ) -> GestureRoute {
        guard isFresh(at: uptime) else { return .system }

        switch overlayMode {
        case .none:
            return .blink
        case .missionControl:
            return missionControlSyntheticState == .available ? .blink : .system
        case .appExpose, .unknown:
            return .system
        }
    }

    func makeContext(
        sessionGeneration: UInt64,
        currentDisplayID: DisplayID,
        at uptime: TimeInterval,
        missionControlSyntheticState: MissionControlSyntheticState
    ) -> GestureSessionContext {
        let agreesWithSample = targetDisplayID == currentDisplayID
        let selectedRoute = agreesWithSample
            ? route(
                at: uptime,
                missionControlSyntheticState: missionControlSyntheticState
            )
            : .system
        let capturedMode = agreesWithSample && isFresh(at: uptime)
            ? overlayMode
            : .unknown
        let postingMode: SpaceSwitchMode? =
            if selectedRoute == .blink {
                switch capturedMode {
                case .none: .instant
                case .missionControl: .missionControl
                case .appExpose, .unknown: nil
                }
            } else {
                nil
            }

        return GestureSessionContext(
            generation: sessionGeneration,
            route: postingMode == nil && selectedRoute == .blink ? .system : selectedRoute,
            targetDisplayID: currentDisplayID,
            capturedOverlayMode: capturedMode,
            missionControlSyntheticState: missionControlSyntheticState,
            requiredPostingMode: postingMode
        )
    }

    private func isFresh(at uptime: TimeInterval) -> Bool {
        sampledAtUptime > 0
            && uptime >= sampledAtUptime
            && uptime - sampledAtUptime <= Self.maximumAge
    }
}

actor OverlayModeSampler {
    private let displayLocator: any DisplayLocating
    private let detector: any OverlayDetecting
    private var samplingTask: Task<Void, Never>?
    private var requestSequence: UInt64 = 0
    private var acceptedGeneration: UInt64 = 0
    private var onUpdate: (@Sendable (GestureRoutingSnapshot) -> Void)?

    init(
        displayLocator: any DisplayLocating,
        detector: any OverlayDetecting
    ) {
        self.displayLocator = displayLocator
        self.detector = detector
    }

    init() {
        let displayLocator = DisplayLocator()
        self.displayLocator = displayLocator
        self.detector = CoreGraphicsOverlayDetector(displayLocator: displayLocator)
    }

    func start(
        generation: UInt64,
        onUpdate: @escaping @Sendable (GestureRoutingSnapshot) -> Void
    ) {
        self.onUpdate = onUpdate
        refresh(generation: generation)
    }

    func stop() {
        requestSequence &+= 1
        acceptedGeneration &+= 1
        samplingTask?.cancel()
        samplingTask = nil
        onUpdate = nil
    }

    func invalidate(generation: UInt64) {
        acceptedGeneration = max(acceptedGeneration, generation)
        requestSequence &+= 1
        samplingTask?.cancel()
        samplingTask = nil
    }

    func refresh(generation: UInt64) {
        guard onUpdate != nil, generation >= acceptedGeneration else { return }
        acceptedGeneration = generation
        requestSequence &+= 1
        let sequence = requestSequence
        samplingTask?.cancel()

        let displayLocator = displayLocator
        let detector = detector
        samplingTask = Task { [weak self] in
            let snapshot = await Task.detached {
                guard let displayID = try? displayLocator.cursorDisplayID() else {
                    return GestureRoutingSnapshot(
                        overlayMode: .unknown,
                        sampledAtUptime: ProcessInfo.processInfo.systemUptime,
                        generation: generation
                    )
                }
                return GestureRoutingSnapshot(
                    overlayMode: detector.detect(on: displayID),
                    sampledAtUptime: ProcessInfo.processInfo.systemUptime,
                    targetDisplayID: displayID,
                    generation: generation
                )
            }.value
            guard !Task.isCancelled else { return }
            await self?.complete(
                snapshot,
                sequence: sequence,
                generation: generation
            )
        }
    }

    private func complete(
        _ snapshot: GestureRoutingSnapshot,
        sequence: UInt64,
        generation: UInt64
    ) {
        guard
            sequence == requestSequence,
            generation == acceptedGeneration,
            onUpdate != nil
        else {
            return
        }
        samplingTask = nil
        onUpdate?(snapshot)
    }
}
