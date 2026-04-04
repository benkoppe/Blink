//
//  MenuKeyDispatcher.swift
//  Blink
//
//  Created by Ben on 4/4/26.
//

import AppKit
import Observation
import SwiftUI

// Dispatches local keyboard events to registered menu commands while the
/// menu popover is open.
@Observable @MainActor
final class MenuKeyDispatcher {
    struct Registration {
        let id: UUID
        let key: KeyCode
        let modifiers: Modifiers
        let isEnabled: Bool
        let action: () -> Void
    }

    var isMenuPresented: Bool = false {
        didSet {
            if isMenuPresented {
                startMonitoring()
            } else {
                stopMonitoring()
            }
        }
    }

    private var registrations: [Registration] = []
    private var monitor: LocalEventMonitor?

    func register(_ registration: Registration) {
        // Replace any existing registration with the same id (e.g. on re-render)
        registrations.removeAll { $0.id == registration.id }
        registrations.append(registration)
    }

    func unregister(id: UUID) {
        registrations.removeAll { $0.id == id }
    }

    private func startMonitoring() {
        guard monitor == nil else { return }

        monitor = LocalEventMonitor(mask: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        monitor?.start()
    }

    private func stopMonitoring() {
        monitor?.stop()
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let pressedKey = KeyCode(rawValue: Int(event.keyCode))
        let pressedMods = Modifiers(
            nsEventFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask))

        for registration in registrations {
            guard registration.isEnabled else { continue }
            if registration.key == pressedKey && registration.modifiers == pressedMods {
                registration.action()
                return nil  // consume the event
            }
        }
        return event
    }
}

private struct MenuIsPresentedKey: EnvironmentKey {
    static let defaultValue: Binding<Bool>? = nil
}

extension EnvironmentValues {
    var menuIsPresented: Binding<Bool>? {
        get { self[MenuIsPresentedKey.self] }
        set { self[MenuIsPresentedKey.self] = newValue }
    }
}
