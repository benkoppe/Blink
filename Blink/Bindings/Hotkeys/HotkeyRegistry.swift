//
//  HotkeyRegistry.swift
//  Blink
//
//  Created by Ben on 3/25/26.
//

import Carbon.HIToolbox
import Cocoa

/// An object that manages the registration, storage, and unregistration of hotkeys.
@MainActor
final class HotkeyRegistry {
    /// The event kinds that a hotkey can be registered for.
    enum EventKind {
        case keyUp
        case keyDown

        fileprivate init?(event: EventRef) {
            switch Int(GetEventKind(event)) {
            case kEventHotKeyPressed:
                self = .keyDown
            case kEventHotKeyReleased:
                self = .keyUp
            default:
                return nil
            }
        }
    }

    /// An object that stores the information needed to cancel a registration.
    private final class Registration {
        let eventKind: EventKind
        let key: KeyCode
        let modifiers: Modifiers
        let handler: () -> Void

        init(
            eventKind: EventKind,
            key: KeyCode,
            modifiers: Modifiers,
            handler: @escaping () -> Void
        ) {
            self.eventKind = eventKind
            self.key = key
            self.modifiers = modifiers
            self.handler = handler
        }
    }

    private var registrations = [UInt32: Registration]()

    private var keyEventTap: EventTap?

    /// Installs the global event tap, if it isn't already.
    private func installIfNeeded() -> OSStatus {
        guard keyEventTap == nil else {
            return noErr
        }

        let tap = EventTap(
            label: "HotkeyRegistry",
            options: .defaultTap,
            location: .hidEventTap,
            place: .headInsertEventTap,
            types: [.keyDown],
            callback: { [weak self] proxy, type, event in
                guard let self else { return event }

                switch type {
                case .tapDisabledByTimeout, .tapDisabledByUserInput:
                    proxy.enable()
                    return event

                case .keyDown:
                    return self.handleKeyDownEvent(event)

                default:
                    return event
                }
            }
        )
        tap.enable()
        keyEventTap = tap

        return tap.isEnabled ? noErr : OSStatus(eventNotHandledErr)
    }

    /// Registers the given hotkey for the given event kind and returns the
    /// identifier of the registration on success.
    ///
    /// The returned identifier can be used to unregister the hotkey using
    /// the ``unregister(_:)`` function.
    ///
    /// - Parameters:
    ///   - hotkey: The hotkey to register the handler with.
    ///   - eventKind: The event kind to register the handler with.
    ///   - handler: The handler to perform when `hotkey` is triggered with
    ///     the event kind specified by `eventKind`.
    ///
    /// - Returns: The registration's identifier on success, `nil` on failure.
    func register(
        hotkey: Hotkey,
        eventKind: EventKind,
        handler: @escaping () -> Void
    ) -> UInt32? {
        enum Context {
            static var currentID: UInt32 = 0
        }

        defer {
            Context.currentID += 1
        }

        guard let keyCombination = hotkey.keyCombination else {
            Logger.hotkeyRegistry.error("Hotkey does not have a valid key combination")
            return nil
        }

        let status = installIfNeeded()

        guard status == noErr else {
            Logger.hotkeyRegistry.error(
                "Hotkey event tap installation failed with status \(status)")
            return nil
        }

        let id = Context.currentID

        guard registrations[id] == nil else {
            Logger.hotkeyRegistry.error("Hotkey already registered for id \(id)")
            return nil
        }

        let registration = Registration(
            eventKind: eventKind,
            key: keyCombination.key,
            modifiers: keyCombination.modifiers,
            handler: handler
        )
        registrations[id] = registration

        return id
    }

    /// Unregisters the key combination with the given identifier.
    ///
    /// - Parameter id: An identifier returned from a call to the
    ///   ``register(hotkey:eventKind:handler:)`` function.
    func unregister(_ id: UInt32) {
        guard registrations.removeValue(forKey: id) != nil else {
            Logger.hotkeyRegistry.error("No registered key combination for id \(id)")
            return
        }
    }

    private func handleKeyDownEvent(_ event: CGEvent) -> CGEvent? {
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let key = KeyCode(rawValue: Int(event.getIntegerValueField(.keyboardEventKeycode)))
        let modifiers = Modifiers(cgEventFlags: event.flags)

        guard
            let registration = registrations.values.first(where: {
                $0.eventKind == .keyDown && $0.key == key && $0.modifiers == modifiers
            })
        else {
            return event
        }

        guard !isAutorepeat else {
            return nil
        }

        registration.handler()
        return nil
    }
}

// MARK: - Logger
extension Logger {
    fileprivate static let hotkeyRegistry = Logger(category: "HotkeyRegistry")
}
