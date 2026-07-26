import AppKit
import CoreGraphics
import Foundation

nonisolated struct WindowDescriptor: Equatable, Sendable {
    let ownerName: String
    let ownerBundleID: String?
    let layer: Int
    let bounds: CGRect
}

nonisolated enum WindowServerParseResult: Equatable, Sendable {
    case verified([WindowDescriptor])
    case unknown
}

/// Parses only Dock records needed by overlay classification. A record that
/// identifies itself as Dock is never discarded: incomplete or unverifiable
/// evidence makes the entire observation unknown.
nonisolated struct WindowServerWindowParser: Sendable {
    func parse(
        _ rawWindows: [[String: Any]],
        verifiedDockBundleIDsByPID: [pid_t: String]
    ) -> WindowServerParseResult {
        var windows: [WindowDescriptor] = []

        for value in rawWindows {
            guard value[kCGWindowOwnerName as String] as? String == "Dock" else {
                continue
            }
            guard
                let ownerPID = integer(value[kCGWindowOwnerPID as String]).map(pid_t.init),
                verifiedDockBundleIDsByPID[ownerPID] == "com.apple.dock",
                let layer = integer(value[kCGWindowLayer as String]),
                let rawBounds = value[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: rawBounds)
            else {
                return .unknown
            }

            windows.append(
                WindowDescriptor(
                    ownerName: "Dock",
                    ownerBundleID: "com.apple.dock",
                    layer: layer,
                    bounds: bounds
                )
            )
        }

        return .verified(windows)
    }

    private func integer(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            value
        case let value as NSNumber:
            value.intValue
        default:
            nil
        }
    }
}

nonisolated struct OverlayClassifier: Sendable {
    private enum Layer {
        static let thumbnail = 17
        static let backdrop = 18
        static let preview = 20
        static let fullscreenBacking = -2_147_483_622
        static let wallpaper = -2_147_483_624

        static let overlayLayers: Set<Int> = [
            thumbnail,
            backdrop,
            preview,
            fullscreenBacking,
            wallpaper,
        ]
    }

    func classify(
        windows: [WindowDescriptor],
        displayBounds: CGRect?
    ) -> OverlayMode {
        guard let displayBounds, displayBounds.isUsableDisplayBounds else {
            return .unknown
        }

        let unverifiedDockSignals = windows.filter {
            guard
                $0.ownerName == "Dock",
                $0.ownerBundleID != "com.apple.dock",
                [Layer.thumbnail, Layer.backdrop, Layer.preview].contains($0.layer)
            else {
                return false
            }
            return !$0.bounds.isUsableWindowBounds
                || isSpatiallyAssociated($0.bounds, with: displayBounds)
        }
        guard unverifiedDockSignals.isEmpty else { return .unknown }

        let dockWindows = windows.filter {
            $0.ownerName == "Dock" && $0.ownerBundleID == "com.apple.dock"
        }
        guard !dockWindows.contains(where: {
            Layer.overlayLayers.contains($0.layer) && !$0.bounds.isUsableWindowBounds
        }) else {
            return .unknown
        }

        let displayWindows = dockWindows.filter {
            isSpatiallyAssociated($0.bounds, with: displayBounds)
        }
        let backdrops = displayWindows.filter {
            $0.layer == Layer.backdrop
                && coversDisplay($0.bounds, displayBounds: displayBounds)
        }
        guard !backdrops.isEmpty else { return .none }

        if hasStrongMissionControlSignal(
            in: displayWindows,
            displayBounds: displayBounds
        ) {
            return .missionControl
        }

        // Captured traces contain a small layer-20 Dock HUD in App Exposé. It is
        // not a display preview and must not be counted as one. Mission Control
        // has two display-covering layer-20 surfaces on a single display, while
        // App Exposé has one.
        let displayPreviews = displayWindows.filter {
            $0.layer == Layer.preview
                && coversDisplay($0.bounds, displayBounds: displayBounds)
        }
        if displayPreviews.count >= 2 {
            return .missionControl
        }
        if displayPreviews.count == 1 {
            return .appExpose
        }
        // A display-covering Dock backdrop is an unresolved transition, not a
        // normal desktop. Routing must fail open until another signal appears.
        return .unknown
    }

    private func hasStrongMissionControlSignal(
        in windows: [WindowDescriptor],
        displayBounds: CGRect
    ) -> Bool {
        let insetWindows = windows.filter {
            isInset($0.bounds, inside: displayBounds)
        }
        if insetWindows.contains(where: { $0.layer == Layer.thumbnail }) {
            return true
        }

        let backings = insetWindows.filter {
            $0.layer == Layer.fullscreenBacking
        }
        let wallpapers = insetWindows.filter { $0.layer == Layer.wallpaper }
        return backings.contains { backing in
            wallpapers.contains { wallpaper in
                geometricallyMatches(backing.bounds, wallpaper.bounds)
            }
        }
    }

    private func isSpatiallyAssociated(
        _ windowBounds: CGRect,
        with displayBounds: CGRect
    ) -> Bool {
        guard windowBounds.isUsableWindowBounds else { return false }
        let intersection = windowBounds.intersection(displayBounds)
        guard !intersection.isNull, !intersection.isEmpty else { return false }

        let intersectionArea = intersection.area
        // A display-local window is mostly inside the target. A deliberately
        // global window is relevant only when it covers most of the target.
        return intersectionArea / windowBounds.area >= 0.8
            || intersectionArea / displayBounds.area >= 0.8
    }

    private func coversDisplay(
        _ windowBounds: CGRect,
        displayBounds: CGRect
    ) -> Bool {
        let intersection = windowBounds.intersection(displayBounds)
        guard !intersection.isNull, !intersection.isEmpty else { return false }
        return intersection.area / displayBounds.area >= 0.8
    }

    private func isInset(_ windowBounds: CGRect, inside displayBounds: CGRect) -> Bool {
        guard displayBounds.contains(windowBounds) else { return false }
        return displayBounds.width - windowBounds.width > 40
            && displayBounds.height - windowBounds.height > 40
    }

    private func geometricallyMatches(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 10
            && abs(lhs.minY - rhs.minY) < 10
            && abs(lhs.width - rhs.width) < 10
            && abs(lhs.height - rhs.height) < 10
    }
}

private extension CGRect {
    nonisolated var area: CGFloat { width * height }

    nonisolated var isUsableWindowBounds: Bool {
        !isNull && !isInfinite
            && origin.x.isFinite && origin.y.isFinite
            && width.isFinite && height.isFinite
            && width > 0 && height > 0
    }

    nonisolated var isUsableDisplayBounds: Bool { isUsableWindowBounds }
}

nonisolated struct CoreGraphicsOverlayDetector: OverlayDetecting, Sendable {
    let displayLocator: any DisplayLocating
    let classifier = OverlayClassifier()
    let parser = WindowServerWindowParser()

    init(displayLocator: any DisplayLocating = DisplayLocator()) {
        self.displayLocator = displayLocator
    }

    func detect(on displayID: DisplayID) -> OverlayMode {
        let startedAt = ProcessInfo.processInfo.systemUptime
        defer {
            DiagnosticsStore.shared.recordOverlayScan(
                startedAt: startedAt,
                endedAt: ProcessInfo.processInfo.systemUptime
            )
        }

        guard
            let rawWindows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly],
                kCGNullWindowID
            ) as? [[String: Any]]
        else {
            return .unknown
        }

        let dockPIDs = Set(rawWindows.compactMap { value -> pid_t? in
            guard value[kCGWindowOwnerName as String] as? String == "Dock" else {
                return nil
            }
            if let pid = value[kCGWindowOwnerPID as String] as? Int {
                return pid_t(pid)
            }
            if let pid = value[kCGWindowOwnerPID as String] as? NSNumber {
                return pid_t(pid.intValue)
            }
            return nil
        })
        let verifiedDockBundleIDsByPID = Dictionary(
            uniqueKeysWithValues: dockPIDs.compactMap { pid in
                NSRunningApplication(processIdentifier: pid)?.bundleIdentifier.map {
                    (pid, $0)
                }
            }
        )
        guard case .verified(let windows) = parser.parse(
            rawWindows,
            verifiedDockBundleIDsByPID: verifiedDockBundleIDsByPID
        ) else {
            return .unknown
        }

        return classifier.classify(
            windows: windows,
            displayBounds: displayLocator.bounds(for: displayID)
        )
    }
}
