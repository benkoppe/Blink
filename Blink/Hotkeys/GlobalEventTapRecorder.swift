//
//  GlobalEventTapRecorder.swift
//  Blink
//
//  Created by Ben on 3/24/26.
//

import AppKit
import Carbon

/// Installs a session-level CGEvent tap that intercepts all key and mouse input globally.
final class GlobalEventTapRecorder {
    static let shared = GlobalEventTapRecorder()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onKeyPress: ((NSEvent) -> Void)?
    private var onMouseClick: (() -> Void)?

    private init() {}

    func startRecording(
        onKeyPress: @escaping (NSEvent) -> Void,
        onMouseClick: @escaping () -> Void
    ) {
        stopRecording()

        self.onKeyPress = onKeyPress
        self.onMouseClick = onMouseClick

        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let recorder = Unmanaged<GlobalEventTapRecorder>
                        .fromOpaque(userInfo)
                        .takeUnretainedValue()

                    if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
                    {
                        recorder.onMouseClick?()
                        return nil
                    }

                    if let nsEvent = NSEvent(cgEvent: event) {
                        recorder.onKeyPress?(nsEvent)
                    }

                    return nil
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            print(
                "GlobalEventTapRecorder: failed to create event tap - Accessibility permission required"
            )
            return
        }

        self.eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stopRecording() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            self.eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            self.runLoopSource = nil
        }
        onKeyPress = nil
        onMouseClick = nil
    }
}
