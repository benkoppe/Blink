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
    static let swipeMask = CGEventField(rawValue: 115)!
    static let eventType = CGEventField(rawValue: 55)!
    static let hidType = CGEventField(rawValue: 110)!
    static let positionX = CGEventField(rawValue: 125)!
    static let positionY = CGEventField(rawValue: 126)!
    static let scrollY = CGEventField(rawValue: 119)!
    static let swipeMotion = CGEventField(rawValue: 123)!
    static let swipeProgress = CGEventField(rawValue: 124)!
    static let velocityX = CGEventField(rawValue: 129)!
    static let velocityY = CGEventField(rawValue: 130)!
    static let phase = CGEventField(rawValue: 132)!
    static let phaseAlias = CGEventField(rawValue: 134)!
    static let scrollFlags = CGEventField(rawValue: 135)!
    static let zoomDeltaY = CGEventField(rawValue: 138)!
    static let zoomDeltaX = CGEventField(rawValue: 139)!
    static let sourceUnixProcessIDAlias = CGEventField(rawValue: 169)!
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
private let kMacOS27ProgressMagnitude = 0.000016
private let kMacOS27MaximumGestureVelocity = 1_000.0
private let kMacOS27GesturePhaseDelay: useconds_t = 10_000

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { bytes in
            append(contentsOf: bytes)
        }
    }
}

/// Builds the private IOHID payload macOS 27 requires for synthetic Dock
/// swipe events. The surrounding CGEvent serialization is big-endian, while
/// the IOHID records themselves use the host's little-endian layout.
enum DockEventPayload {
    private static let fieldID = 4_205

    static func fixedPoint1616(_ value: Double) -> Int32 {
        guard value.isFinite else { return 0 }

        let scaledValue = value * 65_536
        guard scaledValue != 0 else {
            return value == 0 ? 0 : (value.sign == .minus ? -1 : 1)
        }

        let clampedValue = min(
            max(scaledValue, Double(Int32.min)),
            Double(Int32.max)
        )

        return Int32(clampedValue.rounded(.towardZero))
    }

    static func makePayload(for event: CGEvent) -> Data {
        let phase = event.getIntegerValueField(GestureField.phase)
        let motion = event.getIntegerValueField(GestureField.swipeMotion)
        let progress = event.getDoubleValueField(GestureField.swipeProgress)
        let positionX = event.getDoubleValueField(GestureField.positionX)
        let positionY = event.getDoubleValueField(GestureField.positionY)
        let velocityX = event.getDoubleValueField(GestureField.velocityX)
        let velocityY = event.getDoubleValueField(GestureField.velocityY)
        let swipeMask = event.getIntegerValueField(GestureField.swipeMask)

        let includesVelocity =
            velocityX != 0 || velocityY != 0 || phase == Phase.ended

        var payload = Data()
        payload.reserveCapacity(includesVelocity ? 96 : 68)

        payload.appendLittleEndian(
            event.timestamp == 0 ? mach_absolute_time() : event.timestamp
        )
        payload.appendLittleEndian(UInt64(0)) // sender ID
        payload.appendLittleEndian(UInt32(0)) // options
        payload.appendLittleEndian(UInt32(0)) // attribute length
        payload.appendLittleEndian(UInt32(includesVelocity ? 2 : 1))

        // IOHIDFluidTouchGestureData
        payload.appendLittleEndian(UInt32(40)) // record size
        payload.appendLittleEndian(UInt32(23)) // kIOHIDEventTypeFluidTouchGesture
        payload.appendLittleEndian(
            UInt32(truncatingIfNeeded: (phase & 0xFF) << 24)
        )
        payload.append(0) // depth
        payload.append(contentsOf: [UInt8](repeating: 0, count: 3))
        payload.appendLittleEndian(fixedPoint1616(positionX))
        payload.appendLittleEndian(fixedPoint1616(positionY))
        payload.appendLittleEndian(Int32(0)) // position Z
        payload.appendLittleEndian(UInt32(truncatingIfNeeded: swipeMask))
        payload.appendLittleEndian(UInt16(truncatingIfNeeded: motion))
        payload.appendLittleEndian(UInt16(3)) // Dock primary gesture flavor
        payload.appendLittleEndian(fixedPoint1616(progress))

        if includesVelocity {
            // IOHIDVelocityEventData
            payload.appendLittleEndian(UInt32(28)) // record size
            payload.appendLittleEndian(UInt32(9)) // kIOHIDEventTypeVelocity
            payload.appendLittleEndian(UInt32(0)) // options
            payload.append(1) // depth
            payload.append(contentsOf: [UInt8](repeating: 0, count: 3))
            payload.appendLittleEndian(fixedPoint1616(velocityX))
            payload.appendLittleEndian(fixedPoint1616(velocityY))
            payload.appendLittleEndian(Int32(0)) // velocity Z
        }

        return payload
    }

    static func augmentedData(for event: CGEvent) -> Data? {
        guard let flattenedData = event.__data(allocator: nil) as Data? else {
            return nil
        }

        guard
            flattenedData.count >= 4,
            flattenedData[0] == 0,
            flattenedData[1] == 0,
            flattenedData[2] == 0,
            flattenedData[3] == 2
        else {
            return nil
        }

        let payload = makePayload(for: event)
        guard payload.count <= Int(UInt16.max) else { return nil }

        var augmentedData = flattenedData
        augmentedData.append(UInt8((payload.count >> 8) & 0xFF))
        augmentedData.append(UInt8(payload.count & 0xFF))
        augmentedData.append(UInt8((fieldID >> 8) & 0xFF))
        augmentedData.append(UInt8(fieldID & 0xFF))
        augmentedData.append(contentsOf: payload)

        return augmentedData
    }

    static func augment(_ event: CGEvent) -> CGEvent? {
        guard let augmentedData = augmentedData(for: event) else {
            return nil
        }

        return CGEvent(
            withDataAllocator: nil,
            data: augmentedData as CFData
        )
    }
}

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
        guard let snapshot else { return nil }

        return applyingProjectedIndex(to: snapshot.menuBarSpaceInfo)
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

    private var requiresMacOS27EventAugmentation: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(
                majorVersion: 27,
                minorVersion: 0,
                patchVersion: 0
            )
        )
    }

    @ObservationIgnored
    private lazy var switchCoordinator = SpaceSwitchCoordinator(
        dependencies: .init(
            loadContext: { [weak self] displayIdentifier in
                self?.freshSwitchContext(for: displayIdentifier)
            },
            postStep: { [weak self] gestureMode, direction, velocity in
                guard let self else {
                    return false
                }

                switch gestureMode {
                case .instant:
                    return autoreleasepool {
                        self.postInstantGesture(direction, velocity: velocity)
                    }
                case .missionControl:
                    return self.postMissionControlGesture(direction)
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
        guard let newSnapshot = loadSpaceSnapshot() else {
            // Preserve the previous snapshot for menu presentation, but never
            // return stale topology to a command submission.
            return nil
        }

        snapshot = newSnapshot

        switchCoordinator.reconcile(
            topologies: coordinatorTopologies(in: newSnapshot),
            reason: reason
        )

        return newSnapshot
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

    private func applyingProjectedIndex(
        to info: SpaceInfo
    ) -> SpaceInfo {
        guard
            let topology = topology(from: info),
            let projectedIndex = switchCoordinator.projectedIndex(for: topology),
            info.spaceIDs.indices.contains(projectedIndex),
            projectedIndex != info.currentIndex
        else {
            return info
        }

        return SpaceInfo(
            currentIndex: projectedIndex,
            spaceCount: info.spaceCount,
            spaceIDs: info.spaceIDs,
            currentSpaceID: info.currentSpaceID,
            currentSpaceType: info.currentSpaceType,
            displayIdentifier: info.displayIdentifier,
            frontmostBundleID: info.frontmostBundleID
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

    private func dockSwipeFlagBits(for direction: Direction) -> Int64 {
        var flagsProgress = Float.leastNonzeroMagnitude
        if direction == .left {
            flagsProgress.negate()
        }

        return Int64(Int32(bitPattern: flagsProgress.bitPattern))
    }

    private func modernGestureVelocity(
        _ velocity: Double,
        direction: Direction
    ) -> Double {
        let magnitude = velocity.isFinite
            ? min(max(abs(velocity), 1), kMacOS27MaximumGestureVelocity)
            : kMacOS27MaximumGestureVelocity

        return direction == .right ? -magnitude : magnitude
    }

    private func modernGestureProgress(
        _ progress: Double?,
        direction: Direction
    ) -> Double {
        let defaultProgress =
            direction == .right
            ? kMacOS27ProgressMagnitude
            : -kMacOS27ProgressMagnitude
        let appProgress = progress ?? defaultProgress
        let nonzeroProgress =
            appProgress == 0 ? defaultProgress : appProgress

        // macOS 27 interprets the serialized swipe direction opposite to the
        // direction used by the existing public CGEvent fields.
        return -nonzeroProgress
    }

    private func makeGestureEvent() -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }

        event.setIntegerValueField(
            GestureField.eventType,
            value: EventType.gesture
        )
        event.setIntegerValueField(
            kSyntheticMarkerField,
            value: kSyntheticMarkerValue
        )

        return event
    }

    private func makeDockSwipeEvent(
        phase: Int64,
        direction: Direction,
        velocity: Double?,
        progress: Double? = nil
    ) -> CGEvent? {
        let requiresAugmentation = requiresMacOS27EventAugmentation
        let velocityX = velocity.map {
            direction == .right ? $0 : -$0
        }
        let flagBits = dockSwipeFlagBits(for: direction)

        guard let event = CGEvent(source: nil) else { return nil }

        event.setIntegerValueField(
            GestureField.eventType,
            value: EventType.dockControl
        )
        event.setIntegerValueField(
            GestureField.hidType,
            value: kDockSwipeHIDType
        )
        event.setIntegerValueField(GestureField.phase, value: phase)
        event.setIntegerValueField(
            GestureField.swipeMotion,
            value: Motion.horizontal
        )
        event.setDoubleValueField(GestureField.scrollY, value: 0)
        event.setIntegerValueField(
            kSyntheticMarkerField,
            value: kSyntheticMarkerValue
        )

        if requiresAugmentation {
            event.setDoubleValueField(
                GestureField.swipeProgress,
                value: modernGestureProgress(progress, direction: direction)
            )
            event.setIntegerValueField(
                GestureField.phaseAlias,
                value: phase
            )
            event.setDoubleValueField(
                GestureField.positionX,
                value: 0.1
            )
            event.setDoubleValueField(
                GestureField.zoomDeltaY,
                value: 3
            )
            event.setDoubleValueField(
                GestureField.sourceUnixProcessIDAlias,
                value: Double(mach_absolute_time())
            )

            // The serialized Dock trace only carries velocity on its ending
            // phase. Keeping the earlier phases velocity-free avoids them
            // being interpreted as separate swipes on macOS 27.
            if phase == Phase.ended, let velocity {
                event.setDoubleValueField(
                    GestureField.velocityX,
                    value: modernGestureVelocity(velocity, direction: direction)
                )
            }

            return DockEventPayload.augment(event)
        }

        if let progress {
            event.setDoubleValueField(
                GestureField.swipeProgress,
                value: progress
            )
        }
        event.setIntegerValueField(
            GestureField.scrollFlags,
            value: flagBits
        )
        event.setDoubleValueField(
            GestureField.zoomDeltaX,
            value: kFltTrueMin
        )
        if let velocityX {
            event.setDoubleValueField(
                GestureField.velocityX,
                value: velocityX
            )
            event.setDoubleValueField(GestureField.velocityY, value: 0)
        }

        return event
    }

    private func paceModernGesturePhase() {
        guard requiresMacOS27EventAugmentation else { return }

        usleep(kMacOS27GesturePhaseDelay)
    }

    /// Synthetic DockSwipe trace for instant switching outside Mission Control.
    @discardableResult
    private func postInstantGesture(
        _ direction: Direction,
        velocity: Double? = nil
    ) -> Bool {
        let velocity = velocity ?? instantGestureVelocity

        guard postDockSwipe(
            phase: Phase.began,
            direction: direction,
            velocity: velocity
        ) else {
            return false
        }
        paceModernGesturePhase()

        guard postDockSwipe(
            phase: Phase.changed,
            direction: direction,
            velocity: velocity
        ) else {
            return false
        }
        paceModernGesturePhase()

        return postDockSwipe(
            phase: Phase.ended,
            direction: direction,
            velocity: velocity
        )
    }

    @discardableResult
    private func postDockSwipe(
        phase: Int64,
        direction: Direction,
        velocity: Double
    ) -> Bool {
        guard let gestureEvent = makeGestureEvent(),
            let dockEvent = makeDockSwipeEvent(
                phase: phase,
                direction: direction,
                velocity: velocity
            )
        else { return false }

        dockEvent.post(tap: .cgSessionEventTap)
        gestureEvent.post(tap: .cgSessionEventTap)

        return true
    }

    @discardableResult
    private func postMissionControlGesture(_ direction: Direction) -> Bool {
        let isRight = direction == .right
        let progressSteps: [Double] = [0.25, 0.5, 0.75]
        let progress = isRight ? 1.05 : -1.05
        let velocity = 200.0

        guard let beginGesture = makeGestureEvent(),
            let beginDock = makeDockSwipeEvent(
                phase: Phase.began,
                direction: direction,
                velocity: nil
            )
        else { return false }

        beginGesture.post(tap: .cgSessionEventTap)
        beginDock.post(tap: .cgSessionEventTap)
        paceModernGesturePhase()

        for step in progressSteps {
            guard let changedDock = makeDockSwipeEvent(
                phase: Phase.changed,
                direction: direction,
                velocity: velocity,
                progress: isRight ? step : -step
            ) else {
                return false
            }

            changedDock.post(tap: .cgSessionEventTap)
            paceModernGesturePhase()
        }

        guard let endGesture = makeGestureEvent(),
            let endDock = makeDockSwipeEvent(
                phase: Phase.ended,
                direction: direction,
                velocity: velocity,
                progress: progress
            )
        else { return false }

        endGesture.post(tap: .cgSessionEventTap)
        endDock.post(tap: .cgSessionEventTap)

        return true
    }

}

// MARK: - Logger

extension Logger {
    fileprivate static let spaceSwitcher = Logger(category: "SpaceSwitcher")
}
