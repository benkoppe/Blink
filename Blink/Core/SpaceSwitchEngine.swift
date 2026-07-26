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
        let missionControlCapability: MissionControlSyntheticCapability
        let sleep: @Sendable (Duration) async throws -> Void
        let diagnose: @Sendable (String, String) -> Void

        init(
            system: any SpaceSystemClient,
            displays: any DisplayLocating,
            overlays: any OverlayDetecting,
            poster: any SpaceGesturePosting,
            missionControlCapability: MissionControlSyntheticCapability,
            sleep: @escaping @Sendable (Duration) async throws -> Void = {
                try await Task<Never, Never>.sleep(for: $0)
            },
            diagnose: @escaping @Sendable (String, String) -> Void = { _, _ in }
        ) {
            self.system = system
            self.displays = displays
            self.overlays = overlays
            self.poster = poster
            self.missionControlCapability = missionControlCapability
            self.sleep = sleep
            self.diagnose = diagnose
        }
    }

    private struct PostedStep {
        let targetSpaceID: SpaceID
        let postedAtUptime: TimeInterval
    }

    private struct Transaction {
        let targetDisplayID: DisplayID
        let originSpaceID: SpaceID
        var desiredSpaceID: SpaceID
        var inFlightSteps: [PostedStep]
        let mode: SpaceSwitchMode
        var requiredMode: SpaceSwitchMode?
        var velocity: Double
        let startedAtUptime: TimeInterval
        var postedStepCount: Int
    }

    private struct DisplayState {
        var topology: DisplayTopology
        var confirmedSpaceID: SpaceID
        var lastSpaceID: SpaceID?
        var transaction: Transaction?
    }

    private enum PostingResult {
        case posted
        case waiting
        case failed(SpaceSwitchOutcome)
    }

    // Instant mode may post a small window so direct jumps do not visibly dwell
    // on every intermediate Space. Mission Control remains strictly one-at-a-time.
    private static let maximumInstantStepsInFlight = 4
    private static let acknowledgementTimeout: Duration = .seconds(2)

    nonisolated let presentations: AsyncStream<SpacePresentation>

    private let dependencies: Dependencies
    private let presentationContinuation: AsyncStream<SpacePresentation>.Continuation
    private var snapshot: SystemSpaceSnapshot?
    private var displayStates: [ManagedDisplayID: DisplayState] = [:]
    private var transactionManagedDisplayID: ManagedDisplayID?
    private var acknowledgementGeneration: UInt64 = 0
    private var acknowledgementTask: Task<Void, Never>?
    private var isStopped = false

    init(dependencies: Dependencies) {
        let (presentations, continuation) = AsyncStream.makeStream(
            of: SpacePresentation.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.presentations = presentations
        self.presentationContinuation = continuation
        self.dependencies = dependencies
    }

    func start() {
        guard !isStopped else { return }
        refresh(reason: .passive)
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        for managedDisplayID in displayStates.keys {
            diagnoseRollback(for: managedDisplayID, reason: "engine teardown")
        }
        cancelExecution()
        snapshot = nil
        displayStates.removeAll()
        publish()
        presentationContinuation.finish()
    }

    @discardableResult
    func submit(_ request: SpaceSwitchRequest) -> SpaceSwitchOutcome {
        guard !Task.isCancelled else { return .unavailable }
        guard !isStopped else { return .unavailable }
        guard
            let freshSnapshot = loadSnapshot(reason: .request),
            let managedDisplayID = freshSnapshot.managedDisplayID(
                for: request.targetDisplayID
            ),
            let topology = freshSnapshot.topologiesByManagedDisplay[managedDisplayID],
            postingContextIsValid(for: request.targetDisplayID),
            let mode = mode(
                for: request.targetDisplayID,
                requiredMode: request.requiredMode
            )
        else {
            return .unavailable
        }

        if mode == .missionControl,
            dependencies.missionControlCapability.state(on: request.targetDisplayID) != .available
        {
            return .missionControlSyntheticUnavailable
        }

        return submit(
            request,
            managedDisplayID: managedDisplayID,
            topology: topology,
            mode: mode
        )
    }

    func refresh(reason: ReconciliationReason) {
        guard !isStopped else { return }
        _ = loadSnapshot(reason: reason)
    }

    func presentation() -> SpacePresentation {
        makePresentation()
    }

    private func submit(
        _ request: SpaceSwitchRequest,
        managedDisplayID: ManagedDisplayID,
        topology: DisplayTopology,
        mode: SpaceSwitchMode
    ) -> SpaceSwitchOutcome {
        if let transaction = displayStates[managedDisplayID]?.transaction,
            transaction.targetDisplayID != request.targetDisplayID
        {
            cancelTransaction(
                for: managedDisplayID,
                reason: "superseded by physical display \(request.targetDisplayID.rawValue)"
            )
        }

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

        if let transaction = state.transaction, transaction.mode != mode {
            cancelTransaction(for: managedDisplayID, reason: "overlay mode changed")
            return .unavailable
        }

        acquireTransactionLease(for: managedDisplayID)

        if var transaction = state.transaction {
            transaction.desiredSpaceID = targetSpaceID
            transaction.requiredMode = request.requiredMode ?? transaction.requiredMode
            transaction.velocity = max(1, request.velocity)
            state.transaction = transaction
        } else {
            state.transaction = Transaction(
                targetDisplayID: request.targetDisplayID,
                originSpaceID: state.confirmedSpaceID,
                desiredSpaceID: targetSpaceID,
                inFlightSteps: [],
                mode: mode,
                requiredMode: request.requiredMode,
                velocity: max(1, request.velocity),
                startedAtUptime: ProcessInfo.processInfo.systemUptime,
                postedStepCount: 0
            )
        }

        displayStates[managedDisplayID] = state
        transactionManagedDisplayID = managedDisplayID
        publish()
        let postingResult = postNextWindowIfPossible(
            for: managedDisplayID,
            validatedMode: mode,
            contextAlreadyValidated: true
        )
        if case .failed(let outcome) = postingResult {
            return outcome
        }
        dependencies.diagnose(
            "switch",
            "transaction accepted source=\(request.source.rawValue) "
                + "display=\(request.targetDisplayID.rawValue) topology=\(managedDisplayID.rawValue) "
                + "confirmed=\(state.confirmedSpaceID.rawValue) "
                + "desired=\(targetSpaceID.rawValue) uptime=\(ProcessInfo.processInfo.systemUptime)"
        )
        return .accepted
    }

    private func observeOverlay(on displayID: DisplayID) -> OverlayMode {
        let sampledAtUptime = ProcessInfo.processInfo.systemUptime
        let overlayMode = dependencies.overlays.detect(on: displayID)
        dependencies.missionControlCapability.observeOverlay(
            overlayMode,
            on: displayID,
            sampledAtUptime: sampledAtUptime
        )
        return overlayMode
    }

    private func mode(
        for displayID: DisplayID,
        requiredMode: SpaceSwitchMode? = nil
    ) -> SpaceSwitchMode? {
        mode(from: observeOverlay(on: displayID), requiredMode: requiredMode)
    }

    private func mode(
        from overlayMode: OverlayMode,
        requiredMode: SpaceSwitchMode?
    ) -> SpaceSwitchMode? {
        guard let requiredMode else {
            switch overlayMode {
            case .none: return .instant
            case .missionControl: return .missionControl
            case .appExpose, .unknown: return nil
            }
        }
        switch (overlayMode, requiredMode) {
        case (.none, .instant), (.missionControl, .missionControl):
            return requiredMode
        case (.none, .missionControl), (.missionControl, .instant),
            (.appExpose, _), (.unknown, _):
            return nil
        }
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
            for (displayID, validatedMode) in resumableDisplays {
                postNextWindowIfPossible(
                    for: displayID,
                    validatedMode: validatedMode,
                    contextAlreadyValidated: true
                )
            }
        }
        return value
    }

    private func reconcile(
        snapshot: SystemSpaceSnapshot,
        reason: ReconciliationReason
    ) -> [ManagedDisplayID: SpaceSwitchMode] {
        var resumableDisplays: [ManagedDisplayID: SpaceSwitchMode] = [:]
        let cursorDisplayID = try? dependencies.displays.cursorDisplayID()
        let removed = Set(displayStates.keys).subtracting(snapshot.topologiesByManagedDisplay.keys)
        for managedDisplayID in removed {
            diagnoseRollback(for: managedDisplayID, reason: "display removed")
            cancelExecution(for: managedDisplayID)
            displayStates.removeValue(forKey: managedDisplayID)
        }

        for (managedDisplayID, topology) in snapshot.topologiesByManagedDisplay {
            guard var state = displayStates[managedDisplayID] else {
                displayStates[managedDisplayID] = DisplayState(
                    topology: topology,
                    confirmedSpaceID: topology.currentSpaceID,
                    lastSpaceID: nil,
                    transaction: nil
                )
                continue
            }

            let previousConfirmed = state.confirmedSpaceID
            guard state.topology.spaceIDs == topology.spaceIDs else {
                diagnoseRollback(for: managedDisplayID, reason: "topology changed")
                cancelExecution(for: managedDisplayID)
                state.topology = topology
                state.confirmedSpaceID = topology.currentSpaceID
                state.transaction = nil
                if topology.spaceIDs.contains(previousConfirmed),
                    previousConfirmed != topology.currentSpaceID
                {
                    state.lastSpaceID = previousConfirmed
                }
                pruneHistory(in: &state)
                displayStates[managedDisplayID] = state
                continue
            }

            state.topology = topology

            if var transaction = state.transaction {
                // Authoritative movement is processed before cursor and overlay
                // checks. Those checks can be transient during animation and
                // must not discard a valid acknowledgement.
                if !transaction.inFlightSteps.isEmpty,
                    let acknowledgedIndex = transaction.inFlightSteps.firstIndex(where: {
                        $0.targetSpaceID == topology.currentSpaceID
                    })
                {
                    let acknowledgedStep = transaction.inFlightSteps[acknowledgedIndex]
                    state.confirmedSpaceID = topology.currentSpaceID
                    transaction.inFlightSteps.removeFirst(acknowledgedIndex + 1)
                    state.transaction = transaction
                    if transaction.mode == .missionControl {
                        dependencies.missionControlCapability
                            .recordAuthoritativeAcknowledgement(on: transaction.targetDisplayID)
                    }
                    dependencies.diagnose(
                        "switch-timing",
                        "authoritative acknowledgement display=\(transaction.targetDisplayID.rawValue) "
                            + "space=\(topology.currentSpaceID.rawValue) "
                            + "post-to-ack-ms=\(milliseconds(since: acknowledgedStep.postedAtUptime))"
                    )
                    if transaction.inFlightSteps.isEmpty {
                        cancelAcknowledgement(for: managedDisplayID)
                        if transaction.desiredSpaceID == topology.currentSpaceID {
                            settleTransaction(in: &state, managedDisplayID: managedDisplayID)
                        }
                    }
                } else if topology.currentSpaceID != state.confirmedSpaceID,
                    reason.resolvesConflicts
                {
                    diagnoseRollback(for: managedDisplayID, reason: "authoritative disagreement")
                    cancelExecution(for: managedDisplayID)
                    state.transaction = nil
                    state.confirmedSpaceID = topology.currentSpaceID
                    if topology.spaceIDs.contains(previousConfirmed) {
                        state.lastSpaceID = previousConfirmed
                    }
                    dependencies.diagnose(
                        "switch",
                        "unexpected authoritative space topology=\(managedDisplayID.rawValue) "
                            + "space=\(topology.currentSpaceID.rawValue)"
                    )
                }

                if let remaining = state.transaction {
                    guard
                        dependencies.displays.bounds(for: remaining.targetDisplayID) != nil,
                        cursorDisplayID == remaining.targetDisplayID
                    else {
                        diagnoseRollback(for: managedDisplayID, reason: "cursor display changed")
                        cancelExecution(for: managedDisplayID)
                        preserveTransactionOriginIfAdvanced(remaining, in: &state)
                        state.transaction = nil
                        displayStates[managedDisplayID] = state
                        continue
                    }

                    let observedOverlay = observeOverlay(on: remaining.targetDisplayID)
                    if observedOverlay != .unknown,
                        mode(from: observedOverlay, requiredMode: remaining.requiredMode)
                            != remaining.mode
                    {
                        diagnoseRollback(for: managedDisplayID, reason: "overlay mode changed")
                        cancelExecution(for: managedDisplayID)
                        preserveTransactionOriginIfAdvanced(remaining, in: &state)
                        state.transaction = nil
                        dependencies.diagnose(
                            "switch",
                            "cancelled display=\(remaining.targetDisplayID.rawValue) reason=overlay mode changed"
                        )
                    } else if observedOverlay != .unknown,
                        remaining.inFlightSteps.isEmpty
                    {
                        if remaining.desiredSpaceID == state.confirmedSpaceID {
                            settleTransaction(in: &state, managedDisplayID: managedDisplayID)
                        } else {
                            resumableDisplays[managedDisplayID] = remaining.mode
                        }
                    }
                    // Unknown is fail-closed for posting but preserves the
                    // acknowledged transaction for a later authoritative refresh.
                }
            } else if previousConfirmed != topology.currentSpaceID {
                state.confirmedSpaceID = topology.currentSpaceID
                if topology.spaceIDs.contains(previousConfirmed) {
                    state.lastSpaceID = previousConfirmed
                }
            }

            pruneHistory(in: &state)
            displayStates[managedDisplayID] = state
        }

        return resumableDisplays
    }

    @discardableResult
    private func postNextWindowIfPossible(
        for managedDisplayID: ManagedDisplayID,
        validatedMode: SpaceSwitchMode? = nil,
        contextAlreadyValidated: Bool = false
    ) -> PostingResult {
        guard
            var state = displayStates[managedDisplayID],
            var transaction = state.transaction,
            transaction.inFlightSteps.isEmpty
        else {
            return .waiting
        }

        guard transaction.desiredSpaceID != state.confirmedSpaceID else {
            settleTransaction(in: &state, managedDisplayID: managedDisplayID)
            displayStates[managedDisplayID] = state
            publish()
            return .waiting
        }

        if !contextAlreadyValidated,
            !postingContextIsValid(for: transaction.targetDisplayID)
        {
            abortTransaction(for: managedDisplayID, reason: "posting context changed")
            return .failed(.unavailable)
        }
        let currentMode: SpaceSwitchMode?
        if let validatedMode {
            currentMode = validatedMode
        } else {
            let observedOverlay = observeOverlay(on: transaction.targetDisplayID)
            guard observedOverlay != .unknown else {
                // Keep acknowledged intent for a later refresh, but never post
                // from uncertain overlay state.
                return .waiting
            }
            currentMode = mode(
                from: observedOverlay,
                requiredMode: transaction.requiredMode
            )
        }
        guard
            currentMode == transaction.mode,
            let confirmedIndex = state.topology.index(of: state.confirmedSpaceID),
            let desiredIndex = state.topology.index(of: transaction.desiredSpaceID)
        else {
            abortTransaction(for: managedDisplayID, reason: "posting context changed")
            return .failed(.unavailable)
        }

        let direction: SpaceSwitchDirection = desiredIndex > confirmedIndex ? .right : .left
        let remainingSteps = abs(desiredIndex - confirmedIndex)
        let windowSize = transaction.mode == .instant
            ? min(Self.maximumInstantStepsInFlight, remainingSteps)
            : 1

        if transaction.mode == .missionControl,
            dependencies.missionControlCapability.state(on: transaction.targetDisplayID) != .available
        {
            abortTransaction(for: managedDisplayID, reason: "Mission Control synthetic unavailable")
            return .failed(.missionControlSyntheticUnavailable)
        }

        let velocity = transaction.velocity * Double(max(1, remainingSteps))
        var postedSteps: [PostedStep] = []
        var postingFailed = false
        for offset in 1...windowSize {
            let nextIndex = confirmedIndex + (direction == .right ? offset : -offset)
            guard state.topology.spaceIDs.indices.contains(nextIndex) else {
                abortTransaction(for: managedDisplayID, reason: "next target is outside topology")
                return .failed(.invalidTarget)
            }

            guard dependencies.poster.postStep(
                mode: transaction.mode,
                direction: direction,
                velocity: velocity
            ) else {
                postingFailed = true
                break
            }

            postedSteps.append(
                PostedStep(
                    targetSpaceID: state.topology.spaceIDs[nextIndex],
                    postedAtUptime: ProcessInfo.processInfo.systemUptime
                )
            )
        }

        guard !postedSteps.isEmpty else {
            abortTransaction(
                for: managedDisplayID,
                reason: "event posting failed",
                reportsMissionControlFailure: true
            )
            return .failed(
                transaction.mode == .missionControl
                    ? .missionControlSyntheticUnavailable : .unavailable
            )
        }

        transaction.inFlightSteps = postedSteps
        transaction.postedStepCount += postedSteps.count
        state.transaction = transaction
        displayStates[managedDisplayID] = state
        let lastPostedSpaceID = postedSteps.last!.targetSpaceID
        dependencies.diagnose(
            "switch",
            "synthetic post display=\(transaction.targetDisplayID.rawValue) mode=\(transaction.mode) "
                + "direction=\(direction) steps=\(postedSteps.count) "
                + "target=\(lastPostedSpaceID.rawValue) "
                + "desired=\(transaction.desiredSpaceID.rawValue) "
                + "partial-failure=\(postingFailed)"
        )
        publish()
        scheduleAcknowledgementDeadline(
            for: managedDisplayID,
            targetSpaceID: lastPostedSpaceID
        )
        return .posted
    }

    private func scheduleAcknowledgementDeadline(
        for managedDisplayID: ManagedDisplayID,
        targetSpaceID: SpaceID
    ) {
        acknowledgementTask?.cancel()
        acknowledgementGeneration &+= 1
        let generation = acknowledgementGeneration
        acknowledgementTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.dependencies.sleep(Self.acknowledgementTimeout)
            } catch {
                return
            }
            await self.handleAcknowledgementDeadline(
                for: managedDisplayID,
                targetSpaceID: targetSpaceID,
                generation: generation
            )
        }
    }

    private func handleAcknowledgementDeadline(
        for managedDisplayID: ManagedDisplayID,
        targetSpaceID: SpaceID,
        generation: UInt64
    ) {
        guard
            generation == acknowledgementGeneration,
            let state = displayStates[managedDisplayID],
            state.transaction?.inFlightSteps.last?.targetSpaceID == targetSpaceID
        else {
            return
        }

        guard
            let fresh = try? dependencies.system.loadSnapshot(),
            let topology = fresh.topologiesByManagedDisplay[managedDisplayID],
            topology.spaceIDs == state.topology.spaceIDs
        else {
            abortTransaction(for: managedDisplayID, reason: "acknowledgement unverifiable")
            return
        }

        if topology.currentSpaceID != state.confirmedSpaceID {
            snapshot = fresh
            let resumableDisplays = reconcile(snapshot: fresh, reason: .activeSpaceChanged)
            publish()
            for (resumableDisplayID, validatedMode) in resumableDisplays {
                postNextWindowIfPossible(
                    for: resumableDisplayID,
                    validatedMode: validatedMode,
                    contextAlreadyValidated: true
                )
            }
            if resumableDisplays[managedDisplayID] == nil,
                let transaction = displayStates[managedDisplayID]?.transaction,
                let pendingTargetSpaceID = transaction.inFlightSteps.last?.targetSpaceID
            {
                scheduleAcknowledgementDeadline(
                    for: managedDisplayID,
                    targetSpaceID: pendingTargetSpaceID
                )
            }
            return
        }

        dependencies.diagnose(
            "switch-timing",
            "timeout display=\(state.transaction!.targetDisplayID.rawValue) target=\(targetSpaceID.rawValue)"
        )
        let transaction = state.transaction!
        if transaction.mode == .missionControl {
            guard postingContextIsValid(for: transaction.targetDisplayID) else {
                abortTransaction(
                    for: managedDisplayID,
                    reason: "acknowledgement context changed"
                )
                return
            }
            let observedOverlay = observeOverlay(on: transaction.targetDisplayID)
            guard observedOverlay != .unknown,
                mode(from: observedOverlay, requiredMode: transaction.requiredMode)
                    == .missionControl
            else {
                abortTransaction(
                    for: managedDisplayID,
                    reason: "acknowledgement overlay unverifiable"
                )
                return
            }
        }
        let openedCircuit = transaction.mode == .missionControl
            && dependencies.missionControlCapability.recordConfirmedNonmovement(
                on: transaction.targetDisplayID
            )
        abortTransaction(
            for: managedDisplayID,
            reason: "acknowledgement timeout"
        )
        if openedCircuit {
            diagnoseMissionControlCircuitOpen(on: transaction.targetDisplayID)
        }
    }

    private func acquireTransactionLease(for managedDisplayID: ManagedDisplayID) {
        guard
            let activeManagedDisplayID = transactionManagedDisplayID,
            activeManagedDisplayID != managedDisplayID
        else {
            return
        }

        diagnoseRollback(
            for: activeManagedDisplayID,
            reason: "superseded by topology \(managedDisplayID.rawValue)"
        )
        cancelExecution(for: activeManagedDisplayID)
        if var state = displayStates[activeManagedDisplayID] {
            state.transaction = nil
            displayStates[activeManagedDisplayID] = state
        }
        dependencies.diagnose(
            "switch",
            "superseded topology=\(activeManagedDisplayID.rawValue) by topology=\(managedDisplayID.rawValue)"
        )
    }

    private func cancelTransaction(for managedDisplayID: ManagedDisplayID, reason: String) {
        diagnoseRollback(for: managedDisplayID, reason: reason)
        cancelExecution(for: managedDisplayID)
        if var state = displayStates[managedDisplayID] {
            state.transaction = nil
            displayStates[managedDisplayID] = state
        }
        dependencies.diagnose(
            "switch",
            "cancelled topology=\(managedDisplayID.rawValue) reason=\(reason)"
        )
        publish()
    }

    private func abortTransaction(
        for managedDisplayID: ManagedDisplayID,
        reason: String,
        reportsMissionControlFailure: Bool = false
    ) {
        let transaction = displayStates[managedDisplayID]?.transaction
        diagnoseRollback(for: managedDisplayID, reason: reason)
        cancelExecution(for: managedDisplayID)
        if var state = displayStates[managedDisplayID] {
            state.transaction = nil
            displayStates[managedDisplayID] = state
        }
        dependencies.diagnose(
            "switch",
            "aborted topology=\(managedDisplayID.rawValue) reason=\(reason)"
        )
        if reportsMissionControlFailure,
            let transaction,
            transaction.mode == .missionControl,
            dependencies.missionControlCapability.recordPostRejection(
                on: transaction.targetDisplayID
            )
        {
            diagnoseMissionControlCircuitOpen(on: transaction.targetDisplayID)
        }
        publish()
    }

    private func postingContextIsValid(for displayID: DisplayID) -> Bool {
        dependencies.displays.bounds(for: displayID) != nil
            && (try? dependencies.displays.cursorDisplayID()) == displayID
    }

    private func matchingState(for topology: DisplayTopology) -> DisplayState? {
        guard
            let state = displayStates[topology.managedDisplayID],
            state.topology.spaceIDs == topology.spaceIDs
        else {
            return nil
        }
        return state
    }

    private func settleTransaction(
        in state: inout DisplayState,
        managedDisplayID: ManagedDisplayID
    ) {
        guard let transaction = state.transaction else { return }
        dependencies.diagnose(
            "switch-timing",
            "transaction settlement display=\(transaction.targetDisplayID.rawValue) "
                + "posts=\(transaction.postedStepCount) "
                + "elapsed-ms=\(milliseconds(since: transaction.startedAtUptime))"
        )
        if transaction.originSpaceID != transaction.desiredSpaceID,
            state.topology.spaceIDs.contains(transaction.originSpaceID)
        {
            state.lastSpaceID = transaction.originSpaceID
        }
        state.transaction = nil
        cancelExecution(for: managedDisplayID)
    }

    private func diagnoseRollback(for managedDisplayID: ManagedDisplayID, reason: String) {
        guard
            let state = displayStates[managedDisplayID],
            let transaction = state.transaction
        else {
            return
        }
        dependencies.diagnose(
            "switch-timing",
            "cancellation display=\(transaction.targetDisplayID.rawValue) reason=\(reason) "
                + "projection-rollback=\(state.confirmedSpaceID.rawValue) "
                + "elapsed-ms=\(milliseconds(since: transaction.startedAtUptime))"
        )
    }

    private func milliseconds(since start: TimeInterval) -> String {
        String(format: "%.3f", max(0, ProcessInfo.processInfo.systemUptime - start) * 1_000)
    }

    private func preserveTransactionOriginIfAdvanced(
        _ transaction: Transaction,
        in state: inout DisplayState
    ) {
        guard
            state.confirmedSpaceID != transaction.originSpaceID,
            state.topology.spaceIDs.contains(transaction.originSpaceID)
        else {
            return
        }
        state.lastSpaceID = transaction.originSpaceID
    }

    private func pruneHistory(in state: inout DisplayState) {
        if let lastSpaceID = state.lastSpaceID,
            (!state.topology.spaceIDs.contains(lastSpaceID)
                || lastSpaceID == state.confirmedSpaceID)
        {
            state.lastSpaceID = nil
        }
    }

    private func cancelAcknowledgement(for managedDisplayID: ManagedDisplayID) {
        guard transactionManagedDisplayID == managedDisplayID else { return }
        acknowledgementGeneration &+= 1
        acknowledgementTask?.cancel()
        acknowledgementTask = nil
    }

    private func cancelExecution(for managedDisplayID: ManagedDisplayID) {
        guard transactionManagedDisplayID == managedDisplayID else { return }
        cancelExecution()
    }

    private func cancelExecution() {
        acknowledgementGeneration &+= 1
        acknowledgementTask?.cancel()
        acknowledgementTask = nil
        transactionManagedDisplayID = nil
    }

    private func makePresentation() -> SpacePresentation {
        SpacePresentation(
            snapshot: snapshot,
            projectedSpaceByManagedDisplay: displayStates.mapValues {
                $0.transaction?.desiredSpaceID ?? $0.confirmedSpaceID
            },
            lastSpaceByManagedDisplay: displayStates.compactMapValues(\.lastSpaceID)
        )
    }

    private func diagnoseMissionControlCircuitOpen(on displayID: DisplayID) {
        dependencies.diagnose(
            "mission-control",
            "synthetic path unavailable display=\(displayID.rawValue) until confirmed overlay exit"
        )
    }

    private func publish() {
        presentationContinuation.yield(makePresentation())
    }
}
