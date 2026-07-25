import Foundation

actor SpaceSwitchEngine {
    nonisolated enum ReconciliationReason: Sendable {
        case request
        case activeSpaceChanged
        case passive

        var resolvesConflicts: Bool {
            self != .passive
        }

        var resumesPendingWork: Bool {
            self != .request
        }
    }

    nonisolated struct Dependencies: Sendable {
        let system: any SpaceSystemClient
        let displays: any DisplayLocating
        let overlays: any OverlayDetecting
        let poster: any SpaceGesturePosting
        let sleep: @Sendable (Duration) async throws -> Void
        let diagnose: @Sendable (String, String) -> Void
        let missionControlDidFail: @Sendable () -> Void
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
            missionControlDidFail: @escaping @Sendable () -> Void = {},
            publish: @escaping @Sendable (SpacePresentation) -> Void
        ) {
            self.system = system
            self.displays = displays
            self.overlays = overlays
            self.poster = poster
            self.sleep = sleep
            self.diagnose = diagnose
            self.missionControlDidFail = missionControlDidFail
            self.publish = publish
        }
    }

    private struct PostedStep {
        let targetSpaceID: SpaceID
        let direction: SpaceSwitchDirection
    }

    private struct Transaction {
        let originSpaceID: SpaceID
        var desiredSpaceID: SpaceID
        var inFlightStep: PostedStep?
        let mode: SpaceSwitchMode
        var velocity: Double
    }

    private struct DisplayState {
        var topology: DisplayTopology
        var confirmedSpaceID: SpaceID
        var lastSpaceID: SpaceID?
        var transaction: Transaction?
    }

    private static let acknowledgementTimeout: Duration = .seconds(2)

    private let dependencies: Dependencies
    private var snapshot: SystemSpaceSnapshot?
    private var displayStates: [DisplayID: DisplayState] = [:]
    private var transactionDisplayID: DisplayID?
    private var acknowledgementGeneration: UInt64 = 0
    private var acknowledgementTask: Task<Void, Never>?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func start() {
        refresh(reason: .passive)
    }

    func stop() {
        cancelExecution()
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
        guard let displayID = try? dependencies.displays.cursorDisplayID() else {
            return .unavailable
        }
        return submit(
            SpaceSwitchRequest(
                action: action,
                source: source,
                targetDisplayID: displayID,
                wraps: wraps,
                velocity: velocity
            )
        )
    }

    @discardableResult
    func submit(_ request: SpaceSwitchRequest) -> SpaceSwitchOutcome {
        guard
            let freshSnapshot = loadSnapshot(reason: .request),
            let topology = freshSnapshot.topologiesByDisplay[request.targetDisplayID],
            postingContextIsValid(for: request.targetDisplayID, topology: topology)
        else {
            return .unavailable
        }

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

        let planningSpaceID = state.transaction?.desiredSpaceID ?? state.confirmedSpaceID
        guard let planningIndex = topology.index(of: planningSpaceID) else {
            return .unavailable
        }

        if case .step = request.action, topology.spaceIDs.count == 1 {
            return .blockedAtEdge
        }

        let targetSpaceID: SpaceID
        switch request.action {
        case .step(.left):
            if planningIndex > 0 {
                targetSpaceID = topology.spaceIDs[planningIndex - 1]
            } else if request.wraps {
                targetSpaceID = topology.spaceIDs.last!
            } else {
                return .blockedAtEdge
            }
        case .step(.right):
            if planningIndex + 1 < topology.spaceIDs.count {
                targetSpaceID = topology.spaceIDs[planningIndex + 1]
            } else if request.wraps {
                targetSpaceID = topology.spaceIDs.first!
            } else {
                return .blockedAtEdge
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
        if let transaction = state.transaction, transaction.mode != mode {
            cancelTransaction(for: topology.displayID, reason: "overlay mode changed")
            return .unavailable
        }

        acquireTransactionLease(for: topology.displayID)

        if var transaction = state.transaction {
            transaction.desiredSpaceID = targetSpaceID
            transaction.velocity = max(1, request.velocity)
            state.transaction = transaction
        } else {
            state.transaction = Transaction(
                originSpaceID: state.confirmedSpaceID,
                desiredSpaceID: targetSpaceID,
                inFlightStep: nil,
                mode: mode,
                velocity: max(1, request.velocity)
            )
        }

        displayStates[topology.displayID] = state
        transactionDisplayID = topology.displayID
        dependencies.diagnose(
            "switch",
            "intent source=\(request.source.rawValue) display=\(topology.displayID.rawValue) "
                + "confirmed=\(state.confirmedSpaceID.rawValue) desired=\(targetSpaceID.rawValue)"
        )
        publish()
        postNextStepIfPossible(for: topology.displayID)
        return .accepted
    }

    private func mode(for displayID: DisplayID) -> SpaceSwitchMode {
        dependencies.overlays.detect(on: displayID) == .missionControl
            ? .missionControl
            : .instant
    }

    @discardableResult
    private func loadSnapshot(reason: ReconciliationReason) -> SystemSpaceSnapshot? {
        guard let value = try? dependencies.system.loadSnapshot() else {
            return nil
        }

        snapshot = value
        let resumableDisplays = reconcile(snapshot: value, reason: reason)
        publish()

        if reason.resumesPendingWork {
            for displayID in resumableDisplays {
                postNextStepIfPossible(for: displayID)
            }
        }
        return value
    }

    private func reconcile(
        snapshot: SystemSpaceSnapshot,
        reason: ReconciliationReason
    ) -> [DisplayID] {
        var resumableDisplays: [DisplayID] = []
        let removed = Set(displayStates.keys).subtracting(snapshot.topologiesByDisplay.keys)
        for displayID in removed {
            cancelExecution(for: displayID)
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
                cancelExecution(for: displayID)
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

            if var transaction = state.transaction {
                guard transaction.mode == mode(for: displayID) else {
                    cancelExecution(for: displayID)
                    state.transaction = nil
                    state.confirmedSpaceID = topology.currentSpaceID
                    if topology.spaceIDs.contains(previousConfirmed),
                        previousConfirmed != topology.currentSpaceID
                    {
                        state.lastSpaceID = previousConfirmed
                    }
                    pruneHistory(in: &state)
                    displayStates[displayID] = state
                    dependencies.diagnose(
                        "switch",
                        "cancelled display=\(displayID.rawValue) reason=overlay mode changed"
                    )
                    continue
                }

                if let inFlightStep = transaction.inFlightStep {
                    if topology.currentSpaceID == inFlightStep.targetSpaceID {
                        cancelAcknowledgement(for: displayID)
                        state.confirmedSpaceID = topology.currentSpaceID
                        transaction.inFlightStep = nil
                        state.transaction = transaction
                        dependencies.diagnose(
                            "switch",
                            "acknowledged display=\(displayID.rawValue) "
                                + "space=\(topology.currentSpaceID.rawValue)"
                        )

                        if transaction.desiredSpaceID == topology.currentSpaceID {
                            settleTransaction(in: &state, displayID: displayID)
                        } else {
                            resumableDisplays.append(displayID)
                        }
                    } else if topology.currentSpaceID != state.confirmedSpaceID,
                        reason.resolvesConflicts
                    {
                        cancelExecution(for: displayID)
                        state.transaction = nil
                        state.confirmedSpaceID = topology.currentSpaceID
                        if topology.spaceIDs.contains(previousConfirmed) {
                            state.lastSpaceID = previousConfirmed
                        }
                        dependencies.diagnose(
                            "switch",
                            "unexpected authoritative space display=\(displayID.rawValue) "
                                + "space=\(topology.currentSpaceID.rawValue)"
                        )
                    }
                } else if topology.currentSpaceID != state.confirmedSpaceID {
                    if reason.resolvesConflicts {
                        cancelExecution(for: displayID)
                        state.transaction = nil
                        state.confirmedSpaceID = topology.currentSpaceID
                        if topology.spaceIDs.contains(previousConfirmed) {
                            state.lastSpaceID = previousConfirmed
                        }
                    }
                } else if transaction.desiredSpaceID == state.confirmedSpaceID {
                    settleTransaction(in: &state, displayID: displayID)
                } else {
                    resumableDisplays.append(displayID)
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

        return resumableDisplays
    }

    private func postNextStepIfPossible(for displayID: DisplayID) {
        guard
            var state = displayStates[displayID],
            var transaction = state.transaction,
            transaction.inFlightStep == nil
        else {
            return
        }

        guard transaction.desiredSpaceID != state.confirmedSpaceID else {
            settleTransaction(in: &state, displayID: displayID)
            displayStates[displayID] = state
            publish()
            return
        }

        guard
            postingContextIsValid(for: displayID, topology: state.topology),
            mode(for: displayID) == transaction.mode,
            let confirmedIndex = state.topology.index(of: state.confirmedSpaceID),
            let desiredIndex = state.topology.index(of: transaction.desiredSpaceID)
        else {
            abortTransaction(for: displayID, reason: "posting context changed")
            return
        }

        let direction: SpaceSwitchDirection = desiredIndex > confirmedIndex ? .right : .left
        let nextIndex = confirmedIndex + (direction == .right ? 1 : -1)
        guard state.topology.spaceIDs.indices.contains(nextIndex) else {
            abortTransaction(for: displayID, reason: "next target is outside topology")
            return
        }

        let nextSpaceID = state.topology.spaceIDs[nextIndex]
        let remainingSteps = abs(desiredIndex - confirmedIndex)
        guard dependencies.poster.postStep(
            mode: transaction.mode,
            direction: direction,
            velocity: transaction.velocity * Double(max(1, remainingSteps))
        ) else {
            abortTransaction(
                for: displayID,
                reason: "event posting failed",
                reportsMissionControlFailure: true
            )
            return
        }

        transaction.inFlightStep = PostedStep(
            targetSpaceID: nextSpaceID,
            direction: direction
        )
        state.transaction = transaction
        displayStates[displayID] = state
        dependencies.diagnose(
            "switch",
            "posted display=\(displayID.rawValue) mode=\(transaction.mode) direction=\(direction) "
                + "target=\(nextSpaceID.rawValue) desired=\(transaction.desiredSpaceID.rawValue)"
        )
        publish()
        scheduleAcknowledgementDeadline(
            for: displayID,
            targetSpaceID: nextSpaceID,
            mode: transaction.mode
        )
    }

    private func scheduleAcknowledgementDeadline(
        for displayID: DisplayID,
        targetSpaceID: SpaceID,
        mode: SpaceSwitchMode
    ) {
        acknowledgementTask?.cancel()
        acknowledgementGeneration &+= 1
        let generation = acknowledgementGeneration
        acknowledgementTask = Task { [weak self] in
            guard let self else { return }
            do {
                let timeout = mode == .missionControl
                    ? Duration.milliseconds(400)
                    : Self.acknowledgementTimeout
                try await self.dependencies.sleep(timeout)
            } catch {
                return
            }
            await self.handleAcknowledgementDeadline(
                for: displayID,
                targetSpaceID: targetSpaceID,
                generation: generation
            )
        }
    }

    private func handleAcknowledgementDeadline(
        for displayID: DisplayID,
        targetSpaceID: SpaceID,
        generation: UInt64
    ) {
        guard
            generation == acknowledgementGeneration,
            let state = displayStates[displayID],
            state.transaction?.inFlightStep?.targetSpaceID == targetSpaceID
        else {
            return
        }

        if let fresh = try? dependencies.system.loadSnapshot(),
            let topology = fresh.topologiesByDisplay[displayID],
            topology.currentSpaceID != state.confirmedSpaceID
        {
            snapshot = fresh
            let resumableDisplays = reconcile(snapshot: fresh, reason: .activeSpaceChanged)
            publish()
            for resumableDisplayID in resumableDisplays {
                postNextStepIfPossible(for: resumableDisplayID)
            }
            return
        }

        abortTransaction(
            for: displayID,
            reason: "acknowledgement timeout",
            reportsMissionControlFailure: true
        )
    }

    private func acquireTransactionLease(for displayID: DisplayID) {
        guard let activeDisplayID = transactionDisplayID, activeDisplayID != displayID else {
            return
        }

        cancelExecution(for: activeDisplayID)
        if var state = displayStates[activeDisplayID] {
            state.transaction = nil
            displayStates[activeDisplayID] = state
        }
        dependencies.diagnose(
            "switch",
            "superseded display=\(activeDisplayID.rawValue) by display=\(displayID.rawValue)"
        )
    }

    private func cancelTransaction(for displayID: DisplayID, reason: String) {
        cancelExecution(for: displayID)
        if var state = displayStates[displayID] {
            state.transaction = nil
            displayStates[displayID] = state
        }
        dependencies.diagnose("switch", "cancelled display=\(displayID.rawValue) reason=\(reason)")
        publish()
    }

    private func abortTransaction(
        for displayID: DisplayID,
        reason: String,
        reportsMissionControlFailure: Bool = false
    ) {
        let mode = displayStates[displayID]?.transaction?.mode
        cancelExecution(for: displayID)
        if var state = displayStates[displayID] {
            state.transaction = nil
            displayStates[displayID] = state
        }
        dependencies.diagnose("switch", "aborted display=\(displayID.rawValue) reason=\(reason)")
        if reportsMissionControlFailure, mode == .missionControl {
            dependencies.missionControlDidFail()
        }
        publish()
    }

    private func postingContextIsValid(
        for displayID: DisplayID,
        topology: DisplayTopology
    ) -> Bool {
        guard
            dependencies.displays.bounds(for: displayID) != nil,
            (try? dependencies.displays.cursorDisplayID()) == displayID,
            let currentSnapshot = try? dependencies.system.loadSnapshot(),
            let currentTopology = currentSnapshot.topologiesByDisplay[displayID]
        else {
            return false
        }

        return currentTopology.spaceIDs == topology.spaceIDs
            && currentTopology.currentSpaceID == topology.currentSpaceID
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

    private func settleTransaction(in state: inout DisplayState, displayID: DisplayID) {
        guard let transaction = state.transaction else { return }
        if transaction.originSpaceID != transaction.desiredSpaceID,
            state.topology.spaceIDs.contains(transaction.originSpaceID)
        {
            state.lastSpaceID = transaction.originSpaceID
        }
        state.transaction = nil
        cancelExecution(for: displayID)
    }

    private func pruneHistory(in state: inout DisplayState) {
        if let lastSpaceID = state.lastSpaceID,
            (!state.topology.spaceIDs.contains(lastSpaceID)
                || lastSpaceID == state.confirmedSpaceID)
        {
            state.lastSpaceID = nil
        }
    }

    private func cancelAcknowledgement(for displayID: DisplayID) {
        guard transactionDisplayID == displayID else { return }
        acknowledgementGeneration &+= 1
        acknowledgementTask?.cancel()
        acknowledgementTask = nil
    }

    private func cancelExecution(for displayID: DisplayID) {
        guard transactionDisplayID == displayID else { return }
        cancelExecution()
    }

    private func cancelExecution() {
        acknowledgementGeneration &+= 1
        acknowledgementTask?.cancel()
        acknowledgementTask = nil
        transactionDisplayID = nil
    }

    private func makePresentation() -> SpacePresentation {
        SpacePresentation(
            snapshot: snapshot,
            projectedSpaceByDisplay: displayStates.mapValues {
                $0.transaction?.desiredSpaceID ?? $0.confirmedSpaceID
            },
            lastSpaceByDisplay: displayStates.compactMapValues(\.lastSpaceID)
        )
    }

    private func publish() {
        dependencies.publish(makePresentation())
    }
}
