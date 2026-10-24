//
//  SpaceSnapshot.swift
//  Blink
//

import Foundation

struct SpaceSnapshot {
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

    /// The Spaces shown on a physical display, identified by its UUID string.
    func spaceInfo(containingDisplay physicalDisplayIdentifier: String) -> SpaceInfo? {
        spaceInfoByDisplay[physicalDisplayIdentifier]
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

        return SpaceSnapshot(
            spaceInfoByDisplay: spaceInfoByDisplay,
            fallbackSpaceInfo: fallbackSpaceInfo,
            menuBarDisplayIdentifier: menuBarDisplayIdentifier
        )
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
