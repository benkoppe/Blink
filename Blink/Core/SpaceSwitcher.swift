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

// Large bursts of otherwise-valid instant DockSwipe commits can make Dock fall
// back to its animated transition path. Breaking long jumps into short chunks
// with a tiny pause keeps each batch on the instant path.
private let kInstantGestureChunkSize = 4
private let kInstantGestureChunkDelayMicros: useconds_t = 8_000
private let kInstantGestureChunkThreshold = 8

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

    private var wrapSpaces: Bool {
        appState?.settingsManager.generalSettingsManager.wrapSpaceSwitching ?? false
    }

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
        refreshSpaceInfo()

        guard let info = spaceInfo, info.spaceCount > 0 else { return false }
        guard (0..<info.spaceCount).contains(index) else { return false }
        let target = index
        guard target != info.currentIndex else {
            return true
        }

        let direction: Direction = target > info.currentIndex ? .right : .left
        let steps = abs(target - info.currentIndex)

        if isMissionControlActive() {
            return postMissionControlGestures(direction, count: steps)
        }

        return postInstantGestures(direction, count: steps)
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
        let missionControlReport = missionControlWindowReport()
        Logger.spaceSwitcher.info(
            """
            SpaceInfo:
              displayIdentifier: \(info.displayIdentifier ?? "nil")
              currentSpaceID: \(info.currentSpaceID.map(String.init) ?? "nil")
              currentSpaceType: \(info.currentSpaceType.map(String.init) ?? "nil")
              frontmostBundleID: \(info.frontmostBundleID ?? "nil")
              currentIndex: \(info.currentIndex)
              spaceCount: \(info.spaceCount)
              targetDisplayBounds: \(missionControlReport.displayBounds.map(String.init(describing:)) ?? "nil")
            """
        )
        Logger.spaceSwitcher.info(
            "Mission control: \(missionControlReport.isActive)\n\(missionControlReport.debugDescription)"
        )
    }

    private func displayBounds(for displayIdentifier: String?) -> CGRect? {
        guard let displayIdentifier else { return nil }

        var maxDisplayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &maxDisplayCount) == .success,
            maxDisplayCount > 0
        else { return nil }

        var displayIDs = Array(repeating: CGDirectDisplayID(), count: Int(maxDisplayCount))
        var displayCount: UInt32 = 0
        guard
            CGGetOnlineDisplayList(maxDisplayCount, &displayIDs, &displayCount)
                == .success
        else { return nil }

        for displayID in displayIDs.prefix(Int(displayCount)) {
            guard
                let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
                let uuidString = CFUUIDCreateString(nil, uuid) as String?
            else { continue }

            if uuidString == displayIdentifier {
                return CGDisplayBounds(displayID)
            }
        }

        return nil
    }

    private func windowBounds(from window: [String: Any]) -> CGRect? {
        guard let bounds = window[kCGWindowBounds as String] as? NSDictionary else {
            return nil
        }
        return CGRect(dictionaryRepresentation: bounds)
    }

    // Layers of interest in Dock's window list
    private enum DockLayer {
        static let thumbnail: Int = 17  // Space thumbnail cards (normal desktops)
        static let overlay: Int = 20  // Fullscreen overlay / label strip
        static let spaceBacking: Int = -2_147_483_622  // Fullscreen-space preview backing
        static let wallpaper: Int = -2_147_483_624  // Wallpaper window
    }

    private func isDockWindow(_ window: [String: Any]) -> Bool {
        guard
            (window[kCGWindowOwnerName as String] as? String) == "Dock",
            let windowOwnerPID = window[kCGWindowOwnerPID as String] as? pid_t,
            let app = NSRunningApplication(processIdentifier: windowOwnerPID),
            app.bundleIdentifier == "com.apple.dock"
        else { return false }

        return true
    }

    /// Returns true if the supplied Dock window is inset from the display.
    /// Most always-on Dock helper windows are fullscreen, so the inset is the
    /// first gate for all Mission Control-specific signals.
    private func isDockWindowInset(_ window: [String: Any], displayBounds: CGRect) -> Bool {
        guard isDockWindow(window), let bounds = windowBounds(from: window) else {
            return false
        }

        let widthDelta = displayBounds.width - bounds.width
        let heightDelta = displayBounds.height - bounds.height
        return widthDelta > 40 && heightDelta > 40
    }

    /// Checks all three known Mission Control window signatures across the full
    /// on-screen window list for the given display bounds.
    ///
    /// Pattern 1 – Desktop thumbnail cards (layer 17)
    ///   Dock renders a small thumbnail per space when Mission Control is open.
    ///   These are significantly inset from the display.
    ///
    /// Pattern 2 – Empty-space label strip (layer 20, short height)
    ///   When a desktop space has no windows, Mission Control shows a small
    ///   label/control strip (≈177×30) instead of a thumbnail card.
    ///
    /// Pattern 3 – Fullscreen-space preview (layer -2147483622 + wallpaper pair)
    ///   For fullscreen/special spaces Mission Control shows an inset backing
    ///   window at layer -2147483622 paired with a matching inset wallpaper at
    ///   layer -2147483624. Both are inset from the display by a matching amount.
    private func isMissionControlActive(
        in windowList: [[String: Any]],
        displayBounds: CGRect
    ) -> Bool {
        // Collect inset Dock windows grouped by layer for pattern matching
        var hasInsetThumbnail = false  // Pattern 1
        var hasInsetLabelStrip = false  // Pattern 2
        var insetSpaceBackingBounds: [CGRect] = []  // Pattern 3 – backing
        var insetWallpaperBounds: [CGRect] = []  // Pattern 3 – wallpaper pair

        for window in windowList {
            guard isDockWindowInset(window, displayBounds: displayBounds),
                let layer = window[kCGWindowLayer as String] as? Int,
                let bounds = windowBounds(from: window)
            else { continue }

            let isUnnamedWindow = window[kCGWindowName as String] == nil

            switch layer {
            case DockLayer.thumbnail where isUnnamedWindow:
                hasInsetThumbnail = true
            case DockLayer.overlay where isUnnamedWindow && bounds.height < 80:
                hasInsetLabelStrip = true
            case DockLayer.spaceBacking:
                insetSpaceBackingBounds.append(bounds)
            case DockLayer.wallpaper:
                insetWallpaperBounds.append(bounds)
            default:
                break
            }
        }

        if hasInsetThumbnail || hasInsetLabelStrip { return true }

        // Pattern 3: require at least one inset backing with a matching inset wallpaper
        for backingBounds in insetSpaceBackingBounds {
            for wallpaperBounds in insetWallpaperBounds {
                let dx = abs(backingBounds.width - wallpaperBounds.width)
                let dy = abs(backingBounds.height - wallpaperBounds.height)
                if dx < 10 && dy < 10 { return true }
            }
        }

        return false
    }

    // Kept for per-window debug description in missionControlWindowReport()
    private func isMissionControlWindow(
        _ window: [String: Any],
        displayBounds: CGRect?
    ) -> Bool {
        guard let displayBounds else { return false }
        return isMissionControlActive(in: [window], displayBounds: displayBounds)
    }

    private func describeMissionControlWindow(
        _ window: [String: Any],
        displayBounds: CGRect?
    ) -> String? {
        guard (window[kCGWindowOwnerName as String] as? String) == "Dock" else {
            return nil
        }

        let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t
        let bundleID: String
        if let ownerPID, let app = NSRunningApplication(processIdentifier: ownerPID) {
            bundleID = app.bundleIdentifier ?? "nil"
        } else {
            bundleID = "nil"
        }
        let name = window[kCGWindowName as String] as? String ?? "nil"
        let layer = (window[kCGWindowLayer as String] as? Int).map(String.init) ?? "nil"
        let bounds = windowBounds(from: window)
        let widthDelta =
            bounds.map { bounds in
                displayBounds.map { $0.width - bounds.width }
            } ?? nil
        let heightDelta =
            bounds.map { bounds in
                displayBounds.map { $0.height - bounds.height }
            } ?? nil

        return """
              ownerPID: \(ownerPID.map(String.init) ?? "nil")
              bundleID: \(bundleID)
              name: \(name)
              layer: \(layer)
              bounds: \(bounds.map(String.init(describing:)) ?? "nil")
              widthDelta: \(widthDelta.map(String.init) ?? "nil")
              heightDelta: \(heightDelta.map(String.init) ?? "nil")
              matchesMissionControl: \(isMissionControlWindow(window, displayBounds: displayBounds))
            """
    }

    private func missionControlWindowReport() -> (
        isActive: Bool,
        displayBounds: CGRect?,
        debugDescription: String
    ) {
        let targetDisplayBounds = displayBounds(for: spaceInfo?.displayIdentifier)
        let windowList =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]

        let isActive =
            targetDisplayBounds.map {
                isMissionControlActive(in: windowList, displayBounds: $0)
            } ?? false

        var dockWindowDescriptions: [String] = []
        for window in windowList {
            if let description = describeMissionControlWindow(
                window,
                displayBounds: targetDisplayBounds
            ) {
                dockWindowDescriptions.append(description)
            }
        }

        let debugDescription =
            if dockWindowDescriptions.isEmpty {
                "Detected Dock windows: <none>"
            } else {
                "Detected Dock windows:\n" + dockWindowDescriptions.joined(separator: "\n")
            }

        return (isActive, targetDisplayBounds, debugDescription)
    }

    func isMissionControlActive() -> Bool {
        missionControlWindowReport().isActive
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
            let shouldWrap =
                switch direction {
                case .left: info.isAtLeftEdge
                case .right: info.isAtRightEdge
                }

            if shouldWrap {
                guard wrapSpaces else { return false }

                let targetIndex =
                    switch direction {
                    case .left: info.spaceCount - 1
                    case .right: 0
                    }
                return switchToIndex(targetIndex)
            }
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

    /// Batch repeated instant gestures without re-checking space state between steps.
    /// This keeps large indexed jumps fast by letting WindowServer consume a tight
    /// burst of already-formed one-space commits.
    @discardableResult
    private func postInstantGestures(_ direction: Direction, count: Int) -> Bool {
        guard count >= 0 else { return false }

        for step in 0..<count {
            let didPost = autoreleasepool { postInstantGesture(direction) }
            guard didPost else { return false }

            let completed = step + 1
            let shouldPause =
                count >= kInstantGestureChunkThreshold
                && completed < count
                && completed.isMultiple(of: kInstantGestureChunkSize)

            if shouldPause {
                usleep(kInstantGestureChunkDelayMicros)
            }
        }

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

    @discardableResult
    private func postMissionControlGestures(
        _ direction: Direction,
        count: Int
    ) -> Bool {
        guard count >= 0 else { return false }

        for _ in 0..<count {
            let didPost = autoreleasepool { postMissionControlGesture(direction) }
            guard didPost else { return false }
        }

        return true
    }
}

// MARK: - Logger

extension Logger {
    fileprivate static let spaceSwitcher = Logger(category: "SpaceSwitcher")
}
