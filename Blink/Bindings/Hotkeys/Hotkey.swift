import Observation

enum HotkeyRegistrationFailure: Equatable {
    case duplicateBinding(conflictingActions: [BoundAction])
    case monitoringUnavailable(HotkeyMonitoringFailure)
    case registryConflict

    var description: String {
        switch self {
        case .duplicateBinding(let actions):
            let names = actions.map(\.displayName).joined(separator: ", ")
            return "This shortcut is also configured for \(names). Duplicate shortcuts are disabled."
        case .monitoringUnavailable(let reason):
            return reason.description
        case .registryConflict:
            return "This shortcut conflicts with another registered Blink shortcut."
        }
    }
}

enum HotkeyRegistrationState: Equatable {
    case disabled
    case active
    case failed(HotkeyRegistrationFailure)
}

@Observable
final class Hotkey: Codable, Equatable, Hashable {
    let action: BoundAction
    var keyCombination: KeyCombination?

    /// Whether the user has assigned a combination. This says nothing about
    /// whether the shared event tap is currently operational.
    var isConfigured: Bool {
        keyCombination != nil
    }

    private(set) var registrationState: HotkeyRegistrationState = .disabled

    init(keyCombination: KeyCombination?, action: BoundAction) {
        self.keyCombination = keyCombination
        self.action = action
    }

    func setRegistrationState(_ state: HotkeyRegistrationState) {
        registrationState = state
    }

    private enum CodingKeys: CodingKey {
        case keyCombination
        case action
    }

    convenience init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            keyCombination: container.decode(KeyCombination?.self, forKey: .keyCombination),
            action: container.decode(BoundAction.self, forKey: .action)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCombination, forKey: .keyCombination)
        try container.encode(action, forKey: .action)
    }

    static func == (lhs: Hotkey, rhs: Hotkey) -> Bool {
        lhs.keyCombination == rhs.keyCombination && lhs.action == rhs.action
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCombination)
        hasher.combine(action)
    }
}
