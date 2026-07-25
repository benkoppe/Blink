import Foundation

nonisolated enum GestureRoute: String, Equatable, Sendable {
    case blink
    case system
}

nonisolated struct GestureRoutingSnapshot: Equatable, Sendable {
    private static let maximumAge: TimeInterval = 0.3

    let overlayMode: OverlayMode
    let sampledAtUptime: TimeInterval

    static let unknown = GestureRoutingSnapshot(
        overlayMode: .unknown,
        sampledAtUptime: 0
    )

    func route(
        at uptime: TimeInterval,
        missionControlSyntheticState: MissionControlSyntheticState = .available
    ) -> GestureRoute {
        guard
            sampledAtUptime > 0,
            uptime - sampledAtUptime <= Self.maximumAge
        else {
            return .system
        }

        switch overlayMode {
        case .none:
            return .blink
        case .missionControl:
            return missionControlSyntheticState == .available ? .blink : .system
        case .appExpose, .unknown:
            return .system
        }
    }
}

actor OverlayModePoller {
    private static let interval: Duration = .milliseconds(100)

    private let displayLocator: any DisplayLocating
    private let detector: any OverlayDetecting
    private var pollingTask: Task<Void, Never>?
    private var onUpdate: (@Sendable (GestureRoutingSnapshot) -> Void)?

    init() {
        let displayLocator = DisplayLocator()
        self.displayLocator = displayLocator
        self.detector = CoreGraphicsOverlayDetector(displayLocator: displayLocator)
    }

    func start(
        onUpdate: @escaping @Sendable (GestureRoutingSnapshot) -> Void
    ) {
        self.onUpdate = onUpdate
        guard pollingTask == nil else {
            sample()
            return
        }

        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.sample()
                do {
                    try await Task<Never, Never>.sleep(for: Self.interval)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        onUpdate = nil
    }

    func refresh() {
        guard onUpdate != nil else { return }
        sample()
    }

    private func sample() {
        let mode: OverlayMode
        if let displayID = try? displayLocator.cursorDisplayID() {
            mode = detector.detect(on: displayID)
        } else {
            mode = .unknown
        }

        onUpdate?(
            GestureRoutingSnapshot(
                overlayMode: mode,
                sampledAtUptime: ProcessInfo.processInfo.systemUptime
            )
        )
    }
}
