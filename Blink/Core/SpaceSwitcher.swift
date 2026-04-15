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

private let kDefaultInstantGestureVelocity = 999_999.0

// Interval between per-step MC gestures when posted via asyncAfter.
// Must be long enough for one run-loop cycle to process the previous event.
private let kMissionControlStepInterval: TimeInterval = 0.010

// For large instant jumps outside Mission Control, gestures are chunked into
// groups so Dock doesn't see an overwhelming burst. asyncAfter is used (not
// usleep) for the same reason as the MC path: Blink's active event tap holds
// events until the main-thread run loop fires, so usleep just queues them
// all up and they flush as a burst at the end anyway.
private let kInstantGestureChunkSize = 4
private let kInstantGestureChunkInterval: TimeInterval = 0.040

// MARK - SpaceInfo

struct SpaceInfo: Equatable {
    let currentIndex: Int
    let spaceCount: Int
    let spaceIDs: [UInt64]

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

    func index(ofSpaceID spaceID: UInt64) -> Int? {
        spaceIDs.firstIndex(of: spaceID)
    }
}

private struct SpaceSnapshot {
    let spaceInfoByDisplay: [String: SpaceInfo]
    let fallbackSpaceInfo: SpaceInfo
    let menuBarDisplayIdentifier: String?

    var menuBarSpaceInfo: SpaceInfo {
        if let menuBarDisplayIdentifier,
            let info = spaceInfoByDisplay[menuBarDisplayIdentifier]
        {
            return info
        }

        return fallbackSpaceInfo
    }

    func spaceInfo(for displayIdentifier: String?) -> SpaceInfo {
        if let displayIdentifier,
            let info = spaceInfoByDisplay[displayIdentifier]
        {
            return info
        }

        return menuBarSpaceInfo
    }
}

private struct PendingJump {
    let originSpaceID: UInt64
    var targetSpaceID: UInt64
}

// MARK: - SpaceSwitcher

@Observable
final class SpaceSwitcher {
    /// The shared app state.
    private(set) weak var appState: AppState?

    var spaceInfo: SpaceInfo? {
        guard let snapshot else { return nil }
        return applyingOptimisticIndex(to: snapshot.menuBarSpaceInfo)
    }

    private let symbols: CGSSymbols?

    private var snapshot: SpaceSnapshot?
    private var optimisticCurrentIndexByDisplay: [String: Int] = [:]
    private var lastSpaceIDByDisplay: [String: UInt64] = [:]
    private var pendingJumpByDisplay: [String: PendingJump] = [:]

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
        guard let snapshot = refreshSnapshot() else { return false }
        let info = actionSpaceInfo(in: snapshot)
        guard info.spaceCount > 0 else { return false }

        return moveToIndex(index, using: info)
    }

    @discardableResult
    func switchToLastSpace() -> Bool {
        guard let snapshot = refreshSnapshot() else { return false }
        let info = actionSpaceInfo(in: snapshot)
        guard let targetIndex = lastSpaceTargetIndex(using: info) else { return false }

        return moveToIndex(targetIndex, using: info)
    }

    func canMoveLeft() -> Bool { canMove(.left) }
    func canMoveRight() -> Bool { canMove(.right) }

    func canSwitchToLastSpace() -> Bool {
        guard let snapshot else { return false }
        let info = actionSpaceInfo(in: snapshot)
        return lastSpaceTargetIndex(using: info) != nil
    }

    func refreshSpaceInfo() {
        _ = refreshSnapshot()
        // debugLogSpaceInfo()
    }

    // MARK - Workspace notifications

    private func subscribeToWorkspaceNotifications() {
        let workspaceNC = NSWorkspace.shared.notificationCenter
        spaceObserver = workspaceNC.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clearOptimisticStateForCompletedJumps()
            self?.refreshSpaceInfo()
        }

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

    private func scheduleAsyncActions(
        count: Int,
        interval: TimeInterval,
        action: @escaping (Int) -> Void,
        completion: (() -> Void)? = nil
    ) {
        let start = DispatchTime.now()

        for index in 0..<count {
            let deadline = start + Double(index) * interval
            DispatchQueue.main.asyncAfter(deadline: deadline) {
                action(index)
            }
        }

        guard let completion else { return }

        let completionDeadline = start + Double(count) * interval
        DispatchQueue.main.asyncAfter(deadline: completionDeadline) {
            completion()
        }
    }

    @discardableResult
    private func refreshSnapshot() -> SpaceSnapshot? {
        let previousSnapshot = snapshot

        guard let newSnapshot = loadSpaceSnapshot() else {
            return snapshot
        }

        updateLastSpaceHistory(from: previousSnapshot, to: newSnapshot)
        snapshot = newSnapshot

        return newSnapshot
    }

    private func actionSpaceInfo(in snapshot: SpaceSnapshot) -> SpaceInfo {
        snapshot.spaceInfo(for: cursorDisplayIdentifier())
    }

    private func updateLastSpaceHistory(
        from previousSnapshot: SpaceSnapshot?,
        to currentSnapshot: SpaceSnapshot
    ) {
        guard let previousSnapshot else { return }

        for (displayIdentifier, currentInfo) in currentSnapshot.spaceInfoByDisplay {
            if let pendingJump = pendingJumpByDisplay[displayIdentifier] {
                if currentInfo.currentSpaceID == pendingJump.targetSpaceID {
                    lastSpaceIDByDisplay[displayIdentifier] = pendingJump.originSpaceID
                    pendingJumpByDisplay.removeValue(forKey: displayIdentifier)
                    optimisticCurrentIndexByDisplay.removeValue(forKey: displayIdentifier)
                }
                continue
            }

            guard
                let previousInfo = previousSnapshot.spaceInfoByDisplay[displayIdentifier],
                let previousSpaceID = previousInfo.currentSpaceID,
                previousSpaceID != currentInfo.currentSpaceID
            else { continue }

            lastSpaceIDByDisplay[displayIdentifier] = previousSpaceID
        }

        let activeDisplayIdentifiers = Set(currentSnapshot.spaceInfoByDisplay.keys)
        lastSpaceIDByDisplay = lastSpaceIDByDisplay.filter {
            activeDisplayIdentifiers.contains($0.key)
        }
        optimisticCurrentIndexByDisplay = optimisticCurrentIndexByDisplay.filter {
            activeDisplayIdentifiers.contains($0.key)
        }
        pendingJumpByDisplay = pendingJumpByDisplay.filter {
            activeDisplayIdentifiers.contains($0.key)
        }
    }

    private func applyingOptimisticIndex(to info: SpaceInfo) -> SpaceInfo {
        guard
            info.spaceCount > 0,
            let displayIdentifier = info.displayIdentifier,
            let optimisticCurrentIndex = optimisticCurrentIndexByDisplay[displayIdentifier]
        else {
            return info
        }

        let clampedIndex = max(0, min(optimisticCurrentIndex, info.spaceCount - 1))
        guard clampedIndex != info.currentIndex else {
            return info
        }

        return SpaceInfo(
            currentIndex: clampedIndex,
            spaceCount: info.spaceCount,
            spaceIDs: info.spaceIDs,
            currentSpaceID: info.currentSpaceID,
            currentSpaceType: info.currentSpaceType,
            displayIdentifier: info.displayIdentifier,
            frontmostBundleID: info.frontmostBundleID
        )
    }

    private func currentIndex(for info: SpaceInfo) -> Int {
        guard
            let displayIdentifier = info.displayIdentifier,
            let optimisticCurrentIndex = optimisticCurrentIndexByDisplay[displayIdentifier]
        else {
            return info.currentIndex
        }
        return max(0, min(optimisticCurrentIndex, info.spaceCount - 1))
    }

    private func setOptimisticCurrentIndex(_ index: Int, for info: SpaceInfo) {
        guard let displayIdentifier = info.displayIdentifier else { return }
        optimisticCurrentIndexByDisplay[displayIdentifier] = index
    }

    private func rememberCurrentSpaceAsLast(_ info: SpaceInfo, targetIndex: Int? = nil) {
        guard
            let displayIdentifier = info.displayIdentifier,
            let currentSpaceID = info.currentSpaceID
        else { return }

        guard
            let targetIndex,
            info.spaceIDs.indices.contains(targetIndex)
        else {
            if pendingJumpByDisplay[displayIdentifier] == nil {
                lastSpaceIDByDisplay[displayIdentifier] = currentSpaceID
            }
            return
        }

        if pendingJumpByDisplay[displayIdentifier] == nil {
            pendingJumpByDisplay[displayIdentifier] = PendingJump(
                originSpaceID: currentSpaceID,
                targetSpaceID: info.spaceIDs[targetIndex]
            )
        } else {
            pendingJumpByDisplay[displayIdentifier]?.targetSpaceID = info.spaceIDs[targetIndex]
        }
    }

    @discardableResult
    private func moveToIndex(_ index: Int, using info: SpaceInfo) -> Bool {
        let missionControlActive = isMissionControlActive(on: info.displayIdentifier)

        guard (0..<info.spaceCount).contains(index) else { return false }

        let currentIndex = missionControlActive ? info.currentIndex : currentIndex(for: info)
        guard index != currentIndex else { return true }

        let direction: Direction = index > currentIndex ? .right : .left
        let steps = abs(index - currentIndex)

        let didPost =
            missionControlActive
            ? postMissionControlJump(direction, steps: steps)
            : postInstantJump(direction, steps: steps, targetIndex: index, info: info)

        if didPost {
            rememberCurrentSpaceAsLast(info, targetIndex: index)
        }

        return didPost
    }

    private func canMove(_ direction: Direction) -> Bool {
        guard let snapshot else { return false }

        let info = actionSpaceInfo(in: snapshot)
        guard info.spaceCount > 0 else { return false }

        if wrapSpaces { return true }

        let missionControlActive = isMissionControlActive(on: info.displayIdentifier)
        let currentIndex = missionControlActive ? info.currentIndex : currentIndex(for: info)

        switch direction {
        case .left:
            return currentIndex > 0
        case .right:
            return currentIndex + 1 < info.spaceCount
        }
    }

    private func lastSpaceTargetIndex(using info: SpaceInfo) -> Int? {
        guard
            info.spaceCount > 0,
            let displayIdentifier = info.displayIdentifier,
            let lastSpaceID = lastSpaceIDByDisplay[displayIdentifier],
            let targetIndex = info.index(ofSpaceID: lastSpaceID)
        else { return nil }

        let missionControlActive = isMissionControlActive(on: info.displayIdentifier)
        let currentIndex = missionControlActive ? info.currentIndex : currentIndex(for: info)

        guard targetIndex != currentIndex else { return nil }
        return targetIndex
    }

    private func clearOptimisticStateForCompletedJumps() {
        optimisticCurrentIndexByDisplay = optimisticCurrentIndexByDisplay.filter {
            pendingJumpByDisplay[$0.key] != nil
        }
    }

    private enum OverlayMode: String {
        case none
        case appExpose
        case missionControl
    }

    private func debugLogSpaceInfo() {
        guard let info = spaceInfo else {
            Logger.spaceSwitcher.info("SpaceInfo: <nil>")
            return
        }
        let overlayReport = overlayModeReport()
        Logger.spaceSwitcher.info(
            """
            SpaceInfo:
              displayIdentifier: \(info.displayIdentifier ?? "nil")
              currentSpaceID: \(info.currentSpaceID.map(String.init) ?? "nil")
              currentSpaceType: \(info.currentSpaceType.map(String.init) ?? "nil")
              frontmostBundleID: \(info.frontmostBundleID ?? "nil")
              currentIndex: \(info.currentIndex)
              spaceCount: \(info.spaceCount)
              targetDisplayBounds: \(overlayReport.displayBounds.map(String.init(describing:)) ?? "nil")
            """
        )
        Logger.spaceSwitcher.info(
            "Overlay mode: \(overlayReport.mode.rawValue)\n\(overlayReport.debugDescription)"
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

    private enum DockLayer {
        static let thumbnail: Int = 17
        static let appSwitcherBackdrop: Int = 18
        static let previewOverlay: Int = 20
        static let fullscreenPreviewBacking: Int = -2_147_483_622
        static let wallpaper: Int = -2_147_483_624
    }

    private struct DockWindowInfo {
        let ownerPID: pid_t
        let bundleID: String
        let name: String?
        let layer: Int
        let bounds: CGRect

        var isUnnamed: Bool { name == nil }
        var isWallpaper: Bool { layer == DockLayer.wallpaper }

        var isThumbnailCard: Bool {
            isUnnamed && layer == DockLayer.thumbnail
        }

        var isEmptySpaceLabelStrip: Bool {
            isUnnamed && layer == DockLayer.previewOverlay && bounds.height < 80
        }

        var isFullscreenPreviewBacking: Bool {
            isUnnamed && layer == DockLayer.fullscreenPreviewBacking
        }

        func widthDelta(from displayBounds: CGRect) -> CGFloat {
            displayBounds.width - bounds.width
        }

        func heightDelta(from displayBounds: CGRect) -> CGFloat {
            displayBounds.height - bounds.height
        }

        func isInset(from displayBounds: CGRect) -> Bool {
            widthDelta(from: displayBounds) > 40
                && heightDelta(from: displayBounds) > 40
        }

        func matchesPreviewBounds(of other: DockWindowInfo) -> Bool {
            abs(bounds.width - other.bounds.width) < 10
                && abs(bounds.height - other.bounds.height) < 10
        }
    }

    private func dockWindowInfo(from window: [String: Any]) -> DockWindowInfo? {
        guard
            (window[kCGWindowOwnerName as String] as? String) == "Dock",
            let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
            let app = NSRunningApplication(processIdentifier: ownerPID),
            let bundleID = app.bundleIdentifier,
            bundleID == "com.apple.dock",
            let layer = window[kCGWindowLayer as String] as? Int,
            let bounds = windowBounds(from: window)
        else { return nil }

        return DockWindowInfo(
            ownerPID: ownerPID,
            bundleID: bundleID,
            name: window[kCGWindowName as String] as? String,
            layer: layer,
            bounds: bounds
        )
    }

    private func hasAppSwitcherBackdrop(in windows: [DockWindowInfo]) -> Bool {
        windows.contains { $0.layer == DockLayer.appSwitcherBackdrop }
    }

    private func previewOverlayCount(in windows: [DockWindowInfo]) -> Int {
        windows.reduce(0) { count, window in
            count + (window.layer == DockLayer.previewOverlay ? 1 : 0)
        }
    }

    private func detectedMissionControlWindowIndices(
        for windows: [DockWindowInfo],
        displayBounds: CGRect
    ) -> Set<Int> {
        let insetWindows = windows.enumerated().filter { _, window in
            window.isInset(from: displayBounds)
        }

        var matchingIndices: Set<Int> = []

        for (index, window) in insetWindows {
            if window.isThumbnailCard || window.isWallpaper {
                matchingIndices.insert(index)
            }
        }

        let insetFullscreenPreviewBackings = insetWindows.filter { _, window in
            window.isFullscreenPreviewBacking
        }
        let insetWallpapers = insetWindows.filter { _, window in
            window.isWallpaper
        }

        for (backingIndex, backingWindow) in insetFullscreenPreviewBackings {
            for (wallpaperIndex, wallpaperWindow) in insetWallpapers
            where backingWindow.matchesPreviewBounds(of: wallpaperWindow) {
                matchingIndices.insert(backingIndex)
                matchingIndices.insert(wallpaperIndex)
            }
        }

        return matchingIndices
    }

    private func describeMissionControlWindow(
        _ windowInfo: DockWindowInfo,
        displayBounds: CGRect?,
        matchesMissionControl: Bool
    ) -> String? {
        let widthDelta = displayBounds.map { windowInfo.widthDelta(from: $0) }
        let heightDelta = displayBounds.map { windowInfo.heightDelta(from: $0) }

        return """
              ownerPID: \(String(windowInfo.ownerPID))
              bundleID: \(windowInfo.bundleID)
              name: \(windowInfo.name ?? "nil")
              layer: \(String(windowInfo.layer))
              bounds: \(String(describing: windowInfo.bounds))
              widthDelta: \(widthDelta.map(String.init) ?? "nil")
              heightDelta: \(heightDelta.map(String.init) ?? "nil")
              matchesMissionControl: \(matchesMissionControl)
            """
    }

    private func overlayModeReport() -> (
        mode: OverlayMode,
        displayBounds: CGRect?,
        debugDescription: String
    ) {
        overlayModeReport(for: spaceInfo?.displayIdentifier)
    }

    private func overlayModeReport(
        for displayIdentifier: String?
    ) -> (
        mode: OverlayMode,
        displayBounds: CGRect?,
        debugDescription: String
    ) {
        let targetDisplayBounds = displayBounds(for: displayIdentifier)
        let windowList =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]

        let dockWindows = windowList.compactMap(dockWindowInfo)
        let matchingIndices =
            targetDisplayBounds.map {
                detectedMissionControlWindowIndices(for: dockWindows, displayBounds: $0)
            } ?? Set<Int>()

        let hasStrongMissionControlSignal = !matchingIndices.isEmpty
        let hasBackdrop = hasAppSwitcherBackdrop(in: dockWindows)
        let layer20Count = previewOverlayCount(in: dockWindows)

        let mode: OverlayMode
        if hasStrongMissionControlSignal {
            mode = .missionControl
        } else if hasBackdrop && layer20Count >= 3 {
            mode = .missionControl
        } else if hasBackdrop && (1...2).contains(layer20Count) {
            mode = .appExpose
        } else {
            mode = .none
        }

        var dockWindowDescriptions: [String] = []
        for (index, window) in dockWindows.enumerated() {
            if let description = describeMissionControlWindow(
                window,
                displayBounds: targetDisplayBounds,
                matchesMissionControl: matchingIndices.contains(index)
            ) {
                dockWindowDescriptions.append(description)
            }
        }

        let dockWindowSummary =
            if dockWindowDescriptions.isEmpty {
                "Detected Dock windows: <none>"
            } else {
                "Detected Dock windows:\n" + dockWindowDescriptions.joined(separator: "\n")
            }
        let debugDescription = """
            hasStrongMissionControlSignal: \(hasStrongMissionControlSignal)
            hasLayer18Backdrop: \(hasBackdrop)
            layer20Count: \(layer20Count)
            \(dockWindowSummary)
            """

        return (mode, targetDisplayBounds, debugDescription)
    }

    func isMissionControlActive() -> Bool {
        overlayModeReport().mode == .missionControl
    }

    private func isMissionControlActive(on displayIdentifier: String?) -> Bool {
        overlayModeReport(for: displayIdentifier).mode == .missionControl
    }

    func isAppExposeActive() -> Bool {
        overlayModeReport().mode == .appExpose
    }

    private func loadSpaceSnapshot() -> SpaceSnapshot? {
        guard let cgs = symbols else { return nil }

        let connection = cgs.mainConnectionID()
        guard connection != 0 else { return nil }

        let activeSpaceID = cgs.getActiveSpace(connection)
        guard
            activeSpaceID != 0,
            let rawDisplays = cgs.copyDisplaySpaces(connection, nil)?.takeRetainedValue()
        else { return nil }

        let menuBarDisplayIdentifier =
            cgs.copyMenuBarDisplayID?(connection)?.takeRetainedValue() as String?
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        var spaceInfoByDisplay: [String: SpaceInfo] = [:]
        var fallbackSpaceInfo: SpaceInfo?

        for item in rawDisplays as NSArray {
            guard let displayDict = item as? NSDictionary,
                let info = extractSpaceInfo(
                    from: displayDict,
                    globalActiveSpaceID: activeSpaceID,
                    frontmostBundleID: frontmostBundleID
                )
            else { continue }

            if fallbackSpaceInfo == nil {
                fallbackSpaceInfo = info
            }

            if let displayIdentifier = info.displayIdentifier {
                spaceInfoByDisplay[displayIdentifier] = info
            }
        }

        guard let fallbackSpaceInfo else { return nil }

        return SpaceSnapshot(
            spaceInfoByDisplay: spaceInfoByDisplay,
            fallbackSpaceInfo: fallbackSpaceInfo,
            menuBarDisplayIdentifier: menuBarDisplayIdentifier
        )
    }

    private func extractSpaceInfo(
        from displayDict: NSDictionary,
        globalActiveSpaceID: UInt64,
        frontmostBundleID: String?
    )
        -> SpaceInfo?
    {
        let displayIdentifier = displayDict["Display Identifier"] as? String

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
        var spaceIDs: [UInt64] = []

        for item in spacesArray {
            guard let spaceDict = item as? NSDictionary,
                let id = (spaceDict["id64"] as? NSNumber)?.uint64Value
            else { continue }

            if !foundActive && id == activeID {
                activeIndex = count
                foundActive = true
            }

            spaceIDs.append(id)
            count += 1
        }

        guard count > 0 else { return nil }
        return SpaceInfo(
            currentIndex: foundActive ? activeIndex : 0,
            spaceCount: count,
            spaceIDs: spaceIDs,
            currentSpaceID: currentSpaceID,
            currentSpaceType: currentSpaceType,
            displayIdentifier: displayIdentifier,
            frontmostBundleID: frontmostBundleID
        )
    }

    private func cursorDisplayIdentifier() -> String? {
        guard let event = CGEvent(source: nil) else { return nil }

        var displayID: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard
            CGGetDisplaysWithPoint(event.location, 1, &displayID, &count) == .success,
            count > 0,
            let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
        else { return nil }

        return CFUUIDCreateString(nil, uuid) as String?
    }

    // MARK: - Gesture posting
    //
    // Synthesizes a CGEvent sequence to switch spaces.
    // This allows for an instant space switch :)
    // Much appreciation to the people that figured out this method.
    // (See the README)
    //
    // Two different sequences are used:
    //  - Outside Mission Control: a high-velocity began+changed+ended DockSwipe
    //    trace that Dock treats as an instant desktop-space commit.
    //  - Inside Mission Control: an explicit progress trace that remains more
    //    reliable for moving across many spaces in the strip.

    @discardableResult
    private func postGesture(_ direction: Direction) -> Bool {
        let snapshot = refreshSnapshot()
        let info = snapshot.map(actionSpaceInfo(in:))
        let missionControlActive = isMissionControlActive(on: info?.displayIdentifier)

        if let info {
            let currentIndex = missionControlActive ? info.currentIndex : currentIndex(for: info)
            let shouldWrap =
                switch direction {
                case .left: currentIndex == 0
                case .right: currentIndex + 1 >= info.spaceCount
                }

            if shouldWrap {
                guard wrapSpaces else { return false }

                let targetIndex =
                    switch direction {
                    case .left: info.spaceCount - 1
                    case .right: 0
                    }

                return moveToIndex(targetIndex, using: info)
            }
        }

        let didPost =
            missionControlActive
            ? postMissionControlStep(direction)
            : postInstantStep(direction, info: info)

        if didPost, let info {
            rememberCurrentSpaceAsLast(info)
        }

        return didPost
    }

    private func dockSwipeFlagBits(for direction: Direction) -> Int64 {
        var flagsProgress = Float.leastNonzeroMagnitude
        if direction == .left {
            flagsProgress.negate()
        }

        return Int64(Int32(bitPattern: flagsProgress.bitPattern))
    }

    /// Synthetic DockSwipe trace for instant switching outside Mission Control.
    @discardableResult
    private func postInstantGesture(
        _ direction: Direction,
        velocity: Double = kDefaultInstantGestureVelocity
    ) -> Bool {
        postDockSwipe(phase: Phase.began, direction: direction, velocity: velocity)
            && postDockSwipe(phase: Phase.changed, direction: direction, velocity: velocity)
            && postDockSwipe(phase: Phase.ended, direction: direction, velocity: velocity)
    }

    @discardableResult
    private func postDockSwipe(
        phase: Int64,
        direction: Direction,
        velocity: Double
    ) -> Bool {
        let velocityX = direction == .right ? velocity : -velocity
        let flagBits = dockSwipeFlagBits(for: direction)

        guard let gestureEvent = CGEvent(source: nil),
            let dockEvent = CGEvent(source: nil)
        else { return false }

        gestureEvent.setIntegerValueField(GestureField.eventType, value: EventType.gesture)
        gestureEvent.setIntegerValueField(kSyntheticMarkerField, value: kSyntheticMarkerValue)

        dockEvent.setIntegerValueField(GestureField.eventType, value: EventType.dockControl)
        dockEvent.setIntegerValueField(GestureField.hidType, value: kDockSwipeHIDType)
        dockEvent.setIntegerValueField(GestureField.phase, value: phase)
        dockEvent.setIntegerValueField(GestureField.scrollFlags, value: flagBits)
        dockEvent.setIntegerValueField(GestureField.swipeMotion, value: Motion.horizontal)
        dockEvent.setDoubleValueField(GestureField.scrollY, value: 0)
        dockEvent.setDoubleValueField(GestureField.velocityX, value: velocityX)
        dockEvent.setDoubleValueField(GestureField.velocityY, value: 0)
        dockEvent.setDoubleValueField(GestureField.zoomDeltaX, value: kFltTrueMin)
        dockEvent.setIntegerValueField(kSyntheticMarkerField, value: kSyntheticMarkerValue)

        dockEvent.post(tap: .cgSessionEventTap)
        gestureEvent.post(tap: .cgSessionEventTap)

        return true
    }

    @discardableResult
    private func postInstantGestures(
        _ direction: Direction,
        count: Int,
        velocity: Double
    ) -> Bool {
        guard count >= 0 else { return false }

        for _ in 0..<count {
            let didPost = autoreleasepool { postInstantGesture(direction, velocity: velocity) }
            guard didPost else { return false }
        }

        return true
    }

    @discardableResult
    private func postInstantJump(
        _ direction: Direction,
        steps: Int,
        targetIndex: Int,
        info: SpaceInfo
    ) -> Bool {
        let velocity = kDefaultInstantGestureVelocity * Double(steps)

        if steps > kInstantGestureChunkSize {
            return postChunkedInstantJump(
                direction,
                steps: steps,
                velocity: velocity,
                targetIndex: targetIndex,
                info: info
            )
        }

        let didPost = postInstantGestures(direction, count: steps, velocity: velocity)
        if didPost {
            setOptimisticCurrentIndex(targetIndex, for: info)
        }
        return didPost
    }

    @discardableResult
    private func postChunkedInstantJump(
        _ direction: Direction,
        steps: Int,
        velocity: Double,
        targetIndex: Int,
        info: SpaceInfo
    ) -> Bool {
        let chunkCount = (steps + kInstantGestureChunkSize - 1) / kInstantGestureChunkSize

        scheduleAsyncActions(count: chunkCount, interval: kInstantGestureChunkInterval) {
            [weak self] chunk in
            guard let self else { return }

            let chunkStart = chunk * kInstantGestureChunkSize
            let chunkEnd = min(chunkStart + kInstantGestureChunkSize, steps)
            let chunkSteps = chunkEnd - chunkStart
            _ = self.postInstantGestures(direction, count: chunkSteps, velocity: velocity)
        } completion: { [weak self] in
            self?.setOptimisticCurrentIndex(targetIndex, for: info)
        }

        return true
    }

    @discardableResult
    private func postMissionControlJump(_ direction: Direction, steps: Int) -> Bool {
        // Blink's active event tap delays delivery until the main run loop spins,
        // so each Mission Control step must be posted from a later turn.
        scheduleAsyncActions(count: steps, interval: kMissionControlStepInterval) {
            [weak self] _ in
            self?.postMissionControlGesture(direction)
        } completion: { [weak self] in
            self?.refreshSpaceInfo()
        }

        return true
    }

    @discardableResult
    private func postInstantStep(_ direction: Direction, info: SpaceInfo?) -> Bool {
        let didPost = postInstantGesture(direction)
        guard didPost, let info else { return didPost }

        let currentIndex = currentIndex(for: info)
        let targetIndex = direction == .left ? currentIndex - 1 : currentIndex + 1
        setOptimisticCurrentIndex(targetIndex, for: info)
        return true
    }

    @discardableResult
    private func postMissionControlStep(_ direction: Direction) -> Bool {
        let didPost = postMissionControlGesture(direction)
        if didPost { refreshSpaceInfo() }
        return didPost
    }

    @discardableResult
    private func postMissionControlGesture(_ direction: Direction) -> Bool {
        let isRight = direction == .right
        let flagDir = dockSwipeFlagBits(for: direction)
        let progressSteps: [Double] = [0.25, 0.5, 0.75]
        let progress = isRight ? 1.05 : -1.05
        let velocity = isRight ? 200.0 : -200.0

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

        for step in progressSteps {
            guard let changedDock = CGEvent(source: nil) else { return false }
            changedDock.setIntegerValueField(GestureField.eventType, value: EventType.dockControl)
            changedDock.setIntegerValueField(GestureField.hidType, value: kDockSwipeHIDType)
            changedDock.setIntegerValueField(GestureField.phase, value: Phase.changed)
            changedDock.setDoubleValueField(
                GestureField.swipeProgress,
                value: isRight ? step : -step
            )
            changedDock.setIntegerValueField(GestureField.scrollFlags, value: flagDir)
            changedDock.setIntegerValueField(GestureField.swipeMotion, value: Motion.horizontal)
            changedDock.setDoubleValueField(GestureField.scrollY, value: 0)
            changedDock.setDoubleValueField(GestureField.velocityX, value: velocity)
            changedDock.setDoubleValueField(GestureField.velocityY, value: 0)
            changedDock.setDoubleValueField(GestureField.zoomDeltaX, value: kFltTrueMin)
            changedDock.setIntegerValueField(kSyntheticMarkerField, value: kSyntheticMarkerValue)
            changedDock.post(tap: .cgSessionEventTap)
        }

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
