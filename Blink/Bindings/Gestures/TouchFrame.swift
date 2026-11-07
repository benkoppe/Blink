//
//  TouchFrame.swift
//  Blink
//

import AppKit
import CoreGraphics

/// The fingers touching the trackpad in one gesture event.
struct TouchFrame {
    struct Contact {
        let id: Int
        let position: CGPoint
    }

    let contacts: [Contact]
}

extension TouchFrame {
    /// Reads the fingers carried by a gesture event, or `nil` when the event
    /// carries no finger data, such as a Force Touch pressure event.
    ///
    /// This reads the digitizer data embedded in the event. AppKit's
    /// `allTouches()` depends on touch state that AppKit tracks per process, and
    /// in a long-running process that state can stop reporting any touches.
    init?(_ event: CGEvent) {
        switch DigitizerReader.shared?.read(event) ?? .unavailable {
        case .fingers(let contacts):
            self.init(contacts: contacts)
        case .noFingerData:
            return nil
        case .unavailable:
            self.init(appKitEvent: event)
        }
    }

    private init?(appKitEvent event: CGEvent) {
        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.type == .gesture else { return nil }
        contacts = nsEvent.allTouches()
            .filter { $0.phase != .ended && $0.phase != .cancelled }
            .map { Contact(id: $0.identity.hash, position: $0.normalizedPosition) }
    }
}

/// Reads per-finger records from the IOHID event embedded in a `CGEvent`.
private struct DigitizerReader {
    enum Reading {
        case fingers([TouchFrame.Contact])
        case noFingerData
        case unavailable
    }

    private typealias CopyEvent = @convention(c) (CGEvent) -> Unmanaged<CFTypeRef>?
    private typealias GetType = @convention(c) (CFTypeRef) -> UInt32
    private typealias GetChildren = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias GetInteger = @convention(c) (CFTypeRef, UInt32) -> Int
    private typealias GetFloat = @convention(c) (CFTypeRef, UInt32) -> Double

    private static let digitizerType: UInt32 = 11
    private static let xField = digitizerType << 16 | 0
    private static let yField = digitizerType << 16 | 1
    // Field 6, the identity, changes between frames. The path index stays fixed per finger.
    private static let pathIndexField = digitizerType << 16 | 5
    private static let touchField = digitizerType << 16 | 9

    static let shared = DigitizerReader()

    private let copyEvent: CopyEvent
    private let getType: GetType
    private let getChildren: GetChildren
    private let getInteger: GetInteger
    private let getFloat: GetFloat

    private init?() {
        guard
            let coreGraphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
            let ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
            let copyEvent = dlsym(coreGraphics, "CGEventCopyIOHIDEvent"),
            let getType = dlsym(ioKit, "IOHIDEventGetType"),
            let getChildren = dlsym(ioKit, "IOHIDEventGetChildren"),
            let getInteger = dlsym(ioKit, "IOHIDEventGetIntegerValue"),
            let getFloat = dlsym(ioKit, "IOHIDEventGetFloatValue")
        else { return nil }

        self.copyEvent = unsafeBitCast(copyEvent, to: CopyEvent.self)
        self.getType = unsafeBitCast(getType, to: GetType.self)
        self.getChildren = unsafeBitCast(getChildren, to: GetChildren.self)
        self.getInteger = unsafeBitCast(getInteger, to: GetInteger.self)
        self.getFloat = unsafeBitCast(getFloat, to: GetFloat.self)
    }

    func read(_ event: CGEvent) -> Reading {
        guard let hidEvent = copyEvent(event)?.takeRetainedValue() else { return .unavailable }
        guard getType(hidEvent) == Self.digitizerType else { return .noFingerData }

        let children = getChildren(hidEvent)?.takeUnretainedValue() as? [CFTypeRef] ?? []
        return .fingers(
            children
                .filter { getType($0) == Self.digitizerType && getInteger($0, Self.touchField) != 0 }
                .map {
                    TouchFrame.Contact(
                        id: getInteger($0, Self.pathIndexField),
                        position: CGPoint(x: getFloat($0, Self.xField), y: getFloat($0, Self.yField))
                    )
                }
        )
    }
}
