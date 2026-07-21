import Foundation

actor SpaceSwitchEngine {
    nonisolated enum ReconciliationReason: Sendable {
        case request
        case activeSpaceChanged
        case passive

        var resolvesConflicts: Bool {
            self != .passive
        }
    }

    nonisolated struct Dependencies: Sendable {
        let system: any SpaceSystemClient
        let displays: any DisplayLocating
        let overlays: any OverlayDetecting
        let poster: any SpaceGesturePosting
        let sleep: @Sendable (Duration) async throws -> Void
        let diagnose: @Sendable (String, String) -> Void
        let publish: @Sendable (SpacePresentation) -> Void

        init(
            system: any SpaceSystemClient,
            displays: any DisplayLocating,
            overlays: any OverlayDetecting,
            poster: any SpaceGesturePosting,
            sleep: @escaping @Sendable (Duration) async throws -> Void = {
                try await Task<Never, Never>.sleep(for: $0)
            },
            diagnose: @escaping @Sendable (String, String) -> Void = { _, _ in },
            publish: @escaping @Sendable (SpacePresentation) -> Void
        ) {
            self.system = system
            self.displays = displays
            self.overlays = overlays
            self.poster = poster
            self.sleep = sleep
            self.diagnose = diagnose
            self.publish = publish
        }
    }

    private struct Transaction {
        let originSpaceID: SpaceID
        var desiredSpaceID: SpaceID
        var projectedSpaceID: SpaceID
        var postedSpaceIDs: Set<SpaceID>
        let mode: SpaceSwitchMode
        var velocity: Double
    }

    private struct DisplayState {
        var topology: DisplayTopology
        var confirmedSpaceID: SpaceID
        var lastSpaceID: SpaceID?
        var transaction: Transaction?
    }

    private static let instantBatchSize = 4
    private static let instantBatchInterval: Duration = .milliseconds(40)
    private static let missionControlStepInterval: Duration = .milliseconds(10)
    private static let acknowledgementTimeout: Duration = .seconds(2)

    private let dependencies: Dependencies
    private var snapshot: SystemSpaceSnapshot?
    private var displayStates: [DisplayID: DisplayState] = [:]
    private var worker: Task<Void, Never>?
    private var workerDisplayID: DisplayID?
    private var transactionDisplayID: DisplayID?
    private var workerGeneration: UInt64 = 0
    private var acknowledgementTask: Task<Void, Never>?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func start() {
        refresh(reason: .passive)
    }

    func stop() {
        invalidateWorker()
        acknowledgementTask?.cancel()
        acknowledgementTask = nil
        transactionDisplayID = nil
        snapshot = nil
        displayStates.removeAll()
        publish()
    }

    @discardableResult
    func submit(
        action: SpaceSwitchAction,
        source: SpaceInputSource,
        wraps: Bool,
        velocity: Double
    ) -> SpaceSwitchOutcome {
        guard
            let freshSnapshot = loadSnapshot(reason: .request),
            let displayID = try? dependencies.displays.cursorDisplayID(),
            let topology = freshSnapshot.topologiesByDisplay[displayID]
        else {
            return .unavailable
        }

        let request = SpaceSwitchRequest(
            action: action,
            source: source,
            targetDisplayID: displayID,
            wraps: wraps,
            velocity: max(1, velocity)
        )

        return submit(request, topology: topology)
    }

    func refresh(reason: ReconciliationReason) {
        _ = loadSnapshot(reason: reason)
    }

    func presentation() -> SpacePresentation {
        makePresentation()
    }

    private func submit(
        _ request: SpaceSwitchRequest,
        topology: DisplayTopology
    ) -> SpaceSwitchOutcome {
        guard var state = matchingState(for: topology) else {
            return .unavailable
        }

        let planningSpaceID =
            state.transaction?.desiredSpaceID
            ?? state.confirmedSpaceID

        guard let planningIndex = topology.index(of: planningSpaceID) else {
            return .unavailable
        }

        let targetSpaceID: SpaceID

        switch request.action {
        case .step(let direction):
            switch direction {
            case .left:
                if planningIndex > 0 {
                    targetSpaceID = topology.spaceIDs[planningIndex - 1]
                } else if request.wraps {
                    targetSpaceID = topology.spaceIDs.last!
                } else {
                    return .blockedAtEdge
                }
            case .right:
                if planningIndex + 1 < topology.spaceIDs.count {
                    targetSpaceID = topology.spaceIDs[planningIndex + 1]
                } else if request.wraps {
                    targetSpaceID = topology.spaceIDs.first!
                } else {
                    return .blockedAtEdge
                }
            }
        case .index(let index):
            guard topology.spaceIDs.indices.contains(index) else {
                return .invalidTarget
            }
            targetSpaceID = topology.spaceIDs[index]
        case .lastSpace:
            guard
                let lastSpaceID = state.lastSpaceID,
                topology.spaceIDs.contains(lastSpaceID),
                lastSpaceID != planningSpaceID
            else {
                return .invalidTarget
            }
            targetSpaceID = lastSpaceID
        }

        guard targetSpaceID != planningSpaceID else {
            return .alreadyAtTarget
        }

        let mode = mode(for: topology.displayID)
        if let transaction = state.transaction,
            transaction.mode != mode
        {
            cancelTransaction(for: topology.displayID)
            return .unavailable
        }

        acquirePostingLease(for: topology.displayID)
        acknowledgementTask?.cancel()
        acknowledgementTask = nil

        if var transaction = state.transaction {
            transaction.desiredSpaceID = targetSpaceID
            transaction.velocity = request.velocity
            state.transaction = transaction
        } else {
            state.transaction = Transaction(
                originSpaceID: state.confirmedSpaceID,
                desiredSpaceID: targetSpaceID,
                projectedSpaceID: state.confirmedSpaceID,
                postedSpaceIDs: [state.confirmedSpaceID],
                mode: mode,
                velocity: request.velocity
            )
        }

        displayStates[topology.displayID] = state
        transactionDisplayID = topology.displayID
        dependencies.diagnose(
            "switch",
            "accepted source=\(request.source.rawValue) display=\(topology.displayID.rawValue) target=\(targetSpaceID.rawValue) mode=\(mode)"
        )
        publish()
        startWorker(for: topology.displayID)
        return .accepted
    }

    private func mode(for displayID: DisplayID) -> SpaceSwitchMode {
        dependencies.overlays.detect(on: displayID) == .missionControl
            ? .missionControl
            : .instant
    }

    @discardableResult
    private func loadSnapshot(
        reason: ReconciliationReason
    ) -> SystemSpaceSnapshot? {
        guard let value = try? dependencies.system.loadSnapshot() else {
            return nil
        }

        snapshot = value
        reconcile(snapshot: value, reason: reason)
        publish()
        return value
    }

    private func reconcile(
        snapshot: SystemSpaceSnapshot,
        reason: ReconciliationReason
    ) {
        let removed = Set(displayStates.keys).subtracting(snapshot.topologiesByDisplay.keys)
        for displayID in removed {
            cancelPostingIfNeeded(for: displayID)
            displayStates.removeValue(forKey: displayID)
        }

        for (displayID, topology) in snapshot.topologiesByDisplay {
            guard var state = displayStates[displayID] else {
                displayStates[displayID] = DisplayState(
                    topology: topology,
                    confirmedSpaceID: topology.currentSpaceID,
                    lastSpaceID: nil,
                    transaction: nil
                )
                continue
            }

            let previousConfirmed = state.confirmedSpaceID

            guard state.topology.spaceIDs == topology.spaceIDs else {
                cancelPostingIfNeeded(for: displayID)
                state.topology = topology
                state.confirmedSpaceID = topology.currentSpaceID
                state.transaction = nil
                if topology.spaceIDs.contains(previousConfirmed),
                    previousConfirmed != topology.currentSpaceID
                {
                    state.lastSpaceID = previousConfirmed
                }
                pruneHistory(in: &state)
                displayStates[displayID] = state
                continue
            }

            state.topology = topology

            if let transaction = state.transaction {
                if topology.currentSpaceID == transaction.desiredSpaceID {
                    state.confirmedSpaceID = topology.currentSpaceID
                    settleTransaction(in: &state)
                    acknowledgementTask?.cancel()
                    acknowledgementTask = nil
                    cancelPostingIfNeeded(for: displayID)
                    dependencies.diagnose(
                        "switch",
                        "acknowledged display=\(displayID.rawValue) space=\(topology.currentSpaceID.rawValue)"
                    )
                } else if transaction.postedSpaceIDs.contains(topology.currentSpaceID) {
                    state.confirmedSpaceID = topology.currentSpaceID
                } else if reason.resolvesConflicts {
                    cancelPostingIfNeeded(for: displayID)
                    state.transaction = nil
                    state.confirmedSpaceID = topology.currentSpaceID
                    if topology.spaceIDs.contains(previousConfirmed),
                        previousConfirmed != topology.currentSpaceID
                    {
                        state.lastSpaceID = previousConfirmed
                    }
                }
            } else if previousConfirmed != topology.currentSpaceID {
                state.confirmedSpaceID = topology.currentSpaceID
                if topology.spaceIDs.contains(previousConfirmed) {
                    state.lastSpaceID = previousConfirmed
                }
            }

            pruneHistory(in: &state)
            displayStates[displayID] = state
        }
    }

    private func startWorker(for displayID: DisplayID) {
        guard
            worker == nil,
            let transaction = displayStates[displayID]?.transaction,
            transaction.projectedSpaceID != transaction.desiredSpaceID
        else {
            return
        }

        workerGeneration &+= 1
        let generation = workerGeneration
        workerDisplayID = displayID
        worker = Task { [weak self] in
            await self?.runWorker(for: displayID, generation: generation)
        }
    }

    private func runWorker(
        for displayID: DisplayID,
        generation: UInt64
    ) async {
        while isCurrentWorker(for: displayID, generation: generation) {
            guard
                let state = displayStates[displayID],
                let transaction = state.transaction,
                transaction.projectedSpaceID != transaction.desiredSpaceID
            else {
                finishWorker(for: displayID, generation: generation)
                return
            }

            guard
                let cursorDisplayID = try? dependencies.displays.cursorDisplayID(),
                cursorDisplayID == displayID,
                let freshSnapshot = try? dependencies.system.loadSnapshot(),
                let freshTopology = freshSnapshot.topologiesByDisplay[displayID],
                freshTopology.spaceIDs == state.topology.spaceIDs,
                mode(for: displayID) == transaction.mode,
                let projectedIndex = state.topology.index(of: transaction.projectedSpaceID),
                let desiredIndex = state.topology.index(of: transaction.desiredSpaceID)
            else {
                abortTransaction(for: displayID, generation: generation)
                return
            }

            let remaining = abs(desiredIndex - projectedIndex)
            let batchSize = transaction.mode == .instant
                ? min(Self.instantBatchSize, remaining)
                : 1
            let interval = transaction.mode == .instant
                ? Self.instantBatchInterval
                : Self.missionControlStepInterval

            for _ in 0..<batchSize {
                guard
                    isCurrentWorker(for: displayID, generation: generation),
                    var updatedState = displayStates[displayID],
                    var updatedTransaction = updatedState.transaction,
                    let currentIndex = updatedState.topology.index(
                        of: updatedTransaction.projectedSpaceID
                    ),
                    let targetIndex = updatedState.topology.index(
                        of: updatedTransaction.desiredSpaceID
                    ),
                    currentIndex != targetIndex
                else {
                    return
                }

                let direction: SpaceSwitchDirection = targetIndex > currentIndex
                    ? .right
                    : .left
                let nextIndex = currentIndex + (direction == .right ? 1 : -1)
                guard updatedState.topology.spaceIDs.indices.contains(nextIndex) else {
                    abortTransaction(for: displayID, generation: generation)
                    return
                }

                let remainingSteps = abs(targetIndex - currentIndex)
                guard dependencies.poster.postStep(
                    mode: updatedTransaction.mode,
                    direction: direction,
                    velocity: updatedTransaction.velocity * Double(max(1, remainingSteps))
                ) else {
                    abortTransaction(for: displayID, generation: generation)
                    return
                }

                let nextSpaceID = updatedState.topology.spaceIDs[nextIndex]
                updatedTransaction.projectedSpaceID = nextSpaceID
                updatedTransaction.postedSpaceIDs.insert(nextSpaceID)
                updatedState.transaction = updatedTransaction
                displayStates[displayID] = updatedState
                publish()
            }

            guard
                let updatedTransaction = displayStates[displayID]?.transaction
            else {
                return
            }

            if updatedTransaction.projectedSpaceID == updatedTransaction.desiredSpaceID {
                finishWorker(for: displayID, generation: generation)
                scheduleAcknowledgementDeadline(
                    for: displayID,
                    generation: generation
                )
                return
            }

            do {
                try await dependencies.sleep(interval)
            } catch {
                if isCurrentWorker(for: displayID, generation: generation) {
                    abortTransaction(for: displayID, generation: generation)
                }
                return
            }
        }
    }

    private func scheduleAcknowledgementDeadline(
        for displayID: DisplayID,
        generation: UInt64
    ) {
        acknowledgementTask?.cancel()
        acknowledgementTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.dependencies.sleep(Self.acknowledgementTimeout)
            } catch {
                return
            }
            await self.handleAcknowledgementDeadline(
                for: displayID,
                generation: generation
            )
        }
    }

    private func handleAcknowledgementDeadline(
        for displayID: DisplayID,
        generation: UInt64
    ) {
        guard
            generation == workerGeneration,
            var state = displayStates[displayID],
            state.transaction != nil
        else {
            return
        }

        if let fresh = try? dependencies.system.loadSnapshot(),
            let topology = fresh.topologiesByDisplay[displayID]
        {
            snapshot = fresh
            if topology.currentSpaceID == state.transaction?.desiredSpaceID {
                reconcile(snapshot: fresh, reason: .activeSpaceChanged)
                publish()
                return
            }
            state.topology = topology
            state.confirmedSpaceID = topology.currentSpaceID
        }

        state.transaction = nil
        displayStates[displayID] = state
        if transactionDisplayID == displayID {
            transactionDisplayID = nil
        }
        acknowledgementTask = nil
        dependencies.diagnose(
            "switch",
            "acknowledgement timeout display=\(displayID.rawValue)"
        )
        publish()
    }

    private func acquirePostingLease(for displayID: DisplayID) {
        guard let activeDisplayID = transactionDisplayID else { return }
        invalidateWorker()
        if activeDisplayID != displayID,
            var state = displayStates[activeDisplayID]
        {
            state.transaction = nil
            displayStates[activeDisplayID] = state
            transactionDisplayID = nil
            dependencies.diagnose(
                "switch",
                "superseded display=\(activeDisplayID.rawValue) by display=\(displayID.rawValue)"
            )
        }
    }

    private func cancelTransaction(for displayID: DisplayID) {
        cancelPostingIfNeeded(for: displayID)
        if var state = displayStates[displayID] {
            state.transaction = nil
            displayStates[displayID] = state
        }
        if transactionDisplayID == displayID {
            transactionDisplayID = nil
        }
        publish()
    }

    private func abortTransaction(
        for displayID: DisplayID,
        generation: UInt64
    ) {
        guard isCurrentWorker(for: displayID, generation: generation) else {
            return
        }
        invalidateWorker()
        if var state = displayStates[displayID] {
            state.transaction = nil
            displayStates[displayID] = state
        }
        if transactionDisplayID == displayID {
            transactionDisplayID = nil
        }
        dependencies.diagnose("switch", "aborted display=\(displayID.rawValue)")
        publish()
    }

    private func matchingState(for topology: DisplayTopology) -> DisplayState? {
        guard
            let state = displayStates[topology.displayID],
            state.topology.spaceIDs == topology.spaceIDs
        else {
            return nil
        }
        return state
    }

    private func settleTransaction(in state: inout DisplayState) {
        guard let transaction = state.transaction else { return }
        if transaction.originSpaceID != transaction.desiredSpaceID,
            state.topology.spaceIDs.contains(transaction.originSpaceID)
        {
            state.lastSpaceID = transaction.originSpaceID
        }
        state.transaction = nil
    }

    private func pruneHistory(in state: inout DisplayState) {
        if let lastSpaceID = state.lastSpaceID,
            (!state.topology.spaceIDs.contains(lastSpaceID)
                || lastSpaceID == state.confirmedSpaceID)
        {
            state.lastSpaceID = nil
        }
    }

    private func cancelPostingIfNeeded(for displayID: DisplayID) {
        if workerDisplayID == displayID || transactionDisplayID == displayID {
            invalidateWorker()
        }
        if transactionDisplayID == displayID {
            transactionDisplayID = nil
        }
    }

    private func invalidateWorker() {
        workerGeneration &+= 1
        worker?.cancel()
        worker = nil
        workerDisplayID = nil
        acknowledgementTask?.cancel()
        acknowledgementTask = nil
    }

    private func isCurrentWorker(
        for displayID: DisplayID,
        generation: UInt64
    ) -> Bool {
        !Task.isCancelled
            && workerGeneration == generation
            && workerDisplayID == displayID
    }

    private func finishWorker(
        for displayID: DisplayID,
        generation: UInt64
    ) {
        guard
            workerGeneration == generation,
            workerDisplayID == displayID
        else {
            return
        }
        worker = nil
        workerDisplayID = nil
    }

    private func makePresentation() -> SpacePresentation {
        SpacePresentation(
            snapshot: snapshot,
            projectedSpaceByDisplay: displayStates.mapValues {
                $0.transaction?.projectedSpaceID ?? $0.confirmedSpaceID
            },
            lastSpaceByDisplay: displayStates.compactMapValues(\.lastSpaceID)
        )
    }

    private func publish() {
        dependencies.publish(makePresentation())
    }
}
