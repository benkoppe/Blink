//
//  SpaceSnapshot.swift
//  Blink
//

import Foundation

struct SpaceSnapshot {
    /// How macOS assigns Spaces to displays ("Displays have separate Spaces").
    enum Layout: Equatable {
        /// One set of Spaces spans every display. macOS keys it "Main".
        case shared(SpaceInfo)
        /// Each display has its own Spaces, keyed by display UUID.
        case perDisplay([String: SpaceInfo], fallback: SpaceInfo)
    }

    static let sharedDisplayIdentifier = "Main"

    let layout: Layout
    let menuBarDisplayIdentifier: String?

    var spaceInfos: [SpaceInfo] {
        switch layout {
        case .shared(let info): [info]
        case .perDisplay(let infoByDisplay, _): Array(infoByDisplay.values)
        }
    }

    var menuBarSpaceInfo: SpaceInfo {
        switch layout {
        case .shared(let info):
            return info
        case .perDisplay(let infoByDisplay, let fallback):
            return menuBarDisplayIdentifier.flatMap { infoByDisplay[$0] } ?? fallback
        }
    }

    /// The Spaces shown on a physical display, identified by its UUID string.
    func spaceInfo(containingDisplay physicalDisplayIdentifier: String) -> SpaceInfo? {
        switch layout {
        case .shared(let info): info
        case .perDisplay(let infoByDisplay, _): infoByDisplay[physicalDisplayIdentifier]
        }
    }

    var layoutDescription: String {
        switch layout {
        case .shared(let info):
            "shared (\(info.spaceCount) Spaces)"
        case .perDisplay(let infoByDisplay, _):
            "per-display ("
                + infoByDisplay.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value.spaceCount) Spaces" }
                .joined(separator: ", ") + ")"
        }
    }

    /// Parses the output of `CGSCopyManagedDisplaySpaces`.
    static func parse(
        rawDisplays: NSArray,
        globalActiveSpaceID: UInt64,
        menuBarDisplayIdentifier: String?,
        frontmostBundleID: String?
    ) -> SpaceSnapshot? {
        var spaceInfoByDisplay: [String: SpaceInfo] = [:]
        var fallbackSpaceInfo: SpaceInfo?

        for item in rawDisplays {
            guard let displayDict = item as? NSDictionary,
                let info = parseSpaceInfo(
                    from: displayDict,
                    globalActiveSpaceID: globalActiveSpaceID,
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

        let layout: Layout =
            if let shared = spaceInfoByDisplay[sharedDisplayIdentifier] {
                .shared(shared)
            } else {
                .perDisplay(spaceInfoByDisplay, fallback: fallbackSpaceInfo)
            }

        return SpaceSnapshot(layout: layout, menuBarDisplayIdentifier: menuBarDisplayIdentifier)
    }

    private static func parseSpaceInfo(
        from displayDict: NSDictionary,
        globalActiveSpaceID: UInt64,
        frontmostBundleID: String?
    ) -> SpaceInfo? {
        guard
            let displayIdentifier = displayDict["Display Identifier"] as? String,
            !displayIdentifier.isEmpty,
            let spacesArray = displayDict["Spaces"] as? NSArray
        else {
            return nil
        }

        let currentSpaceDict = displayDict["Current Space"] as? NSDictionary
        let perDisplayActiveSpaceID = (currentSpaceDict?["id64"] as? NSNumber)?.uint64Value
        let currentSpaceType = (currentSpaceDict?["type"] as? NSNumber)?.intValue
        let activeSpaceID = perDisplayActiveSpaceID ?? globalActiveSpaceID

        let spaceIDs: [UInt64] = spacesArray.compactMap { item in
            guard
                let spaceDict = item as? NSDictionary,
                let spaceID = (spaceDict["id64"] as? NSNumber)?.uint64Value,
                spaceID != 0
            else { return nil }
            return spaceID
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
}
