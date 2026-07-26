import Foundation

nonisolated enum PhysicalContactTransition: Equatable, Sendable {
    case began(id: UInt64)
    case ended(id: UInt64)
    case sample(id: UInt64)
}

/// Tracks physical identity independently from Dock's gesture segments. An
/// inactivity expiry quarantines the last identities until terminal evidence or
/// a disjoint set arrives, so delayed samples cannot become a second contact.
nonisolated struct PhysicalContactLifetimeState: Equatable, Sendable {
    private enum State: Equatable, Sendable {
        case idle
        case active(id: UInt64, identities: Set<String>, activityToken: UInt64)
        case quarantined(identities: Set<String>)
    }

    private var state: State = .idle
    private var nextID: UInt64 = 0
    private var nextActivityToken: UInt64 = 0

    var activeID: UInt64? {
        guard case .active(let id, _, _) = state else { return nil }
        return id
    }

    var activityToken: UInt64? {
        guard case .active(_, _, let token) = state else { return nil }
        return token
    }

    var isQuarantined: Bool {
        if case .quarantined = state { return true }
        return false
    }

    mutating func consume(_ sample: GestureSample) -> [PhysicalContactTransition] {
        guard !sample.touches.isEmpty else { return [] }
        let activeIdentities = Set(
            sample.touches.lazy.filter { !$0.isEnded }.map(\.identity)
        )

        guard !activeIdentities.isEmpty else {
            switch state {
            case .active(let id, _, _):
                state = .idle
                return [.ended(id: id)]
            case .quarantined:
                state = .idle
            case .idle:
                break
            }
            return []
        }

        switch state {
        case .idle:
            return begin(identities: activeIdentities)
        case .active(let id, let previous, _):
            if previous.isDisjoint(with: activeIdentities) {
                let ended = PhysicalContactTransition.ended(id: id)
                return [ended] + begin(identities: activeIdentities)
            }
            nextActivityToken &+= 1
            state = .active(
                id: id,
                identities: activeIdentities,
                activityToken: nextActivityToken
            )
            return [.sample(id: id)]
        case .quarantined(let identities):
            guard identities.isDisjoint(with: activeIdentities) else { return [] }
            return begin(identities: activeIdentities)
        }
    }

    mutating func expire(activityToken: UInt64) -> PhysicalContactTransition? {
        guard case .active(let id, let identities, let currentToken) = state,
            currentToken == activityToken
        else {
            return nil
        }
        state = .quarantined(identities: identities)
        return .ended(id: id)
    }

    mutating func interrupt() -> PhysicalContactTransition? {
        guard case .active(let id, let identities, _) = state else { return nil }
        state = .quarantined(identities: identities)
        return .ended(id: id)
    }

    mutating func finish() -> PhysicalContactTransition? {
        guard case .active(let id, _, _) = state else { return nil }
        state = .idle
        return .ended(id: id)
    }

    mutating func reset() {
        state = .idle
    }

    private mutating func begin(
        identities: Set<String>
    ) -> [PhysicalContactTransition] {
        nextID &+= 1
        nextActivityToken &+= 1
        state = .active(
            id: nextID,
            identities: identities,
            activityToken: nextActivityToken
        )
        return [.began(id: nextID), .sample(id: nextID)]
    }
}
