//
//  HotkeyManager.swift
//  Blink
//
//  Created by Ben on 3/24/26.
//

import AppKit
import Carbon

final class HotkeyManager {
    static let shared = HotkeyManager()

    private struct Registration {
        let id: UInt32
        var reference: EventHotKeyRef?
    }

    private var handlers: [UInt32: () -> Void] = [:]
    private var registrations: [BoundAction: Registration] = [:]
    private var currentId: UInt32 = 1

    private init() {
        installEventHandler()
    }

    func register(
        action: BoundAction,
        combination: HotkeyCombination,
        handler: @escaping () -> Void
    ) {
        unregister(action: action)

        let id = currentId
        currentId &+= 1

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: 0x1111, id: id)
        let status = RegisterEventHotKey(
            combination.keyCode,
            combination.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr else {
            print("HotKeymanager: failed to register \(action) - status \(status)")
            return
        }

        handlers[id] = handler
        registrations[action] = Registration(id: id, reference: hotKeyRef)
    }

    func unregister(action: BoundAction) {
        guard let registration = registrations.removeValue(forKey: action) else { return }
        handlers.removeValue(forKey: registration.id)
        if let reference = registration.reference {
            UnregisterEventHotKey(reference)
        }
    }

    func unregisterAll() {
        for (_, registration) in registrations {
            if let reference = registration.reference {
                UnregisterEventHotKey(reference)
            }
        }
        registrations.removeAll()
        handlers.removeAll()
    }

    private func installEventHandler() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, event, _) -> OSStatus in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                if let handler = HotkeyManager.shared.handlers[hotKeyID.id] {
                    handler()
                }
                return noErr
            },
            1,
            &eventSpec,
            nil,
            nil
        )
    }
}
