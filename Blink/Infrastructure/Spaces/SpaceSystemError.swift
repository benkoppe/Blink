nonisolated enum CGSSpaceParsingError: Error, Equatable, Sendable {
    case emptyDisplayList
    case invalidDisplayEntry(index: Int)
    case invalidDisplayIdentifier(index: Int)
    case duplicateDisplayIdentifier(ManagedDisplayID)
    case ambiguousSharedTopology
    case invalidSpaces(index: Int)
    case invalidSpaceEntry(displayIndex: Int, spaceIndex: Int)
    case invalidSpaceID(displayIndex: Int, spaceIndex: Int)
    case duplicateSpaceID(displayIndex: Int, SpaceID)
    case invalidCurrentSpace(displayIndex: Int)
    case invalidCurrentSpaceID(displayIndex: Int)
    case currentSpaceOutsideTopology(displayIndex: Int, SpaceID)
    case invalidGlobalActiveSpaceID
}

nonisolated enum SpaceSystemError: Error, Equatable, Sendable {
    case requiredSymbolUnavailable(String)
    case invalidConnection
    case unavailableSpaceList
    case noValidDisplays
    case malformedSpaceList(CGSSpaceParsingError)
    case cursorDisplayUnavailable
}
