import AppKit
import Foundation
import Observation

nonisolated struct SpaceInfo: Equatable, Sendable {
    let currentIndex: Int
    let spaceCount: Int
    let spaceIDs: [UInt64]

    var displayNumber: Int { currentIndex + 1 }
    var isAtLeftEdge: Bool { currentIndex == 0 }
    var isAtRightEdge: Bool { currentIndex + 1 >= spaceCount }

    let currentSpaceID: UInt64?
    let currentSpaceType: Int?
    let displayIdentifier: String?
    let frontmostBundleID: String?

    var isNormalDesktopSpace: Bool { currentSpaceType == 0 }
    var isFullscreenSpace: Bool { currentSpaceType == 2 }
    var isKnownStandardSpace: Bool { isNormalDesktopSpace || isFullscreenSpace }

    func index(ofSpaceID spaceID: UInt64) -> Int? {
        spaceIDs.firstIndex(of: spaceID)
    }
}

@MainActor
@Observable
final class SpaceSwitcher {
    var onMissionControlFailure: (() -> Void)?

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
            spaceCount: projected.spaceIDs.count,
            spaceIDs: projected.spaceIDs.map(\.rawValue),
            currentSpaceID: topology.currentSpaceID.rawValue,
            currentSpaceType: topology.currentSpaceKind == .unknown
                ? nil
                : topology.currentSpaceKind.rawValue,
            displayIdentifier: topology.displayID.rawValue,
            frontmostBundleID: snapshot.frontmostBundleID
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
            missionControlDidFail: { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    self?.onMissionControlFailure?()
                }
            },
            publish: { [weak self] presentation in
                Task { @MainActor [weak self] in
                    self?.presentation = presentation
                }
            }
        )
    )

    @ObservationIgnored
    private var observers: [NSObjectProtocol] = []

    private var wraps = false
    private var velocity = 999_999.0

    init() {
        observeWorkspace()
        Task { [engine] in
            await engine.start()
        }
    }

    func applyConfiguration(wraps: Bool, velocity: Double) {
        self.wraps = wraps
        self.velocity = max(1, velocity)
    }

    deinit {
        MainActor.assumeIsolated {
            removeObservers()
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

    func submit(_ request: SpaceSwitchRequest) async -> SpaceSwitchOutcome {
        await engine.submit(request)
    }

    func shutdown() async {
        removeObservers()
        await engine.stop()
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

    func refreshSpaceInfo() {
        Task { [engine] in
            await engine.refresh(reason: .passive)
        }
    }

    func isMissionControlActive() -> Bool {
        currentOverlayMode() == .missionControl
    }

    func isAppExposeActive() -> Bool {
        currentOverlayMode() == .appExpose
    }

    func currentOverlayMode() -> OverlayMode {
        guard let displayID = actionDisplayID() else { return .unknown }
        return overlayDetector.detect(on: displayID)
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
