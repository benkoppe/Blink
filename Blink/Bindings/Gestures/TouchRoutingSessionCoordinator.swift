/// Joins physical HID contact and Dock segments while keeping one immutable
/// ownership decision for the contact. `nil` is an explicit fail-open decision.
nonisolated struct TouchRoutingSessionCoordinator: Sendable {
    private enum Decision: Sendable {
        case undecided
        case decided(GestureSessionContext?)
    }

    private struct PhysicalContact: Sendable {
        let id: UInt64
        let evidenceToken: UInt64
        var decision: Decision
    }

    private struct DockSegment: Sendable {
        let id: UInt64
        let evidenceToken: UInt64
        var decision: Decision
    }

    private var physicalContact: PhysicalContact?
    private var dockSegment: DockSegment?

    var hasOwnershipDecision: Bool {
        switch physicalContact?.decision ?? dockSegment?.decision {
        case .decided: true
        case .undecided, nil: false
        }
    }

    var selectedContext: GestureSessionContext? {
        switch physicalContact?.decision ?? dockSegment?.decision {
        case .decided(let context): context
        case .undecided, nil: nil
        }
    }

    var currentEvidenceToken: UInt64? {
        physicalContact?.evidenceToken ?? dockSegment?.evidenceToken
    }

    @discardableResult
    mutating func beginTouchSession(id: UInt64, evidenceToken: UInt64) -> UInt64 {
        if let dockSegment {
            physicalContact = PhysicalContact(
                id: id,
                evidenceToken: dockSegment.evidenceToken,
                decision: dockSegment.decision
            )
            return dockSegment.evidenceToken
        }
        physicalContact = PhysicalContact(
            id: id,
            evidenceToken: evidenceToken,
            decision: .undecided
        )
        return evidenceToken
    }

    @discardableResult
    mutating func beginDockSegment(id: UInt64, evidenceToken: UInt64) -> UInt64 {
        let token = physicalContact?.evidenceToken ?? evidenceToken
        dockSegment = DockSegment(
            id: id,
            evidenceToken: token,
            decision: physicalContact?.decision ?? .undecided
        )
        return token
    }

    mutating func bindContext(
        _ context: GestureSessionContext?,
        evidenceToken: UInt64
    ) {
        if var contact = physicalContact,
            contact.evidenceToken == evidenceToken
        {
            if case .undecided = contact.decision {
                contact.decision = .decided(context)
                physicalContact = contact
                if var segment = dockSegment,
                    segment.evidenceToken == evidenceToken
                {
                    segment.decision = contact.decision
                    dockSegment = segment
                }
            }
            return
        }

        if var segment = dockSegment,
            segment.evidenceToken == evidenceToken,
            case .undecided = segment.decision
        {
            segment.decision = .decided(context)
            dockSegment = segment
        }
    }

    @discardableResult
    mutating func endTouchSession(id: UInt64) -> Bool {
        guard physicalContact?.id == id else { return false }
        physicalContact = nil
        if var segment = dockSegment {
            // A Dock segment that outlives finger-up cannot transfer the old
            // contact's destructive ownership to a subsequent contact.
            segment.decision = .decided(nil)
            dockSegment = segment
        }
        return true
    }

    @discardableResult
    mutating func endDockSegment(id: UInt64) -> Bool {
        guard dockSegment?.id == id else { return false }
        dockSegment = nil
        return true
    }

    mutating func interrupt() {
        physicalContact = nil
        dockSegment = nil
    }
}
