import Foundation

nonisolated struct DisplayID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }
}

nonisolated struct SpaceID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: UInt64

    init?(rawValue: UInt64) {
        guard rawValue != 0 else { return nil }
        self.rawValue = rawValue
    }
}

nonisolated struct DisplayTopology: Equatable, Sendable {
    let displayID: DisplayID
    let spaceIDs: [SpaceID]
    let currentSpaceID: SpaceID

    init?(
        displayID: DisplayID,
        spaceIDs: [SpaceID],
        currentSpaceID: SpaceID
    ) {
        guard
            !spaceIDs.isEmpty,
            Set(spaceIDs).count == spaceIDs.count,
            spaceIDs.contains(currentSpaceID)
        else {
            return nil
        }

        self.displayID = displayID
        self.spaceIDs = spaceIDs
        self.currentSpaceID = currentSpaceID
    }

    var currentIndex: Int {
        spaceIDs.firstIndex(of: currentSpaceID)!
    }

    func index(of spaceID: SpaceID) -> Int? {
        spaceIDs.firstIndex(of: spaceID)
    }
}

nonisolated struct SystemSpaceSnapshot: Equatable, Sendable {
    let topologiesByDisplay: [DisplayID: DisplayTopology]
    let menuBarDisplayID: DisplayID?

    var menuBarTopology: DisplayTopology? {
        if let menuBarDisplayID,
            let topology = topologiesByDisplay[menuBarDisplayID]
        {
            return topology
        }

        return topologiesByDisplay.values.sorted {
            $0.displayID.rawValue < $1.displayID.rawValue
        }.first
    }
}

nonisolated enum SpaceSwitchDirection: Equatable, Sendable {
    case left
    case right
}

nonisolated enum SpaceSwitchMode: Equatable, Sendable {
    case instant
    case missionControl
}

nonisolated enum MissionControlSyntheticState: Equatable, Sendable {
    case available
    case unavailableUntilOverlayExit
}

nonisolated struct SpacePresentation: Equatable, Sendable {
    let snapshot: SystemSpaceSnapshot?
    let projectedSpaceByDisplay: [DisplayID: SpaceID]
    let lastSpaceByDisplay: [DisplayID: SpaceID]

    func projectedTopology(for displayID: DisplayID) -> DisplayTopology? {
        guard
            let topology = snapshot?.topologiesByDisplay[displayID],
            let projectedSpaceID = projectedSpaceByDisplay[displayID]
        else {
            return snapshot?.topologiesByDisplay[displayID]
        }

        return DisplayTopology(
            displayID: topology.displayID,
            spaceIDs: topology.spaceIDs,
            currentSpaceID: projectedSpaceID
        )
    }
}

nonisolated enum SpaceSwitchAction: Equatable, Sendable {
    case step(SpaceSwitchDirection)
    case index(Int)
    case lastSpace
}

nonisolated enum SpaceInputSource: String, Equatable, Sendable {
    case gesture
    case hotkey
    case menu
}

nonisolated struct SpaceSwitchRequest: Equatable, Sendable {
    let action: SpaceSwitchAction
    let source: SpaceInputSource
    let targetDisplayID: DisplayID
    let wraps: Bool
    let velocity: Double
    let requiredMode: SpaceSwitchMode?
    /// The semantic target captured when a `lastSpace` input is accepted.
    let resolvedLastSpaceID: SpaceID?

    init(
        action: SpaceSwitchAction,
        source: SpaceInputSource,
        targetDisplayID: DisplayID,
        wraps: Bool,
        velocity: Double,
        requiredMode: SpaceSwitchMode? = nil,
        resolvedLastSpaceID: SpaceID? = nil
    ) {
        self.action = action
        self.source = source
        self.targetDisplayID = targetDisplayID
        self.wraps = wraps
        self.velocity = velocity
        self.requiredMode = requiredMode
        self.resolvedLastSpaceID = resolvedLastSpaceID
    }
}

nonisolated enum SpaceSwitchOutcome: Equatable, Sendable {
    case accepted
    case alreadyAtTarget
    case unavailable
    case missionControlSyntheticUnavailable
    case blockedAtEdge
    case invalidTarget
}
