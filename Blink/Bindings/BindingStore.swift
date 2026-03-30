//
//  BindingStore.swift
//  Blink
//
//  Created by Ben on 3/24/26.
//

import AppKit
import Carbon
import Foundation
import Observation

@Observable
final class BindingStore {

    // MARK: - Swipe bindings

    private(set) var swipeBindings: [SwipeBindingID: SwipeBinding] = [:]

    // MARK: - Default swipe slots

    static let defaultSwipeSlots: [SwipeBindingID: SwipeBinding] = [
        SwipeBindingID(direction: .left, fingerCount: 3): .defaultLeft3,
        SwipeBindingID(direction: .right, fingerCount: 3): .defaultRight3,
        SwipeBindingID(direction: .left, fingerCount: 4): .defaultLeft4,
        SwipeBindingID(direction: .right, fingerCount: 4): .defaultRight4,
    ]

    private let defaults: UserDefaults

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        var states: [BoundAction: Bool] = [:]
        for action in BoundAction.allCases {
            states[action] =
                defaults.object(forKey: "enabled.\(action.rawValue)") as? Bool ?? true
        }

        var bindings: [SwipeBindingID: SwipeBinding] = [:]
        for (id, defaultBinding) in BindingStore.defaultSwipeSlots {
            bindings[id] = defaults.swipeBinding(forKey: id.defaultsKey) ?? defaultBinding
        }
        swipeBindings = bindings
    }

    // MARK: - Swipe binding read

    func swipeBinding(for id: SwipeBindingID) -> SwipeBinding? {
        swipeBindings[id]
    }

    // MARK: - Swipe binding write

    func updateSwipeBinding(_ binding: SwipeBinding, for id: SwipeBindingID) {
        guard swipeBindings[id] != binding else { return }
        swipeBindings[id] = binding
        defaults.setSwipeBinding(binding, forKey: id.defaultsKey)
    }

    func addSwipeBinding(_ binding: SwipeBinding, for id: SwipeBindingID) {
        swipeBindings[id] = binding
        defaults.setSwipeBinding(binding, forKey: id.defaultsKey)
    }

    func removeSwipeBinding(for id: SwipeBindingID) {
        swipeBindings.removeValue(forKey: id)
        defaults.removeObject(forKey: id.defaultsKey)
    }

    func resetSwipeBindingsToDefaults() {
        swipeBindings = BindingStore.defaultSwipeSlots
        for (id, binding) in BindingStore.defaultSwipeSlots {
            defaults.setSwipeBinding(binding, forKey: id.defaultsKey)
        }
    }
}

// MARK: - UserDefaults helpers
extension UserDefaults {
    fileprivate func swipeBinding(forKey key: String) -> SwipeBinding? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SwipeBinding.self, from: data)
    }

    fileprivate func setSwipeBinding(_ binding: SwipeBinding, forKey key: String) {
        if let data = try? JSONEncoder().encode(binding) {
            set(data, forKey: key)
        }
    }
}
