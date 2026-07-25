import CoreGraphics
import Foundation
import Testing

@testable import Blink

@MainActor
@Suite("Gesture and platform domain")
struct GestureAndPlatformTests {
    @Test("Swipe recognizer emits a horizontal gesture")
    func recognizerEmitsSwipe() {
        var recognizer = SwipeRecognizer()
        let configuration = SwipeRecognizer.Configuration(
            flipsDirection: false,
            allowsSameDirectionRepeat: false,
            sameDirectionRepeatSensitivity: 0.06
        )

        let first = GestureSample(touches: touches(at: 0))
        let second = GestureSample(touches: touches(at: 0.08))
        #expect(
            recognizer.consume(
                first,
                configuration: configuration,
                ignoreNewGesture: false
            ) == nil
        )
        let result = recognizer.consume(
            second,
            configuration: configuration,
            ignoreNewGesture: false
        )
        #expect(result?.direction == .right)
        #expect(result?.fingerCount == 3)
    }

    @Test("Ignored gesture sessions remain ignored")
    func recognizerIgnoresWholeSession() {
        var recognizer = SwipeRecognizer()
        let configuration = SwipeRecognizer.Configuration(
            flipsDirection: false,
            allowsSameDirectionRepeat: true,
            sameDirectionRepeatSensitivity: 0
        )
        _ = recognizer.consume(
            GestureSample(touches: touches(at: 0)),
            configuration: configuration,
            ignoreNewGesture: true
        )
        let result = recognizer.consume(
            GestureSample(touches: touches(at: 0.2)),
            configuration: configuration,
            ignoreNewGesture: false
        )
        #expect(result == nil)
    }

    @Test("Overlay classifier distinguishes Expose and Mission Control")
    func overlayClassifierDistinguishesModes() {
        let classifier = OverlayClassifier()
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let backdrop = WindowDescriptor(
            ownerName: "Dock",
            ownerBundleID: "com.apple.dock",
            layer: 18,
            bounds: bounds,
            name: nil
        )
        let preview = WindowDescriptor(
            ownerName: "Dock",
            ownerBundleID: "com.apple.dock",
            layer: 20,
            bounds: bounds,
            name: nil
        )

        #expect(
            classifier.classify(
                windows: [backdrop, preview],
                displayBounds: bounds
            ) == .appExpose
        )
        #expect(
            classifier.classify(
                windows: [backdrop, preview, preview],
                displayBounds: bounds
            ) == .appExpose
        )
        #expect(
            classifier.classify(
                windows: [backdrop, preview, preview, preview],
                displayBounds: bounds
            ) == .missionControl
        )
    }

    @Test("Gesture routing fails open and keeps overlay paths exclusive")
    func gestureRoutingPolicy() {
        let now = 100.0

        #expect(GestureRoutingSnapshot.unknown.route(at: now) == .system)
        #expect(
            GestureRoutingSnapshot(
                overlayMode: .none,
                sampledAtUptime: now
            ).route(at: now) == .blink
        )
        #expect(
            GestureRoutingSnapshot(
                overlayMode: .appExpose,
                sampledAtUptime: now
            ).route(at: now) == .system
        )
        let missionControl = GestureRoutingSnapshot(
            overlayMode: .missionControl,
            sampledAtUptime: now
        )
        #expect(missionControl.route(at: now) == .blink)
        #expect(
            missionControl.route(
                at: now,
                missionControlSyntheticState: .unavailableUntilOverlayExit
            ) == .system
        )
        #expect(
            GestureRoutingSnapshot(
                overlayMode: .none,
                sampledAtUptime: now - 1
            ).route(at: now) == .system
        )
    }

    @Test("Space identifiers and topologies reject invalid values")
    func topologyRejectsInvalidValues() {
        #expect(DisplayID(rawValue: "") == nil)
        #expect(SpaceID(rawValue: 0) == nil)

        let displayID = DisplayID(rawValue: "display-a")!
        let first = SpaceID(rawValue: 100)!
        let second = SpaceID(rawValue: 101)!
        let missing = SpaceID(rawValue: 999)!

        #expect(
            DisplayTopology(
                displayID: displayID,
                spaceIDs: [],
                currentSpaceID: first,
                currentSpaceKind: .desktop
            ) == nil
        )
        #expect(
            DisplayTopology(
                displayID: displayID,
                spaceIDs: [first, first],
                currentSpaceID: first,
                currentSpaceKind: .desktop
            ) == nil
        )
        #expect(
            DisplayTopology(
                displayID: displayID,
                spaceIDs: [first, second],
                currentSpaceID: missing,
                currentSpaceKind: .desktop
            ) == nil
        )
        #expect(
            DisplayTopology(
                displayID: displayID,
                spaceIDs: [first, second],
                currentSpaceID: first,
                currentSpaceKind: .desktop
            ) != nil
        )
    }

    @Test("CGS parser rejects an active Space absent from topology")
    func parserRejectsInvalidCurrentSpace() {
        let display: NSDictionary = [
            "Display Identifier": "display-a",
            "Current Space": ["id64": NSNumber(value: 999), "type": 0],
            "Spaces": [
                ["id64": NSNumber(value: 100)],
                ["id64": NSNumber(value: 101)],
            ],
        ]

        #expect(
            CGSSpaceSystemClient.parseTopology(
                display,
                globalActiveSpaceID: 999
            ) == nil
        )
    }

    @Test("Mission Control capability publishes state transitions")
    func missionControlCapabilityPublishesTransitions() async {
        let capability = MissionControlSyntheticCapability()
        let transitions = Task { @MainActor in
            var values: [MissionControlSyntheticState] = []
            for await state in capability.changes {
                values.append(state)
                if values.count == 2 { break }
            }
            return values
        }

        capability.markUnavailable()
        capability.observeOverlay(.none)
        #expect(
            await transitions.value == [
                .unavailableUntilOverlayExit,
                .available,
            ]
        )
    }

    @Test("Mission Control capability resets only after a confirmed overlay exit")
    func missionControlCapabilityResetPolicy() {
        let capability = MissionControlSyntheticCapability()
        #expect(capability.markUnavailable())
        #expect(capability.state == .unavailableUntilOverlayExit)
        #expect(!capability.observeOverlay(.unknown))
        #expect(!capability.observeOverlay(.appExpose))
        #expect(!capability.observeOverlay(.missionControl))
        #expect(capability.state == .unavailableUntilOverlayExit)
        #expect(capability.observeOverlay(.none))
        #expect(capability.state == .available)
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

    private func version(_ major: Int, _ minor: Int) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
    }

    private func touches(at x: CGFloat) -> [GestureTouchSample] {
        (0..<3).map {
            GestureTouchSample(
                identity: String($0),
                position: CGPoint(x: x, y: CGFloat($0) * 0.01),
                isEnded: false
            )
        }
    }
}
