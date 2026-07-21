//
//  SpaceSwitchCoordinator.swift
//  Blink
//

import Foundation
import Observation

@MainActor
@Observable
final class SpaceSwitchCoordinator {
    nonisolated enum Direction: Equatable, Sendable {
        case left
        case right
    }

    nonisolated enum GestureMode: Equatable, Sendable {
        case instant
        case missionControl
    }

    nonisolated enum ReconciliationReason: Sendable {
        case commandSubmission
        case activeSpaceChanged
        case passiveRefresh

        fileprivate var resolvesConflicts: Bool {
            switch self {
            case .commandSubmission, .activeSpaceChanged:
                true
            case .passiveRefresh:
                false
            }
        }
    }

    nonisolated struct Topology: Equatable, Sendable {
        let displayIdentifier: String
        let spaceIDs: [UInt64]
        let currentSpaceID: UInt64

        init?(
            displayIdentifier: String,
            spaceIDs: [UInt64],
            currentSpaceID: UInt64
        ) {
            guard
                !displayIdentifier.isEmpty,
                !spaceIDs.isEmpty,
                Set(spaceIDs).count == spaceIDs.count,
                spaceIDs.contains(currentSpaceID)
            else {
                return nil
            }

            self.displayIdentifier = displayIdentifier
            self.spaceIDs = spaceIDs
            self.currentSpaceID = currentSpaceID
        }

        func index(of spaceID: UInt64) -> Int? {
            spaceIDs.firstIndex(of: spaceID)
        }
    }

    nonisolated struct Context: Equatable, Sendable {
        let topology: Topology
        let gestureMode: GestureMode
    }

    struct Dependencies {
        let loadContext: @MainActor (_ displayIdentifier: String) -> Context?
        let postStep:
            @MainActor (
                _ gestureMode: GestureMode,
                _ direction: Direction,
                _ velocity: Double
            ) -> Bool
        let sleep: @MainActor (_ duration: Duration) async throws -> Void
    }

    private struct Command {
        let originSpaceID: UInt64
        var desiredSpaceID: UInt64
        var projectedSpaceID: UInt64
        var postedSpaceIDs: Set<UInt64>
        let gestureMode: GestureMode
        var baseVelocity: Double
    }

    private struct DisplayState {
        var spaceIDs: [UInt64]
        var confirmedSpaceID: UInt64
        var lastSpaceID: UInt64?
        var command: Command?
    }

    private static let instantBatchSize = 4
    private static let instantBatchInterval: Duration = .milliseconds(40)
    private static let missionControlStepInterval: Duration = .milliseconds(10)

    @ObservationIgnored
    private let dependencies: Dependencies

    private var displayStates: [String: DisplayState] = [:]

    // Synthetic Dock gestures are global and not display-addressed. Only one
    // display may therefore own the posting worker at a time.
    @ObservationIgnored
    private var worker: Task<Void, Never>?

    @ObservationIgnored
    private var workerDisplayIdentifier: String?

    @ObservationIgnored
    private var workerGeneration: UInt64 = 0

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    // MARK: - Queries

    func projectedIndex(for topology: Topology) -> Int? {
        guard
            let state = matchingState(for: topology),
            let projectedSpaceID = state.command?.projectedSpaceID
        else {
            return topology.index(of: topology.currentSpaceID)
        }

        return topology.index(of: projectedSpaceID)
    }

    func desiredIndex(for topology: Topology) -> Int? {
        guard let state = matchingState(for: topology) else {
            return topology.index(of: topology.currentSpaceID)
        }

        let desiredSpaceID = state.command?.desiredSpaceID ?? state.confirmedSpaceID

        return topology.index(of: desiredSpaceID)
    }

    func lastSpaceID(for topology: Topology) -> UInt64? {
        guard
            let state = matchingState(for: topology),
            let lastSpaceID = state.lastSpaceID,
            topology.spaceIDs.contains(lastSpaceID)
        else {
            return nil
        }

        let desiredSpaceID = state.command?.desiredSpaceID ?? state.confirmedSpaceID

        guard lastSpaceID != desiredSpaceID else {
            return nil
        }

        return lastSpaceID
    }

    func canMove(
        _ direction: Direction,
        in topology: Topology,
        wrap: Bool
    ) -> Bool {
        guard
            topology.spaceIDs.count > 1,
            let currentIndex = desiredIndex(for: topology)
        else {
            return false
        }

        if wrap {
            return true
        }

        switch direction {
        case .left:
            return currentIndex > 0
        case .right:
            return currentIndex + 1 < topology.spaceIDs.count
        }
    }

    func hasActiveCommand(for displayIdentifier: String) -> Bool {
        displayStates[displayIdentifier]?.command != nil
    }

    func projectedSpaceID(for displayIdentifier: String) -> UInt64? {
        guard let state = displayStates[displayIdentifier] else {
            return nil
        }

        return state.command?.projectedSpaceID
            ?? state.confirmedSpaceID
    }

    func desiredSpaceID(for displayIdentifier: String) -> UInt64? {
        guard let state = displayStates[displayIdentifier] else {
            return nil
        }

        return state.command?.desiredSpaceID
            ?? state.confirmedSpaceID
    }

    // MARK: - Requests

    @discardableResult
    func submitStep(
        _ direction: Direction,
        context: Context,
        wrap: Bool,
        baseVelocity: Double
    ) -> Bool {
        let topology = context.topology

        guard
            let state = matchingState(for: topology),
            topology.spaceIDs.count > 1
        else {
            return false
        }

        let planningSpaceID = state.command?.desiredSpaceID ?? state.confirmedSpaceID

        guard
            let currentIndex = topology.index(of: planningSpaceID)
        else {
            return false
        }

        let targetIndex: Int

        switch direction {
        case .left:
            if currentIndex > 0 {
                targetIndex = currentIndex - 1
            } else {
                guard wrap else { return false }

                targetIndex = topology.spaceIDs.count - 1
            }
        case .right:
            if currentIndex + 1 < topology.spaceIDs.count {
                targetIndex = currentIndex + 1
            } else {
                guard wrap else { return false }

                targetIndex = 0
            }
        }

        return submitTarget(
            topology.spaceIDs[targetIndex],
            context: context,
            baseVelocity: baseVelocity
        )
    }

    @discardableResult
    func submitTarget(
        _ targetSpaceID: UInt64,
        context: Context,
        baseVelocity: Double
    ) -> Bool {
        let topology = context.topology
        let displayIdentifier = topology.displayIdentifier

        guard
            topology.spaceIDs.contains(targetSpaceID),
            let initialState = matchingState(for: topology)
        else {
            return false
        }

        let planningSpaceID =
            initialState.command?.desiredSpaceID
            ?? initialState.confirmedSpaceID

        guard targetSpaceID != planningSpaceID else {
            return true
        }

        if let command = initialState.command,
            command.gestureMode != context.gestureMode
        {
            cancelCommand(for: displayIdentifier)
            return false
        }

        acquirePostingLease(for: displayIdentifier)

        guard var state = matchingState(for: topology) else {
            return false
        }

        var command: Command

        if let existingCommand = state.command {
            command = existingCommand
            command.desiredSpaceID = targetSpaceID
            command.baseVelocity = max(1, baseVelocity)
        } else {
            guard targetSpaceID != state.confirmedSpaceID else {
                return true
            }

            command = Command(
                originSpaceID: state.confirmedSpaceID,
                desiredSpaceID: targetSpaceID,
                projectedSpaceID: state.confirmedSpaceID,
                postedSpaceIDs: [state.confirmedSpaceID],
                gestureMode: context.gestureMode,
                baseVelocity: max(1, baseVelocity)
            )
        }

        state.command = command

        if command.projectedSpaceID == command.desiredSpaceID,
            state.confirmedSpaceID == command.desiredSpaceID
        {
            settleCommand(in: &state)
            displayStates[displayIdentifier] = state
            return true
        }

        displayStates[displayIdentifier] = state

        if command.projectedSpaceID != command.desiredSpaceID {
            startWorker(for: displayIdentifier)
        }

        return true
    }

    // MARK - Reconciliation

    func reconcile(
        topologies: [String: Topology],
        reason: ReconciliationReason
    ) {
        let removedDisplayIdentifiers = Set(displayStates.keys).subtracting(topologies.keys)

        for displayIdentifier in removedDisplayIdentifiers {
            cancelPostingIfNeeded(for: displayIdentifier)
            displayStates.removeValue(forKey: displayIdentifier)
        }

        for (displayIdentifier, topology) in topologies {
            guard var state = displayStates[displayIdentifier] else {
                displayStates[displayIdentifier] = DisplayState(
                    spaceIDs: topology.spaceIDs,
                    confirmedSpaceID: topology.currentSpaceID,
                    lastSpaceID: nil,
                    command: nil
                )
                continue
            }

            let previousConfirmedSpaceID = state.confirmedSpaceID

            guard state.spaceIDs == topology.spaceIDs else {
                cancelPostingIfNeeded(for: displayIdentifier)
                state.command = nil
                state.spaceIDs = topology.spaceIDs
                state.confirmedSpaceID = topology.currentSpaceID

                if previousConfirmedSpaceID != topology.currentSpaceID,
                    topology.spaceIDs.contains(previousConfirmedSpaceID)
                {
                    state.lastSpaceID = previousConfirmedSpaceID
                }

                pruneHistory(in: &state)
                displayStates[displayIdentifier] = state
                continue
            }

            if let command = state.command {
                if topology.currentSpaceID == command.desiredSpaceID {
                    cancelPostingIfNeeded(for: displayIdentifier)
                    state.confirmedSpaceID = topology.currentSpaceID
                    settleCommand(in: &state)
                } else if command.postedSpaceIDs.contains(topology.currentSpaceID) {
                    // This is either the origin still being reported because CGS
                    // lags, or an intermediate Space posted by this command.
                    state.confirmedSpaceID = topology.currentSpaceID
                } else if reason.resolvesConflicts {
                    // A fresh authoritative observation landed somewhere Blink
                    // did not post. Treat is as external activity.
                    cancelPostingIfNeeded(for: displayIdentifier)
                    state.command = nil
                    state.confirmedSpaceID = topology.currentSpaceID

                    if previousConfirmedSpaceID != topology.currentSpaceID,
                        topology.spaceIDs.contains(previousConfirmedSpaceID)
                    {
                        state.lastSpaceID = previousConfirmedSpaceID
                    }
                }
            } else if previousConfirmedSpaceID != topology.currentSpaceID {
                state.confirmedSpaceID = topology.currentSpaceID

                if topology.spaceIDs.contains(previousConfirmedSpaceID) {
                    state.lastSpaceID = previousConfirmedSpaceID
                }
            }

            pruneHistory(in: &state)
            displayStates[displayIdentifier] = state
        }
    }

    func cancelAll() {
        invalidateWorker()
        displayStates.removeAll()
    }

    // MARK: - Worker

    private func startWorker(for displayIdentifier: String) {
        guard
            worker == nil,
            let state = displayStates[displayIdentifier],
            let command = state.command,
            command.projectedSpaceID != command.desiredSpaceID
        else {
            return
        }

        workerGeneration &+= 1
        let generation = workerGeneration
        workerDisplayIdentifier = displayIdentifier

        worker = Task { @MainActor [weak self] in
            guard let self else { return }

            await self.runWorker(
                for: displayIdentifier,
                generation: generation
            )
        }
    }

    private func runWorker(
        for displayIdentifier: String,
        generation: UInt64
    ) async {
        while isCurrentWorker(
            for: displayIdentifier,
            generation: generation
        ) {
            guard
                let state = displayStates[displayIdentifier],
                let command = state.command
            else {
                finishWorker(
                    for: displayIdentifier,
                    generation: generation
                )
                return
            }

            guard command.projectedSpaceID != command.desiredSpaceID else {
                finishWorker(
                    for: displayIdentifier,
                    generation: generation
                )
                return
            }

            guard
                let context = dependencies.loadContext(displayIdentifier),
                context.topology.displayIdentifier == displayIdentifier,
                context.topology.spaceIDs == state.spaceIDs,
                context.gestureMode == command.gestureMode
            else {
                abortCommand(
                    for: displayIdentifier,
                    generation: generation
                )
                return
            }

            guard
                let projectedIndex = state.spaceIDs.firstIndex(of: command.projectedSpaceID),
                let desiredIndex = state.spaceIDs.firstIndex(of: command.desiredSpaceID)
            else {
                abortCommand(
                    for: displayIdentifier,
                    generation: generation
                )
                return
            }

            let remainingSteps = abs(desiredIndex - projectedIndex)

            let batchSize: Int
            let interval: Duration

            switch command.gestureMode {
            case .instant:
                batchSize = min(Self.instantBatchSize, remainingSteps)
                interval = Self.instantBatchInterval
            case .missionControl:
                batchSize = 1
                interval = Self.missionControlStepInterval
            }

            let velocity = command.baseVelocity * Double(max(1, remainingSteps))

            for _ in 0..<batchSize {
                guard
                    isCurrentWorker(
                        for: displayIdentifier,
                        generation: generation
                    ),
                    let latestState = displayStates[displayIdentifier],
                    let latestCommand = latestState.command,
                    latestCommand.gestureMode == command.gestureMode,
                    let currentProjectedIndex = latestState.spaceIDs.firstIndex(
                        of: latestCommand.projectedSpaceID
                    ),
                    let currentDesiredIndex = latestState.spaceIDs.firstIndex(
                        of: latestCommand.desiredSpaceID
                    ),
                    currentProjectedIndex != currentDesiredIndex
                else {
                    return
                }

                let currentDirection: Direction =
                    currentDesiredIndex > currentProjectedIndex ? .right : .left

                let nextIndex = currentProjectedIndex + (currentDirection == .right ? 1 : -1)

                guard latestState.spaceIDs.indices.contains(nextIndex) else {
                    abortCommand(
                        for: displayIdentifier,
                        generation: generation
                    )
                    return
                }

                guard
                    dependencies.postStep(
                        latestCommand.gestureMode,
                        currentDirection,
                        velocity
                    )
                else {
                    abortCommand(
                        for: displayIdentifier,
                        generation: generation
                    )
                    return
                }

                guard
                    isCurrentWorker(
                        for: displayIdentifier,
                        generation: generation
                    ),
                    var updatedState = displayStates[displayIdentifier],
                    var updatedCommand = updatedState.command
                else {
                    return
                }

                let nextSpaceID = updatedState.spaceIDs[nextIndex]
                updatedCommand.projectedSpaceID = nextSpaceID
                updatedCommand.postedSpaceIDs.insert(nextSpaceID)
                updatedState.command = updatedCommand
                displayStates[displayIdentifier] = updatedState
            }

            guard
                isCurrentWorker(
                    for: displayIdentifier,
                    generation: generation
                ),
                let updatedCommand = displayStates[displayIdentifier]?.command
            else {
                return
            }

            if updatedCommand.projectedSpaceID == updatedCommand.desiredSpaceID {
                finishWorker(
                    for: displayIdentifier,
                    generation: generation
                )
                return
            }

            do {
                try await dependencies.sleep(interval)
            } catch {
                if isCurrentWorker(
                    for: displayIdentifier,
                    generation: generation
                ) {
                    abortCommand(
                        for: displayIdentifier,
                        generation: generation
                    )
                }
                return
            }

            guard
                isCurrentWorker(
                    for: displayIdentifier,
                    generation: generation
                )
            else {
                return
            }
        }
    }

    // MARK: - State Management

    private func matchingState(for topology: Topology) -> DisplayState? {
        guard
            let state = displayStates[topology.displayIdentifier],
            state.spaceIDs == topology.spaceIDs
        else {
            return nil
        }

        return state
    }

    private func settleCommand(in state: inout DisplayState) {
        guard let command = state.command else {
            return
        }

        if command.desiredSpaceID != command.originSpaceID,
            state.spaceIDs.contains(command.originSpaceID)
        {
            state.lastSpaceID = command.originSpaceID
        }

        state.command = nil
    }

    private func pruneHistory(in state: inout DisplayState) {
        guard let lastSpaceID = state.lastSpaceID else {
            return
        }

        if !state.spaceIDs.contains(lastSpaceID)
            || lastSpaceID == state.confirmedSpaceID
        {
            state.lastSpaceID = nil
        }
    }

    private func acquirePostingLease(for displayIdentifier: String) {
        guard let activeDisplayIdentifier = workerDisplayIdentifier else {
            return
        }

        invalidateWorker()

        guard activeDisplayIdentifier != displayIdentifier else {
            return
        }

        if var activeState = displayStates[activeDisplayIdentifier] {
            activeState.command = nil
            displayStates[activeDisplayIdentifier] = activeState
        }
    }

    private func cancelCommand(for displayIdentifier: String) {
        cancelPostingIfNeeded(for: displayIdentifier)

        guard var state = displayStates[displayIdentifier] else {
            return
        }

        state.command = nil
        displayStates[displayIdentifier] = state
    }

    private func cancelPostingIfNeeded(for displayIdentifier: String) {
        guard workerDisplayIdentifier == displayIdentifier else {
            return
        }

        invalidateWorker()
    }

    private func invalidateWorker() {
        workerGeneration &+= 1
        worker?.cancel()
        worker = nil
        workerDisplayIdentifier = nil
    }

    private func isCurrentWorker(
        for displayIdentifier: String,
        generation: UInt64
    ) -> Bool {
        !Task.isCancelled
            && workerGeneration == generation
            && workerDisplayIdentifier == displayIdentifier
    }

    private func finishWorker(for displayIdentifier: String, generation: UInt64) {
        guard
            workerGeneration == generation,
            workerDisplayIdentifier == displayIdentifier
        else {
            return
        }

        worker = nil
        workerDisplayIdentifier = nil
    }

    private func abortCommand(
        for displayIdentifier: String,
        generation: UInt64
    ) {
        guard
            workerGeneration == generation,
            workerDisplayIdentifier == displayIdentifier
        else {
            return
        }

        invalidateWorker()

        guard var state = displayStates[displayIdentifier] else {
            return
        }

        state.command = nil
        displayStates[displayIdentifier] = state
    }

}
