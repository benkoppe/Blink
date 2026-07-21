import AppKit
import CoreGraphics
import Foundation

nonisolated protocol DisplayLocating: Sendable {
    func cursorDisplayID() throws -> DisplayID
    func bounds(for displayID: DisplayID) -> CGRect?
}

nonisolated struct DisplayLocator: DisplayLocating, Sendable {
    func cursorDisplayID() throws -> DisplayID {
        guard let event = CGEvent(source: nil) else {
            throw SpaceSystemError.cursorDisplayUnavailable
        }

        var displayID: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard
            CGGetDisplaysWithPoint(event.location, 1, &displayID, &count) == .success,
            count > 0,
            let value = identifier(for: displayID)
        else {
            throw SpaceSystemError.cursorDisplayUnavailable
        }

        return value
    }

    func bounds(for displayID: DisplayID) -> CGRect? {
        var capacity: UInt32 = 0
        guard
            CGGetOnlineDisplayList(0, nil, &capacity) == .success,
            capacity > 0
        else {
            return nil
        }

        var displays = Array(repeating: CGDirectDisplayID(), count: Int(capacity))
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(capacity, &displays, &count) == .success else {
            return nil
        }

        for candidate in displays.prefix(Int(count))
        where identifier(for: candidate) == displayID {
            return CGDisplayBounds(candidate)
        }

        return nil
    }

    private func identifier(for displayID: CGDirectDisplayID) -> DisplayID? {
        guard
            let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
            let value = CFUUIDCreateString(nil, uuid) as String?
        else {
            return nil
        }

        return DisplayID(rawValue: value)
    }
}
