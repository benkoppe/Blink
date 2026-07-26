import Foundation

nonisolated enum GestureRoute: String, Equatable, Sendable {
    case blink
    case system
}

nonisolated struct GestureSessionContext: Equatable, Sendable {
    let generation: UInt64
    let route: GestureRoute
    let targetDisplayID: DisplayID
    let capturedOverlayMode: OverlayMode
    let missionControlSyntheticState: MissionControlSyntheticState
    let requiredPostingMode: SpaceSwitchMode?

    var isAuthoritativeBlinkContext: Bool {
        guard route == .blink else { return false }
        switch (capturedOverlayMode, requiredPostingMode) {
        case (.none, .instant), (.missionControl, .missionControl):
            return missionControlSyntheticState == .available
                || requiredPostingMode == .instant
        default:
            return false
        }
    }

    func isValidForDispatch(
        currentDisplayID: DisplayID?,
        currentMissionControlSyntheticState: MissionControlSyntheticState
    ) -> Bool {
        guard
            isAuthoritativeBlinkContext,
            currentDisplayID == targetDisplayID
        else {
            return false
        }
        return requiredPostingMode != .missionControl
            || currentMissionControlSyntheticState == .available
    }

    static func observed(
        generation: UInt64,
        targetDisplayID: DisplayID,
        overlayMode: OverlayMode,
        missionControlSyntheticState: MissionControlSyntheticState
    ) -> GestureSessionContext {
        let postingMode: SpaceSwitchMode? =
            switch overlayMode {
            case .none:
                .instant
            case .missionControl where missionControlSyntheticState == .available:
                .missionControl
            case .missionControl, .appExpose, .unknown:
                nil
            }
        return GestureSessionContext(
            generation: generation,
            route: postingMode == nil ? .system : .blink,
            targetDisplayID: targetDisplayID,
            capturedOverlayMode: overlayMode,
            missionControlSyntheticState: missionControlSyntheticState,
            requiredPostingMode: postingMode
        )
    }

    static func system(
        generation: UInt64,
        targetDisplayID: DisplayID,
        missionControlSyntheticState: MissionControlSyntheticState
    ) -> GestureSessionContext {
        GestureSessionContext(
            generation: generation,
            route: .system,
            targetDisplayID: targetDisplayID,
            capturedOverlayMode: .unknown,
            missionControlSyntheticState: missionControlSyntheticState,
            requiredPostingMode: nil
        )
    }
}
