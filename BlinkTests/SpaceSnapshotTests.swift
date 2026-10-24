import Foundation
import Testing

@testable import Blink

@Suite("Space snapshot")
struct SpaceSnapshotTests {
    private let builtInDisplay = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
    private let externalDisplay = "F7B281F3-5206-4B1D-8C36-FC0FE308B045"

    private func display(_ identifier: String, spaceIDs: [UInt64], current: UInt64) -> NSDictionary {
        [
            "Display Identifier": identifier,
            "Current Space": ["id64": NSNumber(value: current), "type": NSNumber(value: 0)],
            "Spaces": spaceIDs.map { ["id64": NSNumber(value: $0), "type": NSNumber(value: 0)] },
        ]
    }

    private func snapshot(_ displays: [NSDictionary], menuBar: String? = nil) throws -> SpaceSnapshot {
        try #require(
            SpaceSnapshot.parse(
                rawDisplays: displays as NSArray,
                globalActiveSpaceID: 1,
                menuBarDisplayIdentifier: menuBar,
                frontmostBundleID: nil
            )
        )
    }

    @Test("Shared Spaces are found from any physical display")
    func sharedSpaces() throws {
        let snapshot = try snapshot([display("Main", spaceIDs: [1, 2, 3], current: 2)])

        for physicalDisplay in [builtInDisplay, externalDisplay] {
            let info = try #require(snapshot.spaceInfo(containingDisplay: physicalDisplay))
            #expect(info.spaceIDs == [1, 2, 3])
            #expect(info.currentIndex == 1)
            #expect(info.displayIdentifier == "Main")
        }
    }

    @Test("Separate Spaces are found only from their own display")
    func separateSpaces() throws {
        let snapshot = try snapshot([
            display(builtInDisplay, spaceIDs: [1, 2], current: 1),
            display(externalDisplay, spaceIDs: [7, 8, 9], current: 9),
        ])

        #expect(snapshot.spaceInfo(containingDisplay: builtInDisplay)?.spaceIDs == [1, 2])
        #expect(snapshot.spaceInfo(containingDisplay: externalDisplay)?.currentIndex == 2)
        #expect(snapshot.spaceInfo(containingDisplay: "00000000-0000-0000-0000-000000000000") == nil)
    }
}
