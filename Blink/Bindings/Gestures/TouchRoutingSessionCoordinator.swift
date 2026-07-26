/// Binds one immutable ownership decision to a physical trackpad contact
/// session. Dock can announce its first segment before or after HID reports the
/// touches, so a decision may be provisional until the HID session ID arrives.
nonisolated struct TouchRoutingSessionCoordinator: Sendable {
    private enum Decision: Sendable {
        case undecided
        /// `nil` is an explicit fail-open decision, not missing state.
        case decided(GestureSessionContext?)
    }

    private enum State: Sendable {
        case idle
        case provisional(GestureSessionContext?)
        case active(id: UInt64, decision: Decision)
    }

    private var state: State = .idle

    var hasOwnershipDecision: Bool {
        switch state {
        case .provisional, .active(_, .decided): return true
        case .idle, .active(_, .undecided): return false
        }
    }

    var selectedContext: GestureSessionContext? {
        switch state {
        case .provisional(let context), .active(_, .decided(let context)):
            context
        case .idle, .active(_, .undecided):
            nil
        }
    }

    mutating func beginTouchSession(id: UInt64) {
        switch state {
        case .provisional(let context):
            state = .active(id: id, decision: .decided(context))
        case .idle, .active:
            state = .active(id: id, decision: .undecided)
        }
    }

    mutating func bindContext(_ context: GestureSessionContext?) {
        switch state {
        case .idle:
            state = .provisional(context)
        case .active(let id, .undecided):
            state = .active(id: id, decision: .decided(context))
        case .provisional, .active(_, .decided):
            break
        }
    }

    @discardableResult
    mutating func endTouchSession(id: UInt64) -> Bool {
        guard case .active(id: let activeID, decision: _) = state,
            activeID == id
        else {
            return false
        }
        state = .idle
        return true
    }

    mutating func interrupt() {
        state = .idle
    }
}
