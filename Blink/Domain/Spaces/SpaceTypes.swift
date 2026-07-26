import Foundation

nonisolated struct DisplayID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }
}

nonisolated struct ManagedDisplayID: RawRepresentable, Hashable, Codable, Sendable {
    static let main = ManagedDisplayID(rawValue: "Main")!

    let rawValue: String

    init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    var isMain: Bool { self == .main }
}

nonisolated struct SpaceID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: UInt64

    init?(rawValue: UInt64) {
        guard rawValue != 0 else { return nil }
        self.rawValue = rawValue
    }
}

nonisolated struct DisplayTopology: Equatable, Sendable {
    let managedDisplayID: ManagedDisplayID
    let spaceIDs: [SpaceID]
    let currentSpaceID: SpaceID

    init?(
        managedDisplayID: ManagedDisplayID,
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

        self.managedDisplayID = managedDisplayID
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
    let topologiesByManagedDisplay: [ManagedDisplayID: DisplayTopology]
    let menuBarDisplayID: DisplayID?

    func managedDisplayID(for physicalDisplayID: DisplayID) -> ManagedDisplayID? {
        if topologiesByManagedDisplay.count == 1,
            topologiesByManagedDisplay[.main] != nil
        {
            return .main
        }

        let managedDisplayID = ManagedDisplayID(rawValue: physicalDisplayID.rawValue)!
        return topologiesByManagedDisplay[managedDisplayID] == nil ? nil : managedDisplayID
    }

    func topology(for physicalDisplayID: DisplayID) -> DisplayTopology? {
        managedDisplayID(for: physicalDisplayID)
            .flatMap { topologiesByManagedDisplay[$0] }
    }

    var menuBarTopology: DisplayTopology? {
        if let menuBarDisplayID {
            return topology(for: menuBarDisplayID)
        }
        if topologiesByManagedDisplay.count == 1 {
            return topologiesByManagedDisplay[.main]
        }
        return nil
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
    let projectedSpaceByManagedDisplay: [ManagedDisplayID: SpaceID]
    let lastSpaceByManagedDisplay: [ManagedDisplayID: SpaceID]

    func projectedTopology(for managedDisplayID: ManagedDisplayID) -> DisplayTopology? {
        guard
            let topology = snapshot?.topologiesByManagedDisplay[managedDisplayID],
            let projectedSpaceID = projectedSpaceByManagedDisplay[managedDisplayID]
        else {
            return snapshot?.topologiesByManagedDisplay[managedDisplayID]
        }

        return DisplayTopology(
            managedDisplayID: topology.managedDisplayID,
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

    init(
        action: SpaceSwitchAction,
        source: SpaceInputSource,
        targetDisplayID: DisplayID,
        wraps: Bool,
        velocity: Double,
        requiredMode: SpaceSwitchMode? = nil
    ) {
        self.action = action
        self.source = source
        self.targetDisplayID = targetDisplayID
        self.wraps = wraps
        self.velocity = velocity
        self.requiredMode = requiredMode
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
