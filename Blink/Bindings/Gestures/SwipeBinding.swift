//
//  SwipeBinding.swift
//  Blink
//
//  Created by Ben on 3/24/26.
//

import Foundation

enum SwipeDirection: String, Codable, Hashable {
    case left, right
}

struct SwipeBindingID: Codable, Hashable {
    var direction: SwipeDirection
    var fingerCount: Int

    /// UserDefaults persistence key for this slot.
    var defaultsKey: String { "swipe.\(direction.rawValue).\(fingerCount)" }
}

struct SwipeBinding: Codable, Equatable {
    var action: BoundAction
    var isEnabled: Bool
}

extension SwipeBinding {
    static let defaultLeft3 = SwipeBinding(action: .left, isEnabled: true)
    static let defaultRight3 = SwipeBinding(action: .right, isEnabled: true)
    static let defaultLeft4 = SwipeBinding(action: .left, isEnabled: false)
    static let defaultRight4 = SwipeBinding(action: .right, isEnabled: false)
}
