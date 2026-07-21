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

nonisolated enum SpaceKind: Int, Codable, Sendable {
    case desktop = 0
    case fullscreen = 2
    case unknown = -1

    init(rawValueOrUnknown rawValue: Int?) {
        self = rawValue.flatMap(Self.init(rawValue:)) ?? .unknown
    }
}

nonisolated struct DisplayTopology: Equatable, Sendable {
    let displayID: DisplayID
    let spaceIDs: [SpaceID]
    let currentSpaceID: SpaceID
    let currentSpaceKind: SpaceKind

    init?(
        displayID: DisplayID,
        spaceIDs: [SpaceID],
        currentSpaceID: SpaceID,
        currentSpaceKind: SpaceKind
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
        self.currentSpaceKind = currentSpaceKind
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
    let frontmostBundleID: String?

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
            currentSpaceID: projectedSpaceID,
            currentSpaceKind: topology.currentSpaceKind
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
}

nonisolated enum SpaceSwitchOutcome: Equatable, Sendable {
    case accepted
    case alreadyAtTarget
    case unavailable
    case blockedAtEdge
    case invalidTarget
}

nonisolated enum SpaceSystemError: Error, Equatable, Sendable {
    case requiredSymbolUnavailable(String)
    case invalidConnection
    case unavailableSpaceList
    case invalidDisplayRecord
    case noValidDisplays
    case cursorDisplayUnavailable
    case eventCreationFailed
}
