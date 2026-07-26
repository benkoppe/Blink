//
//  BoundAction.swift
//  Blink
//
//  Created by Ben on 3/24/26.
//

import Foundation

enum BoundAction: String, Codable, CaseIterable {
    case left, right, lastSpace
    case space1, space2, space3, space4, space5
    case space6, space7, space8, space9, space10

    var displayName: String {
        switch self {
        case .left: return "Switch Left"
        case .right: return "Switch Right"
        case .lastSpace: return "Last Space"
        case .space1: return "Space 1"
        case .space2: return "Space 2"
        case .space3: return "Space 3"
        case .space4: return "Space 4"
        case .space5: return "Space 5"
        case .space6: return "Space 6"
        case .space7: return "Space 7"
        case .space8: return "Space 8"
        case .space9: return "Space 9"
        case .space10: return "Space 10"
        }
    }

    var spaceSwitchAction: SpaceSwitchAction {
        switch self {
        case .left: .step(.left)
        case .right: .step(.right)
        case .lastSpace: .lastSpace
        case .space1: .index(0)
        case .space2: .index(1)
        case .space3: .index(2)
        case .space4: .index(3)
        case .space5: .index(4)
        case .space6: .index(5)
        case .space7: .index(6)
        case .space8: .index(7)
        case .space9: .index(8)
        case .space10: .index(9)
        }
    }
}

extension BoundAction {
    var defaultKeyCombination: KeyCombination? {
        let swipeModifiers: Modifiers = [.control]
        let jumpModifiers: Modifiers = [.control, .option]
        switch self {
        case .left: return .init(key: .leftArrow, modifiers: swipeModifiers)
        case .right: return .init(key: .rightArrow, modifiers: swipeModifiers)
        case .lastSpace: return .init(key: .grave, modifiers: jumpModifiers)
        case .space1: return .init(key: .one, modifiers: jumpModifiers)
        case .space2: return .init(key: .two, modifiers: jumpModifiers)
        case .space3: return KeyCombination(key: .three, modifiers: jumpModifiers)
        case .space4: return KeyCombination(key: .four, modifiers: jumpModifiers)
        case .space5: return KeyCombination(key: .five, modifiers: jumpModifiers)
        case .space6: return KeyCombination(key: .six, modifiers: jumpModifiers)
        case .space7: return KeyCombination(key: .seven, modifiers: jumpModifiers)
        case .space8: return KeyCombination(key: .eight, modifiers: jumpModifiers)
        case .space9: return KeyCombination(key: .nine, modifiers: jumpModifiers)
        case .space10: return KeyCombination(key: .zero, modifiers: jumpModifiers)
        }
    }

    static let indexedSpaceActions: [BoundAction] = [
        .space1, .space2, .space3, .space4, .space5,
        .space6, .space7, .space8, .space9, .space10,
    ]
}
