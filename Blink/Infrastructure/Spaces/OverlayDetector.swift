import AppKit
import CoreGraphics
import Foundation

nonisolated enum OverlayMode: String, Equatable, Sendable {
    case none
    case appExpose
    case missionControl
    case unknown
}

nonisolated struct WindowDescriptor: Equatable, Sendable {
    let ownerName: String
    let ownerBundleID: String?
    let layer: Int
    let bounds: CGRect
    let name: String?
}

nonisolated struct OverlayClassifier: Sendable {
    private enum Layer {
        static let thumbnail = 17
        static let backdrop = 18
        static let preview = 20
        static let fullscreenBacking = -2_147_483_622
        static let wallpaper = -2_147_483_624
    }

    func classify(
        windows: [WindowDescriptor],
        displayBounds: CGRect?
    ) -> OverlayMode {
        let dockWindows = windows.filter {
            $0.ownerName == "Dock" && $0.ownerBundleID == "com.apple.dock"
        }
        let hasBackdrop = dockWindows.contains { $0.layer == Layer.backdrop }
        let previewCount = dockWindows.count { $0.layer == Layer.preview }

        if let displayBounds,
            hasStrongMissionControlSignal(
                in: dockWindows,
                displayBounds: displayBounds
            )
        {
            return .missionControl
        }

        if hasBackdrop && previewCount >= 3 {
            return .missionControl
        }
        if hasBackdrop && (1...2).contains(previewCount) {
            return .appExpose
        }
        return .none
    }

    private func hasStrongMissionControlSignal(
        in windows: [WindowDescriptor],
        displayBounds: CGRect
    ) -> Bool {
        let inset = windows.filter {
            displayBounds.width - $0.bounds.width > 40
                && displayBounds.height - $0.bounds.height > 40
        }

        if inset.contains(where: {
            $0.layer == Layer.thumbnail || $0.layer == Layer.wallpaper
        }) {
            return true
        }

        let backings = inset.filter { $0.layer == Layer.fullscreenBacking }
        let wallpapers = inset.filter { $0.layer == Layer.wallpaper }

        return backings.contains { backing in
            wallpapers.contains { wallpaper in
                abs(backing.bounds.width - wallpaper.bounds.width) < 10
                    && abs(backing.bounds.height - wallpaper.bounds.height) < 10
            }
        }
    }
}

nonisolated protocol OverlayDetecting: Sendable {
    func detect(on displayID: DisplayID) -> OverlayMode
}

nonisolated struct CoreGraphicsOverlayDetector: OverlayDetecting, Sendable {
    let displayLocator: any DisplayLocating
    let classifier = OverlayClassifier()

    init(displayLocator: any DisplayLocating = DisplayLocator()) {
        self.displayLocator = displayLocator
    }

    func detect(on displayID: DisplayID) -> OverlayMode {
        guard
            let rawWindows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly],
                kCGNullWindowID
            ) as? [[String: Any]]
        else {
            return .unknown
        }

        let windows = rawWindows.compactMap { value -> WindowDescriptor? in
            guard
                let ownerName = value[kCGWindowOwnerName as String] as? String,
                let layer = value[kCGWindowLayer as String] as? Int,
                let rawBounds = value[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: rawBounds)
            else {
                return nil
            }

            let ownerBundleID: String? =
                if ownerName == "Dock",
                    let ownerPID = value[kCGWindowOwnerPID as String] as? pid_t
                {
                    NSRunningApplication(
                        processIdentifier: ownerPID
                    )?.bundleIdentifier
                } else {
                    nil
                }

            return WindowDescriptor(
                ownerName: ownerName,
                ownerBundleID: ownerBundleID,
                layer: layer,
                bounds: bounds,
                name: value[kCGWindowName as String] as? String
            )
        }

        return classifier.classify(
            windows: windows,
            displayBounds: displayLocator.bounds(for: displayID)
        )
    }
}
