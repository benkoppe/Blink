//
//  SwipeGesture.swift
//  Blink
//
//  Created by Ben on 3/31/26.
//

import Foundation
import Observation

enum SwipeDirection: String, Codable, Hashable {
    case left, right
}

struct SwipeGestureID: Codable, Hashable {
    var direction: SwipeDirection
    var fingerCount: Int

    /// UserDefaults persistence key for this slot.
    var defaultsKey: String { "swipe.\(direction.rawValue).\(fingerCount)" }

    var defaultAction: BoundAction? {
        switch (direction, fingerCount) {
        case (.left, 3): return .left
        case (.right, 3): return .right
        default: return nil
        }
    }

    static let allSlots: [SwipeGestureID] = [
        .init(direction: .left, fingerCount: 3),
        .init(direction: .right, fingerCount: 3),
        .init(direction: .left, fingerCount: 4),
        .init(direction: .right, fingerCount: 4),
    ]
}

@Observable
final class SwipeGesture {
    let id: SwipeGestureID
    var action: BoundAction?

    init(id: SwipeGestureID, action: BoundAction?) {
        self.id = id
        self.action = action
    }
}
