import Carbon.HIToolbox
import Foundation

@MainActor
final class HotkeyRegistry {
    enum EventKind {
        case keyUp
        case keyDown
    }

    private final class Registration {
        let eventKind: EventKind
        let handler: () -> Void
        let reference: EventHotKeyRef

        init(
            eventKind: EventKind,
            handler: @escaping () -> Void,
            reference: EventHotKeyRef
        ) {
            self.eventKind = eventKind
            self.handler = handler
            self.reference = reference
        }
    }

    private static let signature: OSType = 0x424C4E4B // BLNK

    private var registrations: [UInt32: Registration] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    deinit {
        MainActor.assumeIsolated {
            registrations.values.forEach {
                UnregisterEventHotKey($0.reference)
            }
            if let eventHandler {
                RemoveEventHandler(eventHandler)
            }
        }
    }

    func register(
        hotkey: Hotkey,
        eventKind: EventKind,
        handler: @escaping () -> Void
    ) -> UInt32? {
        guard let keyCombination = hotkey.keyCombination else {
            Logger.hotkeyRegistry.error("Hotkey does not have a valid key combination")
            return nil
        }
        guard installHandlerIfNeeded() else {
            return nil
        }

        let id = nextID
        nextID &+= 1
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCombination.key.rawValue),
            UInt32(keyCombination.modifiers.carbonFlags),
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &reference
        )

        guard status == noErr, let reference else {
            Logger.hotkeyRegistry.error(
                "Hotkey registration failed with status \(status)"
            )
            return nil
        }

        registrations[id] = Registration(
            eventKind: eventKind,
            handler: handler,
            reference: reference
        )
        return id
    }

    func unregister(_ id: UInt32) {
        guard let registration = registrations.removeValue(forKey: id) else {
            Logger.hotkeyRegistry.error("No registered key combination for id \(id)")
            return
        }

        let status = UnregisterEventHotKey(registration.reference)
        if status != noErr {
            Logger.hotkeyRegistry.error(
                "Hotkey unregistration failed with status \(status)"
            )
        }
    }

    private func installHandlerIfNeeded() -> Bool {
        guard eventHandler == nil else { return true }

        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            handleCarbonHotkey,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        guard status == noErr else {
            Logger.hotkeyRegistry.error(
                "Hotkey event handler installation failed with status \(status)"
            )
            return false
        }
        return true
    }

    fileprivate func handle(_ event: EventRef) -> OSStatus {
        var hotkeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotkeyID
        )
        guard
            status == noErr,
            hotkeyID.signature == Self.signature,
            let registration = registrations[hotkeyID.id]
        else {
            return OSStatus(eventNotHandledErr)
        }

        let kind = GetEventKind(event)
        let expectedKind: UInt32 = registration.eventKind == .keyDown
            ? UInt32(kEventHotKeyPressed)
            : UInt32(kEventHotKeyReleased)
        guard kind == expectedKind else {
            return OSStatus(eventNotHandledErr)
        }

        registration.handler()
        return noErr
    }
}

private nonisolated func handleCarbonHotkey(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else {
        return OSStatus(eventNotHandledErr)
    }

    let registry = Unmanaged<HotkeyRegistry>
        .fromOpaque(userData)
        .takeUnretainedValue()
    return MainActor.assumeIsolated {
        registry.handle(event)
    }
}

extension Logger {
    fileprivate static let hotkeyRegistry = Logger(category: "HotkeyRegistry")
}
