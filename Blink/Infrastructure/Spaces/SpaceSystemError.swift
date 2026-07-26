nonisolated enum SpaceSystemError: Error, Equatable, Sendable {
    case requiredSymbolUnavailable(String)
    case invalidConnection
    case unavailableSpaceList
    case noValidDisplays
    case cursorDisplayUnavailable
}
