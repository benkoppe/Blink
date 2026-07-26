import CoreGraphics
import Foundation
import Testing

@testable import Blink

@MainActor
@Suite("Space platform and diagnostics")
struct SpacePlatformTests {
    @Test("Gesture context fixes route, display, overlay, and posting mode")
    func gestureContextIsAtomic() {
        let display = DisplayID(rawValue: "display-a")!
        let otherDisplay = DisplayID(rawValue: "display-b")!
        let desktop = routingLease(generation: 4, displayID: display)
        let context = desktop.makeContext(
            sessionGeneration: 9,
            requiredGeneration: 4,
            currentDisplayID: display,
            at: 100,
            missionControlSyntheticState: .available
        )
        #expect(context.route == .blink)
        #expect(context.targetDisplayID == display)
        #expect(context.capturedOverlayMode == .none)
        #expect(context.requiredPostingMode == .instant)
        #expect(context.isAuthoritativeBlinkContext)

        let disagreement = desktop.makeContext(
            sessionGeneration: 10,
            requiredGeneration: 4,
            currentDisplayID: otherDisplay,
            at: 100,
            missionControlSyntheticState: .available
        )
        #expect(disagreement.route == .system)
        #expect(disagreement.capturedOverlayMode == .unknown)
        #expect(disagreement.requiredPostingMode == nil)
    }

    @Test("Unowned terminal swipe events fail open")
    func nativeSwipeRoutingFailsOpenWithoutOwnership() {
        var state = NativeSwipeRoutingState()
        #expect(!state.shouldSuppress)
        let unownedTerminalWasSuppressed = state.finish()
        #expect(!unownedTerminalWasSuppressed)

        state.begin(ownedByBlink: true)
        #expect(state.shouldSuppress)
        let blinkTerminalWasSuppressed = state.finish()
        #expect(blinkTerminalWasSuppressed)
        #expect(!state.shouldSuppress)

        state.begin(ownedByBlink: false)
        #expect(!state.shouldSuppress)
        let systemTerminalWasSuppressed = state.finish()
        #expect(!systemTerminalWasSuppressed)

        state.begin(ownedByBlink: true)
        state.reset()
        #expect(!state.shouldSuppress)
        let resetTerminalWasSuppressed = state.finish()
        #expect(!resetTerminalWasSuppressed)
    }

    @Test("Event-tap recovery tokens cannot outlive intentional disable")
    func eventTapRecoveryHonorsLifecycleGeneration() {
        let lifecycle = EventTapRecoveryLifecycle()
        let token = lifecycle.beginEnable()
        var recoveries = 0
        lifecycle.disable()
        lifecycle.performIfCurrent(token) { recoveries += 1 }
        #expect(recoveries == 0)
        #expect(!lifecycle.isCurrent(token))
    }

    @Test("Diagnostics report process lifetime rather than system uptime")
    func diagnosticsReportProcessUptime() {
        let store = DiagnosticsStore()
        let report = store.report(version: "test", build: "1")
        let systemUptime = Int(ProcessInfo.processInfo.systemUptime)
        let uptimeLine = report.split(separator: "\n").first {
            $0.hasPrefix("Process uptime: ")
        }
        let processUptime = uptimeLine.flatMap {
            Int($0.dropFirst("Process uptime: ".count).dropLast(" seconds".count))
        }
        #expect(processUptime != nil)
        #expect(processUptime! >= 0)
        #expect(processUptime! < systemUptime)
    }

    @Test("Diagnostics report overlay scan lifetime metrics")
    func diagnosticsReportOverlayMetrics() {
        let store = DiagnosticsStore()
        store.recordOverlayScan(startedAt: 10, endedAt: 10.01)
        store.recordOverlayScan(startedAt: 20, endedAt: 20.03)

        let report = store.report(version: "test", build: "1")
        #expect(report.contains("count=2 lifetime-average-hz=0.100"))
        #expect(report.contains("duration-ms(avg/max)=20.000/30.000"))
    }

    @Test("Overlay metrics tolerate scans completing out of start order")
    func diagnosticsOverlayMetricsUseFullTimeRange() {
        let store = DiagnosticsStore()
        store.recordOverlayScan(startedAt: 20, endedAt: 21)
        store.recordOverlayScan(startedAt: 10, endedAt: 30)

        let report = store.report(version: "test", build: "1")
        #expect(report.contains("count=2 lifetime-average-hz=0.050"))
    }

    @Test("Space identifiers and topologies reject invalid values")
    func topologyRejectsInvalidValues() {
        #expect(DisplayID(rawValue: "") == nil)
        #expect(ManagedDisplayID(rawValue: "") == nil)
        #expect(SpaceID(rawValue: 0) == nil)

        let managedDisplayID = ManagedDisplayID(rawValue: "display-a")!
        let first = SpaceID(rawValue: 100)!
        let second = SpaceID(rawValue: 101)!
        let missing = SpaceID(rawValue: 999)!

        #expect(
            DisplayTopology(
                managedDisplayID: managedDisplayID,
                spaceIDs: [],
                currentSpaceID: first
            ) == nil
        )
        #expect(
            DisplayTopology(
                managedDisplayID: managedDisplayID,
                spaceIDs: [first, first],
                currentSpaceID: first
            ) == nil
        )
        #expect(
            DisplayTopology(
                managedDisplayID: managedDisplayID,
                spaceIDs: [first, second],
                currentSpaceID: missing
            ) == nil
        )
        #expect(
            DisplayTopology(
                managedDisplayID: managedDisplayID,
                spaceIDs: [first, second],
                currentSpaceID: first
            ) != nil
        )
    }

    @Test("CGS parser accepts one shared Main topology for every physical display")
    func parserAcceptsSharedMainTopology() throws {
        let displayA = DisplayID(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let snapshot = try CGSSpaceSystemClient.parseSnapshot(
            [[
                "Display Identifier": "Main",
                "Current Space": ["id64": NSNumber(value: 100)],
                "Spaces": [
                    ["id64": NSNumber(value: 100)],
                    ["id64": NSNumber(value: 101)],
                ],
            ]] as NSArray,
            globalActiveSpaceID: 999,
            menuBarDisplayID: displayA
        )

        #expect(Set(snapshot.topologiesByManagedDisplay.keys) == [.main])
        #expect(snapshot.managedDisplayID(for: displayA) == .main)
        #expect(snapshot.menuBarTopology?.managedDisplayID == .main)
    }

    @Test("CGS parser is strict and all-or-nothing")
    func parserRejectsMalformedEntries() {
        let uuid = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let valid: NSDictionary = [
            "Display Identifier": uuid,
            "Current Space": ["id64": NSNumber(value: 100)],
            "Spaces": [["id64": NSNumber(value: 100)]],
        ]

        expectParsingError(
            [valid, "not-a-display"] as NSArray,
            .invalidDisplayEntry(index: 1)
        )
        expectParsingError(
            [[
                "Display Identifier": "not-a-managed-display",
                "Spaces": [["id64": NSNumber(value: 100)]],
            ]] as NSArray,
            .invalidDisplayIdentifier(index: 0)
        )
        expectParsingError(
            [[
                "Display Identifier": uuid,
                "Spaces": ["not-a-space"],
            ]] as NSArray,
            .invalidSpaceEntry(displayIndex: 0, spaceIndex: 0)
        )
        expectParsingError(
            [[
                "Display Identifier": uuid,
                "Current Space": ["id64": NSNumber(value: 100)],
                "Spaces": [
                    ["id64": NSNumber(value: 100)],
                    ["id64": NSNumber(value: 0)],
                ],
            ]] as NSArray,
            .invalidSpaceID(displayIndex: 0, spaceIndex: 1)
        )
        for malformedID in [
            NSNumber(value: 0),
            NSNumber(value: -1),
            NSNumber(value: true),
            NSNumber(value: 1.5),
        ] {
            expectParsingError(
                [[
                    "Display Identifier": uuid,
                    "Spaces": [["id64": malformedID]],
                ]] as NSArray,
                .invalidSpaceID(displayIndex: 0, spaceIndex: 0)
            )
        }
        for malformedID in [
            NSNumber(value: 0),
            NSNumber(value: -1),
            NSNumber(value: true),
            NSNumber(value: 1.5),
        ] {
            expectParsingError(
                [[
                    "Display Identifier": uuid,
                    "Current Space": ["id64": malformedID],
                    "Spaces": [["id64": NSNumber(value: 100)]],
                ]] as NSArray,
                .invalidCurrentSpaceID(displayIndex: 0)
            )
        }
        expectParsingError(
            [[
                "Display Identifier": uuid,
                "Current Space": ["id64": NSNumber(value: 999)],
                "Spaces": [["id64": NSNumber(value: 100)]],
            ]] as NSArray,
            .currentSpaceOutsideTopology(displayIndex: 0, SpaceID(rawValue: 999)!)
        )
        expectParsingError(
            [[
                "Display Identifier": uuid,
                "Spaces": [
                    ["id64": NSNumber(value: 100)],
                    ["id64": NSNumber(value: 100)],
                ],
            ]] as NSArray,
            .duplicateSpaceID(displayIndex: 0, SpaceID(rawValue: 100)!)
        )
    }

    @Test("CGS global active fallback requires an absent key and topology membership")
    func parserRestrictsGlobalFallback() throws {
        let uuid = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let withoutCurrent: NSDictionary = [
            "Display Identifier": uuid,
            "Spaces": [
                ["id64": NSNumber(value: 100)],
                ["id64": NSNumber(value: 101)],
            ],
        ]
        let snapshot = try CGSSpaceSystemClient.parseSnapshot(
            [withoutCurrent] as NSArray,
            globalActiveSpaceID: 101
        )
        #expect(snapshot.topologiesByManagedDisplay.values.first?.currentSpaceID.rawValue == 101)

        expectParsingError(
            [withoutCurrent] as NSArray,
            .currentSpaceOutsideTopology(displayIndex: 0, SpaceID(rawValue: 999)!),
            globalActiveSpaceID: 999
        )
        expectParsingError(
            [[
                "Display Identifier": uuid,
                "Current Space": "malformed",
                "Spaces": [["id64": NSNumber(value: 100)]],
            ]] as NSArray,
            .invalidCurrentSpace(displayIndex: 0),
            globalActiveSpaceID: 100
        )
    }

    @Test("CGS parser rejects duplicate and mixed topology identities")
    func parserRejectsAmbiguousTopologyShape() {
        func display(_ identifier: String, _ spaceID: UInt64) -> NSDictionary {
            [
                "Display Identifier": identifier,
                "Current Space": ["id64": NSNumber(value: spaceID)],
                "Spaces": [["id64": NSNumber(value: spaceID)]],
            ]
        }

        let uuid = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        expectParsingError(
            [display(uuid, 100), display(uuid, 100)] as NSArray,
            .duplicateDisplayIdentifier(ManagedDisplayID(rawValue: uuid)!)
        )
        expectParsingError(
            [display("Main", 100), display(uuid, 200)] as NSArray,
            .ambiguousSharedTopology
        )
    }

    @Test("Snapshots never choose an arbitrary topology fallback")
    func snapshotHasNoArbitraryFallback() {
        let managed = ManagedDisplayID(
            rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        )!
        let physical = DisplayID(rawValue: managed.rawValue)!
        let unknown = DisplayID(rawValue: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let topology = DisplayTopology(
            managedDisplayID: managed,
            spaceIDs: [SpaceID(rawValue: 100)!],
            currentSpaceID: SpaceID(rawValue: 100)!
        )!
        let snapshot = SystemSpaceSnapshot(
            topologiesByManagedDisplay: [managed: topology],
            menuBarDisplayID: unknown
        )

        #expect(snapshot.topology(for: physical) == topology)
        #expect(snapshot.topology(for: unknown) == nil)
        #expect(snapshot.menuBarTopology == nil)
    }

    @Test("Shared Main remains presentable without the optional menu-bar symbol")
    func sharedMainMenuBarFallbackIsUnambiguous() {
        let topology = DisplayTopology(
            managedDisplayID: .main,
            spaceIDs: [SpaceID(rawValue: 100)!, SpaceID(rawValue: 101)!],
            currentSpaceID: SpaceID(rawValue: 100)!
        )!
        let snapshot = SystemSpaceSnapshot(
            topologiesByManagedDisplay: [.main: topology],
            menuBarDisplayID: nil
        )

        #expect(snapshot.menuBarTopology == topology)
    }

    @Test("Mission Control failure policy is display-scoped and bounded")
    func missionControlCapabilityPolicy() {
        let capability = MissionControlSyntheticCapability()
        let displayA = DisplayID(rawValue: "display-a")!
        let displayB = DisplayID(rawValue: "display-b")!
        #expect(!capability.recordConfirmedNonmovement(on: displayA, at: 100))
        #expect(capability.state(on: displayA) == .available)
        #expect(capability.recordConfirmedNonmovement(on: displayA, at: 101))
        #expect(capability.state(on: displayA) == .unavailableUntilOverlayExit)
        #expect(capability.state(on: displayB) == .available)
        capability.recordAuthoritativeAcknowledgement(on: displayA)
        #expect(capability.state(on: displayA) == .unavailableUntilOverlayExit)
        #expect(!capability.observeOverlay(
            .none,
            on: displayB,
            sampledAtUptime: 102
        ))
        #expect(!capability.observeOverlay(
            .none,
            on: displayA,
            sampledAtUptime: 101
        ))
        #expect(!capability.observeOverlay(
            .missionControl,
            on: displayA,
            sampledAtUptime: 103
        ))
        #expect(capability.state(on: displayA) == .unavailableUntilOverlayExit)
        #expect(capability.observeOverlay(
            .none,
            on: displayA,
            sampledAtUptime: 104
        ))
        #expect(capability.state(on: displayA) == .available)

        #expect(capability.recordPostRejection(on: displayB, at: 200))
        #expect(capability.state(on: displayB) == .unavailableUntilOverlayExit)
    }

    @Test("A newer confirmed overlay exit clears pending nonmovement strikes")
    func missionControlOverlayExitClearsPendingStrike() {
        let capability = MissionControlSyntheticCapability()
        let display = DisplayID(rawValue: "display-a")!

        #expect(!capability.recordConfirmedNonmovement(on: display, at: 100))
        #expect(!capability.observeOverlay(.none, on: display, sampledAtUptime: 99))
        #expect(!capability.observeOverlay(.none, on: display, sampledAtUptime: 101))
        #expect(!capability.recordConfirmedNonmovement(on: display, at: 102))
        #expect(capability.state(on: display) == .available)
    }

    private func expectParsingError(
        _ displays: NSArray,
        _ expected: CGSSpaceParsingError,
        globalActiveSpaceID: UInt64 = 100
    ) {
        do {
            _ = try CGSSpaceSystemClient.parseSnapshot(
                displays,
                globalActiveSpaceID: globalActiveSpaceID
            )
            Issue.record("Expected parser to throw \(expected)")
        } catch let error as CGSSpaceParsingError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Mission Control payload strategy has explicit macOS boundaries")
    func missionControlPayloadStrategyBoundaries() {
        #expect(MissionControlPayloadStrategy.select(for: version(13, 6)) == .unsupported)
        #expect(MissionControlPayloadStrategy.select(for: version(14, 0)) == .legacyProgress)
        #expect(MissionControlPayloadStrategy.select(for: version(25, 9)) == .legacyProgress)
        #expect(MissionControlPayloadStrategy.select(for: version(26, 0)) == .tahoeCompact)
        #expect(MissionControlPayloadStrategy.select(for: version(26, 1)) == .tahoeCompact)
        #expect(
            DockGesturePoster(operatingSystemVersion: version(25, 9)).missionControlStrategy
                == .legacyProgress
        )
        #expect(
            DockGesturePoster(operatingSystemVersion: version(26, 0)).missionControlStrategy
                == .tahoeCompact
        )
        #expect(
            DockGesturePoster.missionControlPayloads(
                strategy: .unsupported,
                direction: .right,
                velocity: 2_000
            ) == nil
        )
    }

    @Test("Tahoe Mission Control payload is the compact Dock-only trace")
    func tahoeMissionControlPayload() {
        let right = DockGesturePoster.missionControlPayloads(
            strategy: .tahoeCompact,
            direction: .right,
            velocity: 2_000
        )!
        #expect(
            right.map(\.phase) == [
                SyntheticGestureProtocol.began,
                SyntheticGestureProtocol.changed,
                SyntheticGestureProtocol.ended,
            ]
        )
        #expect(right.allSatisfy { $0.eventType == SyntheticGestureProtocol.dockControlEventType })
        #expect(right.allSatisfy { $0.hidType == SyntheticGestureProtocol.dockSwipeHIDType })
        #expect(right.allSatisfy { $0.swipeMotion == SyntheticGestureProtocol.horizontalMotion })
        #expect(right.allSatisfy { ($0.progress ?? 0) > 0 })
        #expect(right.allSatisfy { $0.velocityX == 2_000 })
        #expect(right.allSatisfy { $0.velocityY == 2_000 })

        let left = DockGesturePoster.missionControlPayloads(
            strategy: .tahoeCompact,
            direction: .left,
            velocity: 2_000
        )!
        #expect(left.allSatisfy { ($0.progress ?? 0) < 0 })
        #expect(left.allSatisfy { $0.velocityX == -2_000 })
        #expect(left.allSatisfy { $0.velocityY == -2_000 })
    }

    @Test("Pre-Tahoe Mission Control payload is the legacy progress trace")
    func legacyMissionControlPayload() {
        let right = DockGesturePoster.missionControlPayloads(
            strategy: .legacyProgress,
            direction: .right,
            velocity: 9_999
        )!
        #expect(
            right.map(\.eventType) == [
                SyntheticGestureProtocol.gestureEventType,
                SyntheticGestureProtocol.dockControlEventType,
                SyntheticGestureProtocol.dockControlEventType,
                SyntheticGestureProtocol.dockControlEventType,
                SyntheticGestureProtocol.dockControlEventType,
                SyntheticGestureProtocol.gestureEventType,
                SyntheticGestureProtocol.dockControlEventType,
            ]
        )
        #expect(
            right.map(\.phase) == [
                nil,
                SyntheticGestureProtocol.began,
                SyntheticGestureProtocol.changed,
                SyntheticGestureProtocol.changed,
                SyntheticGestureProtocol.changed,
                nil,
                SyntheticGestureProtocol.ended,
            ]
        )
        #expect(right.compactMap(\.progress) == [0.25, 0.5, 0.75, 1.05])
        let rightDock = right.filter {
            $0.eventType == SyntheticGestureProtocol.dockControlEventType
        }
        #expect(rightDock.allSatisfy { $0.hidType == SyntheticGestureProtocol.dockSwipeHIDType })
        #expect(rightDock.allSatisfy { $0.scrollFlags != nil })
        #expect(
            rightDock.allSatisfy { $0.swipeMotion == SyntheticGestureProtocol.horizontalMotion })
        #expect(rightDock.allSatisfy { $0.scrollY == 0 && $0.zoomDeltaX != nil })
        #expect(right.compactMap(\.velocityX) == [200, 200, 200, 200])
        #expect(right.compactMap(\.velocityY) == [0, 0, 0, 0])

        let left = DockGesturePoster.missionControlPayloads(
            strategy: .legacyProgress,
            direction: .left,
            velocity: 9_999
        )!
        #expect(left.compactMap(\.progress) == [-0.25, -0.5, -0.75, -1.05])
        #expect(left.compactMap(\.velocityX) == [-200, -200, -200, -200])
        let leftFlags = left.compactMap(\.scrollFlags)
        #expect(!leftFlags.isEmpty)
        #expect(Set(leftFlags).count == 1)
        #expect(leftFlags.first != rightDock.first?.scrollFlags)
    }
}
