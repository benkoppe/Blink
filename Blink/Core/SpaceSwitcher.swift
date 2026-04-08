//
//  SpaceSwitcher.swift
//  Blink
//
//  Created by Ben on 3/24/26.
//

import AppKit
import CoreGraphics
import Darwin
import Observation

// MARK: - Private CGS function types
//
// These are private WindowServer APIs used to read the space layout. All four
// symbols live in CoreGraphics.framework (which re-exports them from SkyLight).
// We load them at runtime via dlopen/dlsym so the binary degrades gracefully
// if Apple removes them in a future OS version

private typealias CGSConnectionIDFn = @convention(c) () -> Int32
private typealias CGSGetAciveSpaceFn = @convention(c) (Int32) -> UInt64
private typealias CGSCopyDisplaySpacesFn =
    @convention(c) (Int32, CFString?) -> Unmanaged<CFArray>?
private typealias CGSCopyMenuBarDisplayFn =
    @convention(c) (Int32) -> Unmanaged<CFString>?

// MARK - Symbol loader

private struct CGSSymbols {
    let mainConnectionID: CGSConnectionIDFn
    let getActiveSpace: CGSGetAciveSpaceFn
    let copyDisplaySpaces: CGSCopyDisplaySpacesFn
    let copyMenuBarDisplayID: CGSCopyMenuBarDisplayFn?  // degrade gracefully if absent

    /// Load all symbols from CoreGraphics
    static func load() -> CGSSymbols? {
        let handle = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            0x4 | 0x1
        )

        func sym<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }

        guard
            let conn = sym("CGSMainConnectionID", as: CGSConnectionIDFn.self),
            let actv = sym("CGSGetActiveSpace", as: CGSGetAciveSpaceFn.self),
            let disp = sym(
                "CGSCopyManagedDisplaySpaces",
                as: CGSCopyDisplaySpacesFn.self
            )
        else {
            return nil
        }

        return CGSSymbols(
            mainConnectionID: conn,
            getActiveSpace: actv,
            copyDisplaySpaces: disp,
            copyMenuBarDisplayID: sym(
                "CGSCopyActiveMenuBarDisplayIdentifier",
                as: CGSCopyMenuBarDisplayFn.self
            )
        )
    }
}

// MARK: - Gesture event field constants
//
// These are private CGEventField indices observed via reverse-engineering
// of the synthetic Dock swipe trace. The values are stable across many
// macOS releases.

private enum GestureField {
    static let eventType = CGEventField(rawValue: 55)!
    static let hidType = CGEventField(rawValue: 110)!
    static let scrollY = CGEventField(rawValue: 119)!
    static let swipeMotion = CGEventField(rawValue: 123)!
    static let swipeProgress = CGEventField(rawValue: 124)!
    static let velocityX = CGEventField(rawValue: 129)!
    static let velocityY = CGEventField(rawValue: 130)!
    static let phase = CGEventField(rawValue: 132)!
    static let scrollFlags = CGEventField(rawValue: 135)!
    static let zoomDeltaX = CGEventField(rawValue: 139)!
}

// Raw integer values for the private CGS event type and gesture phase enums
private enum EventType {
    static let gesture: Int64 = 29
    static let dockControl: Int64 = 30
}
private enum Phase {
    static let began: Int64 = 1
    static let changed: Int64 = 2
    static let ended: Int64 = 4
}
private enum Motion { static let horizontal: Int64 = 1 }
private let kDockSwipeHIDType: Int64 = 23  // kIOHIDEventTypeDockSwipe

// For an unknown reason, this must be used as zoomDeltaX
private let kFltTrueMin = Double(Float.leastNonzeroMagnitude)

// MARK - SpaceInfo

struct SpaceInfo: Equatable {
    let currentIndex: Int
    let spaceCount: Int

    var displayNumber: Int { currentIndex + 1 }
    var isAtLeftEdge: Bool { currentIndex == 0 }
    var isAtRightEdge: Bool { currentIndex + 1 >= spaceCount }

    let currentSpaceID: UInt64?
    let currentSpaceType: Int?
    let displayIdentifier: String?
    let frontmostBundleID: String?

    var isNormalDesktopSpace: Bool { currentSpaceType == 0 }
    var isFullscreenSpace: Bool { currentSpaceType == 2 }

    var isKnownStandardSpace: Bool {
        isNormalDesktopSpace || isFullscreenSpace
    }
}

// MARK: - SpaceSwitcher

@Observable
final class SpaceSwitcher {
    /// The shared app state.
    private(set) weak var appState: AppState?

    private(set) var spaceInfo: SpaceInfo?

    private let symbols: CGSSymbols?

    private var spaceObserver: NSObjectProtocol?
    private var appObserver: NSObjectProtocol?
    private var screensWakeObserver: NSObjectProtocol?
    private var windowObserver: NSObjectProtocol?
    private var windowScreenObserver: NSObjectProtocol?
    private var screenParamsObserver: NSObjectProtocol?

    init(appState: AppState) {
        self.appState = appState

        symbols = CGSSymbols.load()

        refreshSpaceInfo()
        subscribeToWorkspaceNotifications()
    }

    deinit {
        let workspaceNC = NSWorkspace.shared.notificationCenter
        [spaceObserver, appObserver, screensWakeObserver].compactMap { $0 }.forEach {
            workspaceNC.removeObserver($0)
        }
        let defaultNC = NotificationCenter.default
        [windowObserver, windowScreenObserver, screenParamsObserver].compactMap { $0 }
            .forEach {
                defaultNC.removeObserver($0)
            }
    }

    // MARK: - Public interface

    @discardableResult
    func switchLeft() -> Bool { postGesture(.left) }

    @discardableResult
    func switchRight() -> Bool { postGesture(.right) }

    @discardableResult
    func switchToIndex(_ index: Int) -> Bool {
        guard let info = spaceInfo, info.spaceCount > 0 else { return false }
        let target = min(index, info.spaceCount - 1)
        guard target != info.currentIndex else {
            return index < info.spaceCount
        }
        let direction: Direction = target > info.currentIndex ? .right : .left
        let steps = abs(target - info.currentIndex)
        for _ in 0..<steps {
            guard postGesture(direction) else { return false }
        }
        return index < info.spaceCount
    }

    func canMoveLeft() -> Bool { spaceInfo.map { !$0.isAtLeftEdge } ?? false }
    func canMoveRight() -> Bool { spaceInfo.map { !$0.isAtRightEdge } ?? false }

    func refreshSpaceInfo() {
        // Use the menu-bar display for the icon (always correct on multi-monitor)
        spaceInfo = loadSpaceInfo(useCursorDisplay: false)
        // debugLogSpaceInfo()
    }

    // MARK - Workspace notifications

    private func subscribeToWorkspaceNotifications() {
        let workspaceNC = NSWorkspace.shared.notificationCenter
        spaceObserver = workspaceNC.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.refreshSpaceInfo() }

        appObserver = workspaceNC.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.refreshSpaceInfo() }

        screensWakeObserver = workspaceNC.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.refreshSpaceInfo() }

        let defaultNC = NotificationCenter.default
        windowObserver = defaultNC.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.refreshSpaceInfo() }

        windowScreenObserver = defaultNC.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.refreshSpaceInfo() }

        screenParamsObserver = defaultNC.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.refreshSpaceInfo() }
    }

    // MARK: - Space info loading

    private enum Direction { case left, right }

    private func debugLogSpaceInfo() {
        guard let info = spaceInfo else {
            Logger.spaceSwitcher.info("SpaceInfo: <nil>")
            return
        }
        Logger.spaceSwitcher.info(
            """
            SpaceInfo:
              displayIdentifier: \(info.displayIdentifier ?? "nil")
              currentSpaceID: \(info.currentSpaceID.map(String.init) ?? "nil")
              currentSpaceType: \(info.currentSpaceType.map(String.init) ?? "nil")
              frontmostBundleID: \(info.frontmostBundleID ?? "nil")
              currentIndex: \(info.currentIndex)
              spaceCount: \(info.spaceCount)
            """
        )
        Logger.spaceSwitcher.info("Mission control: \(isMissionControlActive())")
    }

    func isMissionControlActive() -> Bool {
        let windowList =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
        for window in windowList {
            if  // window must be owned by "Dock" process
            (window["kCGWindowOwnerName"] as? String) == "Dock",

                // ensure the owner is not some other process named "Dock" (seems unlikely though)
                let windowOwnerPID = window["kCGWindowOwnerPID"] as? pid_t,
                let app = NSRunningApplication(processIdentifier: windowOwnerPID),
                app.bundleIdentifier == "com.apple.dock",

                // window must have no title
                window["kCGWindowName"] == nil
            {
                return true
            }
        }
        return false
    }

    private func loadSpaceInfo(useCursorDisplay: Bool) -> SpaceInfo? {
        guard let cgs = symbols else { return nil }

        let connection = cgs.mainConnectionID()
        guard connection != 0 else { return nil }

        let activeSpaceID = cgs.getActiveSpace(connection)
        guard activeSpaceID != 0 else { return nil }

        let displayID: CFString? =
            useCursorDisplay
            ? cursorDisplayIdentifier()
            : cgs.copyMenuBarDisplayID?(connection)?.takeRetainedValue()

        // Fetch all display/space layout data. Fall back to nil displayID
        // (all displays) if the targeted display yields no results
        var rawDisplays = cgs.copyDisplaySpaces(connection, displayID)?
            .takeRetainedValue()
        if rawDisplays == nil, displayID != nil {
            rawDisplays = cgs.copyDisplaySpaces(connection, nil)?
                .takeRetainedValue()
        }
        guard let rawDisplays else { return nil }

        // Find the display dict that matches our target identifier
        var fallback: NSDictionary?
        var target: NSDictionary?

        for item in rawDisplays as NSArray {
            guard let dict = item as? NSDictionary else { continue }
            if fallback == nil { fallback = dict }
            if let id = displayID,
                let dictID = dict["Display Identifier"] as? String,
                dictID == id as String
            {
                target = dict
                break
            }
        }

        guard let displayDict = target ?? fallback else { return nil }
        return extractSpaceInfo(
            from: displayDict,
            globalActiveSpaceID: activeSpaceID,
            displayIdentifier: displayDict["Display Identifier"] as? String,
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )
    }

    private func extractSpaceInfo(
        from displayDict: NSDictionary,
        globalActiveSpaceID: UInt64,
        displayIdentifier: String?,
        frontmostBundleID: String?
    )
        -> SpaceInfo?
    {
        guard let spacesArray = displayDict["Spaces"] as? NSArray else {
            return nil
        }

        // Prefer the per-display active space ID
        var activeID = globalActiveSpaceID
        let currentSpaceDict = displayDict["Current Space"] as? NSDictionary
        let currentSpaceID = (currentSpaceDict?["id64"] as? NSNumber)?.uint64Value
        let currentSpaceType = (currentSpaceDict?["type"] as? NSNumber)?.intValue
        if let id = currentSpaceID {
            activeID = id
        }

        var count = 0
        var activeIndex = 0
        var foundActive = false

        for item in spacesArray {
            guard let spaceDict = item as? NSDictionary,
                let id = (spaceDict["id64"] as? NSNumber)?.uint64Value
            else { continue }
            if !foundActive && id == activeID {
                activeIndex = count
                foundActive = true
            }
            count += 1
        }

        guard count > 0 else { return nil }
        return SpaceInfo(
            currentIndex: foundActive ? activeIndex : 0,
            spaceCount: count,
            currentSpaceID: currentSpaceID,
            currentSpaceType: currentSpaceType,
            displayIdentifier: displayIdentifier,
            frontmostBundleID: frontmostBundleID
        )
    }

    private func cursorDisplayIdentifier() -> CFString? {
        guard let event = CGEvent(source: nil) else { return nil }
        var displayID: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard
            CGGetDisplaysWithPoint(event.location, 1, &displayID, &count)
                == .success,
            count > 0
        else { return nil }
        let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?
            .takeRetainedValue()
        return CFUUIDCreateString(nil, uuid)
    }

    // MARK: - Gesture posting
    //
    // Synthesizes a CGEvent sequence to switch spaces.
    // This allows for an instant space switch :)
    // Much appreciation to the people that figured out this method.
    // (See the README)
    //
    // Two different sequences are used:
    //  - Outside Mission Control: a minimal begin+end pair. The Dock's desktop
    //    switcher treats swipeProgress on the end event as a direct commit signal,
    //    so no intermediate frames are needed.
    //  - Inside Mission Control: a full begin+changed...+end trace. Mission Control
    //    interprets swipeProgress as a normalized scroll position across the space
    //    strip and requires intermediate frames to register the gesture as intentional
    //    before it will commit the switch.

    @discardableResult
    private func postGesture(_ direction: Direction) -> Bool {
        refreshSpaceInfo()

        if let info = spaceInfo {
            if direction == .left && info.isAtLeftEdge { return false }
            if direction == .right && info.isAtRightEdge { return false }
        }

        if isMissionControlActive() {
            return postMissionControlGesture(direction)
        } else {
            return postInstantGesture(direction)
        }
    }

    /// Minimal two-event sequence for instant switching outside Mission Control.
    @discardableResult
    private func postInstantGesture(_ direction: Direction) -> Bool {
        let isRight = direction == .right
        let flagDir = isRight ? Int64(1) : Int64(0)
        let progress = isRight ? 2.0 : -2.0
        let velocity = isRight ? 400.0 : -400.0

        // -- Begin --
        guard let beginGesture = CGEvent(source: nil),
            let beginDock = CGEvent(source: nil)
        else { return false }

        beginGesture.setIntegerValueField(GestureField.eventType, value: EventType.gesture)
        beginGesture.setIntegerValueField(kSyntheticMarkerField, value: kSyntheticMarkerValue)

        beginDock.setIntegerValueField(GestureField.eventType, value: EventType.dockControl)
        beginDock.setIntegerValueField(GestureField.hidType, value: kDockSwipeHIDType)
        beginDock.setIntegerValueField(GestureField.phase, value: Phase.began)
        beginDock.setIntegerValueField(GestureField.scrollFlags, value: flagDir)
        beginDock.setIntegerValueField(GestureField.swipeMotion, value: Motion.horizontal)
        beginDock.setDoubleValueField(GestureField.scrollY, value: 0)
        beginDock.setDoubleValueField(GestureField.zoomDeltaX, value: kFltTrueMin)
        beginDock.setIntegerValueField(kSyntheticMarkerField, value: kSyntheticMarkerValue)

        beginGesture.post(tap: .cgSessionEventTap)
        beginDock.post(tap: .cgSessionEventTap)

        // -- End --
        guard let endGesture = CGEvent(source: nil),
            let endDock = CGEvent(source: nil)
        else { return false }

        endGesture.setIntegerValueField(GestureField.eventType, value: EventType.gesture)
        endGesture.setIntegerValueField(kSyntheticMarkerField, value: kSyntheticMarkerValue)

        endDock.setIntegerValueField(GestureField.eventType, value: EventType.dockControl)
        endDock.setIntegerValueField(GestureField.hidType, value: kDockSwipeHIDType)
        endDock.setIntegerValueField(GestureField.phase, value: Phase.ended)
        endDock.setDoubleValueField(GestureField.swipeProgress, value: progress)
        endDock.setIntegerValueField(GestureField.scrollFlags, value: flagDir)
        endDock.setIntegerValueField(GestureField.swipeMotion, value: Motion.horizontal)
        endDock.setDoubleValueField(GestureField.scrollY, value: 0)
        endDock.setDoubleValueField(GestureField.velocityX, value: velocity)
        endDock.setDoubleValueField(GestureField.velocityY, value: 0)
        endDock.setDoubleValueField(GestureField.zoomDeltaX, value: kFltTrueMin)
        endDock.setIntegerValueField(kSyntheticMarkerField, value: kSyntheticMarkerValue)

        endGesture.post(tap: .cgSessionEventTap)
        endDock.post(tap: .cgSessionEventTap)

        return true
    }

    /// Multi-step gesture trace for switching spaces inside Mission Control.
    /// Sends intermediate changed-phase frames so Mission Control treats the
    /// sequence as a real tracked gesture and commits the switch cleanly.
    @discardableResult
    private func postMissionControlGesture(_ direction: Direction) -> Bool {
        let isRight = direction == .right
        // scrollFlags values matching actual DockSwipe events:
        // 1 = swipe right (toward higher-indexed space), 4 = swipe left
        let flagDir = isRight ? Int64(1) : Int64(4)
        // Progress steps from 0 toward ±1.0. Mission Control uses these to
        // track the gesture and determine which space to land on.
        let progressSteps: [Double] = [0.25, 0.5, 0.75]
        // swipeProgress slightly past ±1.0 commits the switch.
        let progress = isRight ? 1.05 : -1.05
        let velocity = isRight ? 200.0 : -200.0

        // -- Begin --
        guard let beginGesture = CGEvent(source: nil),
            let beginDock = CGEvent(source: nil)
        else { return false }

        beginGesture.setIntegerValueField(GestureField.eventType, value: EventType.gesture)
        beginGesture.setIntegerValueField(kSyntheticMarkerField, value: kSyntheticMarkerValue)

        beginDock.setIntegerValueField(GestureField.eventType, value: EventType.dockControl)
        beginDock.setIntegerValueField(GestureField.hidType, value: kDockSwipeHIDType)
        beginDock.setIntegerValueField(GestureField.phase, value: Phase.began)
        beginDock.setIntegerValueField(GestureField.scrollFlags, value: flagDir)
        beginDock.setIntegerValueField(GestureField.swipeMotion, value: Motion.horizontal)
        beginDock.setDoubleValueField(GestureField.scrollY, value: 0)
        beginDock.setDoubleValueField(GestureField.zoomDeltaX, value: kFltTrueMin)
        beginDock.setIntegerValueField(kSyntheticMarkerField, value: kSyntheticMarkerValue)

        beginGesture.post(tap: .cgSessionEventTap)
        beginDock.post(tap: .cgSessionEventTap)

        // -- Intermediate changed frames --
        for step in progressSteps {
            guard let changedDock = CGEvent(source: nil) else { return false }
            changedDock.setIntegerValueField(GestureField.eventType, value: EventType.dockControl)
            changedDock.setIntegerValueField(GestureField.hidType, value: kDockSwipeHIDType)
            changedDock.setIntegerValueField(GestureField.phase, value: Phase.changed)
            changedDock.setDoubleValueField(
                GestureField.swipeProgress, value: isRight ? step : -step)
            changedDock.setIntegerValueField(GestureField.scrollFlags, value: flagDir)
            changedDock.setIntegerValueField(GestureField.swipeMotion, value: Motion.horizontal)
            changedDock.setDoubleValueField(GestureField.scrollY, value: 0)
            changedDock.setDoubleValueField(GestureField.velocityX, value: velocity)
            changedDock.setDoubleValueField(GestureField.velocityY, value: 0)
            changedDock.setDoubleValueField(GestureField.zoomDeltaX, value: kFltTrueMin)
            changedDock.setIntegerValueField(kSyntheticMarkerField, value: kSyntheticMarkerValue)
            changedDock.post(tap: .cgSessionEventTap)
        }

        // -- End --
        guard let endGesture = CGEvent(source: nil),
            let endDock = CGEvent(source: nil)
        else { return false }

        endGesture.setIntegerValueField(GestureField.eventType, value: EventType.gesture)
        endGesture.setIntegerValueField(kSyntheticMarkerField, value: kSyntheticMarkerValue)

        endDock.setIntegerValueField(GestureField.eventType, value: EventType.dockControl)
        endDock.setIntegerValueField(GestureField.hidType, value: kDockSwipeHIDType)
        endDock.setIntegerValueField(GestureField.phase, value: Phase.ended)
        endDock.setDoubleValueField(GestureField.swipeProgress, value: progress)
        endDock.setIntegerValueField(GestureField.scrollFlags, value: flagDir)
        endDock.setIntegerValueField(GestureField.swipeMotion, value: Motion.horizontal)
        endDock.setDoubleValueField(GestureField.scrollY, value: 0)
        endDock.setDoubleValueField(GestureField.velocityX, value: velocity)
        endDock.setDoubleValueField(GestureField.velocityY, value: 0)
        endDock.setDoubleValueField(GestureField.zoomDeltaX, value: kFltTrueMin)
        endDock.setIntegerValueField(kSyntheticMarkerField, value: kSyntheticMarkerValue)

        endGesture.post(tap: .cgSessionEventTap)
        endDock.post(tap: .cgSessionEventTap)

        return true
    }
}

// MARK: - Logger

extension Logger {
    fileprivate static let spaceSwitcher = Logger(category: "SpaceSwitcher")
}
