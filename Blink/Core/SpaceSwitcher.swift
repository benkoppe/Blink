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

private let kDefaultInstantGestureVelocity = 999_999.0

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

// MARK: - SpaceSwitcher

@MainActor
@Observable
final class SpaceSwitcher {
    /// The shared app state.
    private(set) weak var appState: AppState?

    var spaceInfo: SpaceInfo? {
        snapshot?.menuBarSpaceInfo
    }

    /// Optimistic menu-bar index; SpaceInfo remains observed.
    var menuBarSpaceIndex: Int? {
        guard let info = spaceInfo, let topology = topology(from: info) else { return nil }
        return switchCoordinator.presentation(in: topology).selectedIndex
    }

    private let symbols: CGSSymbols?

    private var snapshot: SpaceSnapshot?

    private var spaceObserver: NSObjectProtocol?
    private var appObserver: NSObjectProtocol?
    private var screensWakeObserver: NSObjectProtocol?
    private var windowObserver: NSObjectProtocol?
    private var windowScreenObserver: NSObjectProtocol?
    private var screenParamsObserver: NSObjectProtocol?

    private var wrapSpaces: Bool {
        appState?.settingsManager.generalSettingsManager.wrapSpaceSwitching ?? false
    }

    private var instantGestureVelocity: Double {
        max(
            1,
            appState?.settingsManager.generalSettingsManager.instantGestureSpeed.velocity
                ?? kDefaultInstantGestureVelocity)
    }

    private let gestureTransport = DockSwipeTransport()

    @ObservationIgnored
    private lazy var switchCoordinator = SpaceSwitchCoordinator(
        dependencies: .init(
            loadContext: { [weak self] displayIdentifier in
                self?.freshSwitchContext(for: displayIdentifier)
            },
            observeTopologies: { [weak self] in
                self?.observeSpaceTopologies()
            },
            postStep: { [weak self] gestureMode, direction, velocity in
                guard let self else {
                    return .unavailable
                }

                return autoreleasepool {
                    self.gestureTransport.submit(
                        mode: gestureMode,
                        direction: direction,
                        velocity: velocity
                    )
                }
            },
            sleep: { duration in
                try await Task<Never, Never>.sleep(for: duration)
            }
        )
    )

    init(appState: AppState) {
        self.appState = appState

        symbols = CGSSymbols.load()

        refreshSpaceInfo()
        subscribeToWorkspaceNotifications()
    }

    deinit {
        MainActor.assumeIsolated {
            switchCoordinator.cancelAll()

            let workspaceNC = NSWorkspace.shared.notificationCenter
            [spaceObserver, appObserver, screensWakeObserver]
                .compactMap { $0 }.forEach {
                    workspaceNC.removeObserver($0)
                }
            let defaultNC = NotificationCenter.default
            [windowObserver, windowScreenObserver, screenParamsObserver]
                .compactMap { $0 }
                .forEach {
                    defaultNC.removeObserver($0)
                }
        }
    }

    // MARK: - Public interface

    @discardableResult
    func switchLeft() -> Bool { submitStep(.left) }

    @discardableResult
    func switchRight() -> Bool { submitStep(.right) }

    @discardableResult
    func switchToIndex(_ index: Int) -> Bool {
        guard
            let context = freshActionContext(),
            context.topology.spaceIDs.indices.contains(index)
        else {
            return false
        }

        return switchCoordinator.submitTarget(
            context.topology.spaceIDs[index],
            context: context,
            baseVelocity: instantGestureVelocity
        )
    }

    @discardableResult
    func switchToLastSpace() -> Bool {
        guard
            let context = freshActionContext(),
            let targetSpaceID =
                switchCoordinator.lastSpaceID(for: context.topology)
        else {
            return false
        }

        return switchCoordinator.submitTarget(
            targetSpaceID,
            context: context,
            baseVelocity: instantGestureVelocity
        )
    }

    func canMoveLeft() -> Bool { canMove(.left) }
    func canMoveRight() -> Bool { canMove(.right) }

    func canSwitchToLastSpace() -> Bool {
        guard
            let snapshot,
            let topology = actionTopology(in: snapshot)
        else {
            return false
        }

        return switchCoordinator.lastSpaceID(for: topology) != nil
    }

    func refreshSpaceInfo() {
        refreshSpaceInfo(reason: .passiveRefresh)
    }

    private func refreshSpaceInfo(
        reason: SpaceSwitchCoordinator.ReconciliationReason
    ) {
        _ = refreshSnapshot(reason: reason)
    }

    // MARK - Workspace notifications

    private func subscribeToWorkspaceNotifications() {
        let workspaceNC = NSWorkspace.shared.notificationCenter
        spaceObserver = workspaceNC.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSpaceInfo(reason: .activeSpaceChanged)
            }
        }

        appObserver = workspaceNC.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSpaceInfo()
            }
        }

        screensWakeObserver = workspaceNC.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSpaceInfo()
            }
        }

        let defaultNC = NotificationCenter.default
        windowObserver = defaultNC.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSpaceInfo()
            }
        }

        windowScreenObserver = defaultNC.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSpaceInfo()
            }
        }

        screenParamsObserver = defaultNC.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSpaceInfo()
            }
        }
    }

    // MARK: - Space info loading

    private typealias Direction = SpaceSwitchCoordinator.Direction

    @discardableResult
    private func refreshSnapshot(
        reason: SpaceSwitchCoordinator.ReconciliationReason = .passiveRefresh
    ) -> SpaceSnapshot? {
        guard let topologies = observeSpaceTopologies() else { return nil }
        switchCoordinator.reconcile(topologies: topologies, reason: reason)
        return snapshot
    }

    /// Updates the authoritative snapshot independently of cursor position.
    private func observeSpaceTopologies() -> [String: SpaceSwitchCoordinator.Topology]? {
        guard let newSnapshot = loadSpaceSnapshot() else {
            // Retain the displayed snapshot, but reject stale commands.
            return nil
        }

        snapshot = newSnapshot

        return coordinatorTopologies(in: newSnapshot)
    }

    private func topology(
        from info: SpaceInfo
    ) -> SpaceSwitchCoordinator.Topology? {
        guard
            let displayIdentifier = info.displayIdentifier,
            info.spaceIDs.indices.contains(info.currentIndex)
        else {
            return nil
        }

        return SpaceSwitchCoordinator.Topology(
            displayIdentifier: displayIdentifier,
            spaceIDs: info.spaceIDs,
            currentSpaceID: info.spaceIDs[info.currentIndex]
        )
    }

    private func coordinatorTopologies(
        in snapshot: SpaceSnapshot
    ) -> [String: SpaceSwitchCoordinator.Topology] {
        Dictionary(
            uniqueKeysWithValues:
                snapshot.spaceInfoByDisplay.compactMap {
                    displayIdentifier, info in

                    guard
                        info.displayIdentifier == displayIdentifier,
                        let topology = topology(from: info)
                    else {
                        return nil
                    }

                    return (displayIdentifier, topology)
                }
        )
    }

    private func actionTopology(
        in snapshot: SpaceSnapshot
    ) -> SpaceSwitchCoordinator.Topology? {
        guard
            let displayIdentifier = cursorDisplayIdentifier(),
            let info = snapshot.spaceInfoByDisplay[displayIdentifier]
        else {
            return nil
        }

        return topology(from: info)
    }

    private func actionContext(
        in snapshot: SpaceSnapshot
    ) -> SpaceSwitchCoordinator.Context? {
        guard let topology = actionTopology(in: snapshot) else {
            return nil
        }

        let gestureMode: SpaceSwitchCoordinator.GestureMode =
            isMissionControlActive(
                on: topology.displayIdentifier
            )
            ? .missionControl
            : .instant

        return SpaceSwitchCoordinator.Context(
            topology: topology,
            gestureMode: gestureMode
        )
    }

    private func freshActionContext() -> SpaceSwitchCoordinator.Context? {
        guard
            let snapshot = refreshSnapshot(reason: .commandSubmission)
        else {
            return nil
        }

        return actionContext(in: snapshot)
    }

    private func freshSwitchContext(
        for displayIdentifier: String
    ) -> SpaceSwitchCoordinator.Context? {
        guard
            cursorDisplayIdentifier() == displayIdentifier,
            let snapshot = loadSpaceSnapshot(),
            let info = snapshot.spaceInfoByDisplay[displayIdentifier],
            let topology = topology(from: info)
        else {
            return nil
        }

        let gestureMode: SpaceSwitchCoordinator.GestureMode =
            isMissionControlActive(on: displayIdentifier)
            ? .missionControl
            : .instant

        return SpaceSwitchCoordinator.Context(
            topology: topology,
            gestureMode: gestureMode
        )
    }

    private func canMove(_ direction: Direction) -> Bool {
        guard
            let snapshot,
            let topology = actionTopology(in: snapshot)
        else {
            return false
        }

        return switchCoordinator.canMove(
            direction,
            in: topology,
            wrap: wrapSpaces
        )
    }

    @discardableResult
    private func submitStep(_ direction: Direction) -> Bool {
        guard let context = freshActionContext() else {
            return false
        }

        return switchCoordinator.submitStep(
            direction,
            context: context,
            wrap: wrapSpaces,
            baseVelocity: instantGestureVelocity
        )
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
        guard
            let displayIdentifier =
                displayDict["Display Identifier"] as? String,
            !displayIdentifier.isEmpty,
            let spacesArray = displayDict["Spaces"] as? NSArray
        else {
            return nil
        }

        let currentSpaceDict =
            displayDict["Current Space"] as? NSDictionary

        let perDisplayActiveSpaceID =
            (currentSpaceDict?["id64"] as? NSNumber)?
            .uint64Value

        let currentSpaceType =
            (currentSpaceDict?["type"] as? NSNumber)?
            .intValue

        let activeSpaceID =
            perDisplayActiveSpaceID
            ?? globalActiveSpaceID

        var spaceIDs: [UInt64] = []

        for item in spacesArray {
            guard
                let spaceDict = item as? NSDictionary,
                let spaceID = (spaceDict["id64"] as? NSNumber)?.uint64Value,
                spaceID != 0
            else {
                continue
            }

            spaceIDs.append(spaceID)
        }

        guard
            !spaceIDs.isEmpty,
            Set(spaceIDs).count == spaceIDs.count,
            let activeIndex = spaceIDs.firstIndex(of: activeSpaceID)
        else {
            return nil
        }

        return SpaceInfo(
            currentIndex: activeIndex,
            spaceCount: spaceIDs.count,
            spaceIDs: spaceIDs,
            currentSpaceID: activeSpaceID,
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
}

// MARK: - Logger

extension Logger {
    fileprivate static let spaceSwitcher = Logger(category: "SpaceSwitcher")
}
