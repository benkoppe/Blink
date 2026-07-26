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

@MainActor
@Observable
final class SpaceSwitcher {
    nonisolated let missionControlSyntheticCapability: MissionControlSyntheticCapability

    private(set) var presentation = SpacePresentation(
        snapshot: nil,
        projectedSpaceByDisplay: [:],
        lastSpaceByDisplay: [:]
    )

    var spaceInfo: SpaceInfo? {
        guard
            let snapshot = presentation.snapshot,
            let topology = snapshot.menuBarTopology,
            let projected = presentation.projectedTopology(for: topology.displayID)
        else {
            return nil
        }

        return SpaceInfo(
            currentIndex: projected.currentIndex,
            spaceCount: projected.spaceIDs.count
        )
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

    private var wraps = false
    private var velocity = 999_999.0

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

    func applyConfiguration(wraps: Bool, velocity: Double) {
        self.wraps = wraps
        self.velocity = max(1, velocity)
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

        return SpaceSwitchRequest(
            action: action,
            source: source,
            targetDisplayID: targetDisplayID,
            wraps: wraps,
            velocity: velocity
        )
    }

    func makeGestureRequest(
        action: SpaceSwitchAction,
        context: GestureSessionContext
    ) -> SpaceSwitchRequest? {
        guard context.isAuthoritativeBlinkContext else { return nil }
        return SpaceSwitchRequest(
            action: action,
            source: .gesture,
            targetDisplayID: context.targetDisplayID,
            wraps: wraps,
            velocity: velocity,
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

    func canMoveLeft() -> Bool {
        canSubmit(.step(.left))
    }

    func canMoveRight() -> Bool {
        canSubmit(.step(.right))
    }

    func canSwitchToLastSpace() -> Bool {
        guard
            let displayID = actionDisplayID(),
            let topology = presentation.projectedTopology(for: displayID),
            let lastSpaceID = presentation.lastSpaceByDisplay[displayID]
        else {
            return false
        }

        return topology.spaceIDs.contains(lastSpaceID)
            && topology.currentSpaceID != lastSpaceID
    }

    private func canSubmit(_ action: SpaceSwitchAction) -> Bool {
        guard
            let displayID = actionDisplayID(),
            let topology = presentation.projectedTopology(for: displayID)
        else {
            return false
        }

        switch action {
        case .step(.left):
            return topology.spaceIDs.count > 1 && (wraps || topology.currentIndex > 0)
        case .step(.right):
            return topology.spaceIDs.count > 1
                && (wraps || topology.currentIndex + 1 < topology.spaceIDs.count)
        case .index(let index):
            return topology.spaceIDs.indices.contains(index)
        case .lastSpace:
            return canSwitchToLastSpace()
        }
    }

    private func actionDisplayID() -> DisplayID? {
        (try? displayLocator.cursorDisplayID())
            ?? presentation.snapshot?.menuBarDisplayID
            ?? presentation.snapshot?.menuBarTopology?.displayID
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
