import Observation

@Observable
final class Hotkey: Codable, Equatable, Hashable {
    let action: BoundAction
    var keyCombination: KeyCombination?

    var isEnabled: Bool {
        keyCombination != nil
    }

    init(keyCombination: KeyCombination?, action: BoundAction) {
        self.keyCombination = keyCombination
        self.action = action
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
