import AppKit
import Foundation
import Observation

nonisolated struct SpaceInfo: Equatable, Sendable {
    let currentIndex: Int
    let spaceCount: Int

    var displayNumber: Int { currentIndex + 1 }
    var isAtLeftEdge: Bool { currentIndex == 0 }
    var isAtRightEdge: Bool { currentIndex + 1 >= spaceCount }

}

nonisolated struct SpaceSwitchConfiguration: Equatable, Sendable {
    static let defaultValue = SpaceSwitchConfiguration(
        wraps: false,
        velocity: 999_999
    )

    let wraps: Bool
    let velocity: Double

    init(wraps: Bool, velocity: Double) {
        self.wraps = wraps
        self.velocity = max(1, velocity)
    }
}

nonisolated struct SpaceActionContext: Equatable, Sendable {
    let targetDisplayID: DisplayID
    let topology: DisplayTopology
    let lastSpaceID: SpaceID?
    let configuration: SpaceSwitchConfiguration

    var spaceInfo: SpaceInfo {
        SpaceInfo(
            currentIndex: topology.currentIndex,
            spaceCount: topology.spaceIDs.count
        )
    }

    func title(forSpaceAt index: Int) -> String {
        "Space \(index + 1)"
    }

    func canSubmit(_ action: SpaceSwitchAction) -> Bool {
        switch action {
        case .step(.left):
            topology.spaceIDs.count > 1
                && (configuration.wraps || topology.currentIndex > 0)
        case .step(.right):
            topology.spaceIDs.count > 1
                && (configuration.wraps
                    || topology.currentIndex + 1 < topology.spaceIDs.count)
        case .index(let index):
            topology.spaceIDs.indices.contains(index)
        case .lastSpace:
            lastSpaceID.map {
                topology.spaceIDs.contains($0) && topology.currentSpaceID != $0
            } ?? false
        }
    }

    func request(
        for action: SpaceSwitchAction,
        source: SpaceInputSource
    ) -> SpaceSwitchRequest {
        SpaceSwitchRequest(
            action: action,
            source: source,
            targetDisplayID: targetDisplayID,
            wraps: configuration.wraps,
            velocity: configuration.velocity
        )
    }
}

nonisolated extension SpacePresentation {
    var menuBarSpaceInfo: SpaceInfo? {
        guard
            let topology = snapshot?.menuBarTopology,
            let projected = projectedTopology(for: topology.managedDisplayID)
        else {
            return nil
        }
        return SpaceInfo(
            currentIndex: projected.currentIndex,
            spaceCount: projected.spaceIDs.count
        )
    }

    func actionContext(
        for physicalDisplayID: DisplayID,
        configuration: SpaceSwitchConfiguration
    ) -> SpaceActionContext? {
        guard
            let managedDisplayID = snapshot?.managedDisplayID(for: physicalDisplayID),
            let topology = projectedTopology(for: managedDisplayID)
        else {
            return nil
        }
        return SpaceActionContext(
            targetDisplayID: physicalDisplayID,
            topology: topology,
            lastSpaceID: lastSpaceByManagedDisplay[managedDisplayID],
            configuration: configuration
        )
    }
}

@MainActor
@Observable
final class SpaceSwitcher {
    nonisolated let missionControlSyntheticCapability: MissionControlSyntheticCapability

    private(set) var presentation = SpacePresentation(
        snapshot: nil,
        projectedSpaceByManagedDisplay: [:],
        lastSpaceByManagedDisplay: [:]
    )

    var spaceInfo: SpaceInfo? {
        presentation.menuBarSpaceInfo
    }

    @ObservationIgnored
    private let displayLocator = DisplayLocator()

    @ObservationIgnored
    private lazy var overlayDetector = CoreGraphicsOverlayDetector(
        displayLocator: displayLocator
    )

    @ObservationIgnored
    private lazy var engine = SpaceSwitchEngine(
        dependencies: .init(
            system: CGSSpaceSystemClient(),
            displays: displayLocator,
            overlays: overlayDetector,
            poster: DockGesturePoster(),
            missionControlCapability: missionControlSyntheticCapability,
            diagnose: { category, message in
                Logger.spaceSwitcherTiming.info("[\(category)] \(message)")
                DiagnosticsStore.shared.record(category, message)
            }
        )
    )

    @ObservationIgnored
    private var observers: [NSObjectProtocol] = []

    @ObservationIgnored
    private var presentationConsumer: Task<Void, Never>?

    @ObservationIgnored
    private var configurationProvider: @MainActor () -> SpaceSwitchConfiguration = {
        .defaultValue
    }

    init(
        missionControlSyntheticCapability: MissionControlSyntheticCapability = .init()
    ) {
        self.missionControlSyntheticCapability = missionControlSyntheticCapability
        observeWorkspace()
        let engine = self.engine
        presentationConsumer = Task { @MainActor [weak self] in
            await engine.start()
            for await presentation in engine.presentations {
                guard !Task.isCancelled else { break }
                self?.presentation = presentation
            }
        }
    }

    func setConfigurationProvider(
        _ provider: @escaping @MainActor () -> SpaceSwitchConfiguration
    ) {
        configurationProvider = provider
    }

    deinit {
        MainActor.assumeIsolated {
            removeObservers()
            presentationConsumer?.cancel()
            let engine = engine
            Task {
                await engine.stop()
            }
        }
    }

    func makeRequest(
        action: SpaceSwitchAction,
        source: SpaceInputSource
    ) -> SpaceSwitchRequest? {
        guard let targetDisplayID = try? displayLocator.cursorDisplayID() else {
            return nil
        }
        let configuration = configurationProvider()

        return SpaceSwitchRequest(
            action: action,
            source: source,
            targetDisplayID: targetDisplayID,
            wraps: configuration.wraps,
            velocity: configuration.velocity
        )
    }

    func makeGestureRequest(
        action: SpaceSwitchAction,
        context: GestureSessionContext
    ) -> SpaceSwitchRequest? {
        guard context.isAuthoritativeBlinkContext else { return nil }
        let configuration = configurationProvider()
        return SpaceSwitchRequest(
            action: action,
            source: .gesture,
            targetDisplayID: context.targetDisplayID,
            wraps: configuration.wraps,
            velocity: configuration.velocity,
            requiredMode: context.requiredPostingMode
        )
    }

    func submit(_ request: SpaceSwitchRequest) async -> SpaceSwitchOutcome {
        await engine.submit(request)
    }

    func shutdown() async {
        removeObservers()
        await engine.stop()
        presentationConsumer?.cancel()
        await presentationConsumer?.value
        presentationConsumer = nil
    }

    func captureMenuActionContext() -> SpaceActionContext? {
        guard let displayID = actionDisplayID() else { return nil }
        let configuration = configurationProvider()
        return presentation.actionContext(
            for: displayID,
            configuration: configuration
        )
    }

    private func actionDisplayID() -> DisplayID? {
        (try? displayLocator.cursorDisplayID())
            ?? presentation.snapshot?.menuBarDisplayID
    }

    private func removeObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let defaultCenter = NotificationCenter.default
        for observer in observers {
            workspaceCenter.removeObserver(observer)
            defaultCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func observeWorkspace() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let defaultCenter = NotificationCenter.default

        observers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                let message = "active-space notification uptime="
                    + "\(ProcessInfo.processInfo.systemUptime)"
                Logger.spaceSwitcherTiming.info(message)
                DiagnosticsStore.shared.record("switch-timing", message)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.engine.refresh(reason: .activeSpaceChanged)
                }
            }
        )

        for name in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            observers.append(
                workspaceCenter.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.engine.refresh(reason: .passive)
                    }
                }
            )
        }

        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didChangeScreenNotification,
            NSApplication.didChangeScreenParametersNotification,
        ] {
            observers.append(
                defaultCenter.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.engine.refresh(reason: .passive)
                    }
                }
            )
        }
    }
}

extension Logger {
    nonisolated fileprivate static let spaceSwitcherTiming = Logger(category: "SwitchTiming")
}
