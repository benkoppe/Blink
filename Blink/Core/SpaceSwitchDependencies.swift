import CoreGraphics

nonisolated protocol SpaceSystemClient: Sendable {
    func loadSnapshot() throws -> SystemSpaceSnapshot
}

nonisolated protocol DisplayLocating: Sendable {
    func cursorDisplayID() throws -> DisplayID
    func bounds(for displayID: DisplayID) -> CGRect?
}

nonisolated protocol OverlayDetecting: Sendable {
    func detect(on displayID: DisplayID) -> OverlayMode
}

nonisolated protocol SpaceGesturePosting: Sendable {
    func postStep(
        mode: SpaceSwitchMode,
        direction: SpaceSwitchDirection,
        velocity: Double
    ) -> Bool
}
