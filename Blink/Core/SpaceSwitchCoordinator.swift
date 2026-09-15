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
        let observeTopologies: @MainActor () -> [String: Topology]?
        let postStep:
            @MainActor (
                _ gestureMode: GestureMode,
                _ direction: Direction,
                _ velocity: Double
            ) -> GestureSubmission
        let sleep: @MainActor (_ duration: Duration) async throws -> Void
        var confirmationSleep: @MainActor () async throws -> Void = {
            try await Task.sleep(for: .seconds(3))
        }
    }

    private struct Command {
        var revision = UUID()
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

    @ObservationIgnored
    private var confirmationTasks: [String: Task<Void, Never>] = [:]

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    // MARK: - Queries

    /// A read-only view of the same transaction used to plan switches. Presentation
    /// never owns a second prediction or deadline, and cannot outlive a command.
    struct Presentation: Equatable {
        let observedSpaceID: UInt64
        let pendingSpaceID: UInt64?
        let revision: UUID?
        let selectedIndex: Int?
    }

    func presentation(in topology: Topology) -> Presentation {
        let command = matchingState(for: topology)?.command
        return Presentation(
            observedSpaceID: topology.currentSpaceID,
            pendingSpaceID: command?.desiredSpaceID,
            revision: command?.revision,
            selectedIndex: topology.index(of: command?.desiredSpaceID ?? topology.currentSpaceID)
        )
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

        if let command = initialState.command,
            command.gestureMode != context.gestureMode
        {
            cancelCommand(for: displayIdentifier)
            return false
        }

        guard targetSpaceID != planningSpaceID else {
            return true
        }

        acquirePostingLease(for: displayIdentifier)
        confirmationTasks.removeValue(forKey: displayIdentifier)?.cancel()

        guard var state = matchingState(for: topology) else {
            return false
        }

        var command: Command

        if let existingCommand = state.command {
            command = existingCommand
            command.revision = UUID()
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
            finishCommand(in: &state, for: displayIdentifier, outcome: .confirmed)
            displayStates[displayIdentifier] = state
            return true
        }

        displayStates[displayIdentifier] = state

        if command.projectedSpaceID != command.desiredSpaceID {
            startWorker(for: displayIdentifier)
        } else {
            scheduleConfirmation(for: displayIdentifier)
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
            confirmationTasks.removeValue(forKey: displayIdentifier)?.cancel()
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
                confirmationTasks.removeValue(forKey: displayIdentifier)?.cancel()
                cancelPostingIfNeeded(for: displayIdentifier)
                state.spaceIDs = topology.spaceIDs
                state.confirmedSpaceID = topology.currentSpaceID
                finishCommand(in: &state, for: displayIdentifier, outcome: .topologyChanged)

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
                    finishCommand(in: &state, for: displayIdentifier, outcome: .confirmed)
                } else if command.postedSpaceIDs.contains(topology.currentSpaceID) {
                    // This is either the origin still being reported because CGS
                    // lags, or an intermediate Space posted by this command.
                    state.confirmedSpaceID = topology.currentSpaceID
                } else if reason.resolvesConflicts {
                    // A fresh authoritative observation landed somewhere Blink
                    // did not post. Treat is as external activity.
                    cancelPostingIfNeeded(for: displayIdentifier)
                    state.confirmedSpaceID = topology.currentSpaceID
                    finishCommand(in: &state, for: displayIdentifier, outcome: .externalMovement)

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
            if state.command == nil {
                confirmationTasks.removeValue(forKey: displayIdentifier)?.cancel()
            }
            displayStates[displayIdentifier] = state
        }
    }

    func cancelAll() {
        invalidateWorker()
        for task in confirmationTasks.values {
            task.cancel()
        }
        confirmationTasks.removeAll()
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

                guard case .submitted =
                    dependencies.postStep(
                        latestCommand.gestureMode,
                        currentDirection,
                        velocity
                    )
                else {
                    abortCommand(
                        for: displayIdentifier,
                        generation: generation,
                        outcome: .unavailable
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

    private enum CommandOutcome: String {
        case confirmed, interrupted, unavailable, expired, observationUnavailable
        case externalMovement, topologyChanged
    }

    private func finishCommand(
        in state: inout DisplayState,
        for displayIdentifier: String,
        outcome: CommandOutcome
    ) {
        confirmationTasks.removeValue(forKey: displayIdentifier)?.cancel()
        cancelPostingIfNeeded(for: displayIdentifier)
        guard let command = state.command else {
            return
        }

        // Partial completion is real movement too. Never record an unobserved
        // requested destination as history.
        if state.confirmedSpaceID != command.originSpaceID,
            state.spaceIDs.contains(command.originSpaceID)
        {
            state.lastSpaceID = command.originSpaceID
        }

        state.command = nil
        Logger.spaceSwitchCoordinator.debug(
            "Command \(command.revision): \(outcome.rawValue), display=\(displayIdentifier), target=\(command.desiredSpaceID), observed=\(state.confirmedSpaceID), postedDestinations=\(command.postedSpaceIDs.count - 1)"
        )
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

        cancelCommand(for: activeDisplayIdentifier)
    }

    private func cancelCommand(for displayIdentifier: String) {
        confirmationTasks.removeValue(forKey: displayIdentifier)?.cancel()
        cancelPostingIfNeeded(for: displayIdentifier)

        guard var state = displayStates[displayIdentifier] else {
            return
        }

        finishCommand(in: &state, for: displayIdentifier, outcome: .interrupted)
        displayStates[displayIdentifier] = state
        refreshAfterInterruption()
    }

    private func refreshAfterInterruption() {
        // Cancellation cannot undo already-posted Dock events. Read the system
        // after releasing the abandoned prediction, without retrying gestures.
        guard let topologies = dependencies.observeTopologies() else { return }
        reconcile(topologies: topologies, reason: .activeSpaceChanged)
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
        scheduleConfirmation(for: displayIdentifier)
    }

    private func scheduleConfirmation(for displayIdentifier: String) {
        confirmationTasks.removeValue(forKey: displayIdentifier)?.cancel()
        guard
            let command = displayStates[displayIdentifier]?.command,
            command.projectedSpaceID == command.desiredSpaceID
        else { return }
        let revision = command.revision
        let sleep = dependencies.confirmationSleep
        confirmationTasks[displayIdentifier] = Task { @MainActor [weak self] in
            do {
                try await sleep()
            } catch {
                return
            }
            guard
                !Task.isCancelled, let self,
                var state = self.displayStates[displayIdentifier],
                let pending = state.command,
                pending.revision == revision
            else { return }
            self.confirmationTasks.removeValue(forKey: displayIdentifier)
            guard let topologies = self.dependencies.observeTopologies() else {
                // Missing observations must not leave an unconfirmed command active.
                self.finishCommand(in: &state, for: displayIdentifier, outcome: .observationUnavailable)
                self.displayStates[displayIdentifier] = state
                return
            }
            self.reconcile(topologies: topologies, reason: .activeSpaceChanged)
            guard
                var remaining = self.displayStates[displayIdentifier],
                remaining.command?.revision == revision
            else { return }
            self.finishCommand(in: &remaining, for: displayIdentifier, outcome: .expired)
            self.displayStates[displayIdentifier] = remaining
        }
    }

    private func abortCommand(
        for displayIdentifier: String,
        generation: UInt64,
        outcome: CommandOutcome = .interrupted
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

        finishCommand(in: &state, for: displayIdentifier, outcome: outcome)
        displayStates[displayIdentifier] = state
        refreshAfterInterruption()
    }

}

// MARK: - Logger

extension Logger {
    fileprivate static let spaceSwitchCoordinator = Logger(category: "SpaceSwitchCoordinator")
}
