import CoreGraphics
import Foundation
import Testing

@testable import Blink

@MainActor
@Suite("Overlay classification and gesture routing")
struct OverlayRoutingTests {
    @Test("Captured single-display Mission Control has two display previews")
    func capturedSingleDisplayMissionControl() {
        let bounds = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        // Minimal fixture derived from InstantSpaceSwitcher probe output captured
        // on macOS 26.2: github.com/jurplel/InstantSpaceSwitcher, ExposeMcDetectTests.swift.
        let windows = [
            dockWindow(layer: 20, bounds: bounds),
            dockWindow(layer: 20, bounds: bounds),
            dockWindow(layer: 18, bounds: bounds),
            dockWindow(layer: -2_147_483_624, bounds: bounds),
        ]
        #expect(
            OverlayClassifier().classify(
                windows: windows,
                displayBounds: bounds
            ) == .missionControl
        )
    }

    @Test("Captured App Exposé ignores its small Dock HUD")
    func capturedAppExpose() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let windows = [
            dockWindow(
                layer: 20,
                bounds: CGRect(x: 0, y: 0, width: 233, height: 86)
            ),
            dockWindow(layer: 20, bounds: bounds),
            dockWindow(layer: 18, bounds: bounds),
            dockWindow(layer: -2_147_483_624, bounds: bounds),
        ]
        #expect(
            OverlayClassifier().classify(
                windows: windows,
                displayBounds: bounds
            ) == .appExpose
        )
    }

    @Test("Normal desktop and strong Mission Control traces classify safely")
    func normalAndStrongOverlayFixtures() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let wallpaper = dockWindow(layer: -2_147_483_624, bounds: bounds)
        #expect(
            OverlayClassifier().classify(
                windows: [wallpaper],
                displayBounds: bounds
            ) == .none
        )

        let thumbnail = CGRect(x: 120, y: 80, width: 600, height: 400)
        #expect(
            OverlayClassifier().classify(
                windows: [
                    dockWindow(layer: 18, bounds: bounds),
                    dockWindow(layer: 17, bounds: thumbnail),
                ],
                displayBounds: bounds
            ) == .missionControl
        )

        let backing = CGRect(x: 160, y: 100, width: 1500, height: 800)
        #expect(
            OverlayClassifier().classify(
                windows: [
                    dockWindow(layer: 18, bounds: bounds),
                    dockWindow(layer: -2_147_483_622, bounds: backing),
                    dockWindow(layer: -2_147_483_624, bounds: backing),
                ],
                displayBounds: bounds
            ) == .missionControl
        )
    }

    @Test("Other-display backing windows cannot classify the target display")
    func overlayClassificationIsDisplaySpecific() {
        let target = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let secondary = CGRect(x: -1728, y: 0, width: 1728, height: 1117)
        let secondaryInset = CGRect(x: -1650, y: 60, width: 1500, height: 900)
        let windows = [
            dockWindow(layer: 18, bounds: target),
            dockWindow(layer: 20, bounds: target),
            dockWindow(layer: -2_147_483_622, bounds: secondaryInset),
            dockWindow(layer: -2_147_483_624, bounds: secondaryInset),
            dockWindow(layer: -2_147_483_624, bounds: secondary),
        ]
        #expect(
            OverlayClassifier().classify(
                windows: windows,
                displayBounds: target
            ) == .appExpose
        )
    }

    @Test("Negative-origin display geometry is preserved")
    func negativeOriginOverlayGeometry() {
        let bounds = CGRect(x: -2560, y: -200, width: 2560, height: 1440)
        #expect(
            OverlayClassifier().classify(
                windows: [
                    dockWindow(layer: 18, bounds: bounds),
                    dockWindow(layer: 20, bounds: bounds),
                    dockWindow(layer: 20, bounds: bounds),
                ],
                displayBounds: bounds
            ) == .missionControl
        )
    }

    @Test("Unknown and malformed overlay geometry fails open")
    func malformedOverlayGeometry() {
        let classifier = OverlayClassifier()
        let malformed = dockWindow(
            layer: 18,
            bounds: CGRect(x: CGFloat.nan, y: 0, width: 1920, height: 1080)
        )
        #expect(classifier.classify(windows: [], displayBounds: nil) == .unknown)
        #expect(
            classifier.classify(
                windows: [malformed],
                displayBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)
            ) == .unknown
        )
    }

    @Test("A desktop lease remains Blink-routable beyond 300 milliseconds")
    func desktopLeaseSurvivesOrdinaryIdle() {
        let display = DisplayID(rawValue: "display-a")!
        let lease = routingLease(
            displayID: display,
            sampledAtUptime: 100,
            expirationUptime: 130
        )

        #expect(
            lease.route(
                at: 101,
                requiredGeneration: 1,
                currentTargetDisplayID: display
            ) == .blink
        )
        #expect(
            lease.route(
                at: 130,
                requiredGeneration: 1,
                currentTargetDisplayID: display
            ) == .system
        )
    }

    @Test("Expired, unknown, invalidated, and display-mismatched leases fail open")
    func invalidRoutingLeasesFailOpen() {
        let display = DisplayID(rawValue: "display-a")!
        let otherDisplay = DisplayID(rawValue: "display-b")!
        let desktop = routingLease(displayID: display)
        let unknown = routingLease(mode: .unknown, displayID: display)

        #expect(
            desktop.route(
                at: 130,
                requiredGeneration: 1,
                currentTargetDisplayID: display
            ) == .system
        )
        #expect(
            unknown.route(
                at: 100,
                requiredGeneration: 1,
                currentTargetDisplayID: display
            ) == .system
        )
        #expect(
            desktop.route(
                at: 100,
                requiredGeneration: 2,
                currentTargetDisplayID: display
            ) == .system
        )
        #expect(
            desktop.route(
                at: 100,
                requiredGeneration: 1,
                currentTargetDisplayID: otherDisplay
            ) == .system
        )

        var state = OverlayRoutingLeaseState()
        _ = state.invalidate()
        #expect(
            state.makeContext(
                sessionGeneration: 1,
                at: 100,
                currentDisplayID: display,
                missionControlSyntheticState: .available
            ) == nil
        )
    }

    @Test("A new gesture fails open after desktop or overlay state is invalidated")
    func gestureBoundaryInvalidationDropsDestructiveOwnership() {
        let display = DisplayID(rawValue: "display-a")!
        for mode in [OverlayMode.none, .missionControl] {
            var state = OverlayRoutingLeaseState()
            let generation = state.invalidate()
            let accepted = state.accept(routingLease(
                mode: mode,
                generation: generation,
                displayID: display
            ))
            #expect(accepted)
            #expect(state.makeContext(
                sessionGeneration: 1,
                at: 100,
                currentDisplayID: display,
                missionControlSyntheticState: .available
            )?.route == .blink)

            _ = state.invalidate()
            #expect(state.makeContext(
                sessionGeneration: 2,
                at: 100,
                currentDisplayID: display,
                missionControlSyntheticState: .available
            ) == nil)
        }
    }

    @Test("App Exposé routes to macOS and Mission Control respects its circuit")
    func overlayRoutesRemainExclusive() {
        let display = DisplayID(rawValue: "display-a")!
        let appExpose = routingLease(mode: .appExpose, displayID: display)
        let missionControl = routingLease(mode: .missionControl, displayID: display)

        #expect(
            appExpose.route(
                at: 100,
                requiredGeneration: 1,
                currentTargetDisplayID: display
            ) == .system
        )
        #expect(
            missionControl.route(
                at: 100,
                requiredGeneration: 1,
                currentTargetDisplayID: display
            ) == .blink
        )
        #expect(
            missionControl.route(
                at: 100,
                requiredGeneration: 1,
                currentTargetDisplayID: display,
                missionControlSyntheticState: .unavailableUntilOverlayExit
            ) == .system
        )
    }

    @Test("Touch routing reuses one decision across Dock segments")
    func touchRoutingReusesDecisionUntilFingerUp() {
        var coordinator = TouchRoutingSessionCoordinator()
        let original = blinkContext(generation: 1)
        let replacement = blinkContext(generation: 2)

        coordinator.beginTouchSession(id: 10, evidenceToken: 100)
        coordinator.bindContext(original, evidenceToken: 100)
        coordinator.bindContext(replacement, evidenceToken: 100)

        #expect(coordinator.hasOwnershipDecision)
        #expect(coordinator.selectedContext == original)
        let rejectedOldEnd = coordinator.endTouchSession(id: 9)
        #expect(!rejectedOldEnd)
        #expect(coordinator.selectedContext == original)
        let acceptedEnd = coordinator.endTouchSession(id: 10)
        #expect(acceptedEnd)
        #expect(!coordinator.hasOwnershipDecision)
    }

    @Test("Dock-first ownership joins the following HID touch session")
    func dockFirstOwnershipJoinsTouchSession() {
        var coordinator = TouchRoutingSessionCoordinator()
        let context = blinkContext()

        coordinator.beginDockSegment(id: 20, evidenceToken: 100)
        coordinator.bindContext(context, evidenceToken: 100)
        coordinator.beginTouchSession(id: 1, evidenceToken: 101)

        #expect(coordinator.hasOwnershipDecision)
        #expect(coordinator.selectedContext == context)
        let acceptedEnd = coordinator.endTouchSession(id: 1)
        #expect(acceptedEnd)
    }

    @Test("A system decision is stable across an entire touch session")
    func nilOwnershipDecisionRemainsDecided() {
        var coordinator = TouchRoutingSessionCoordinator()
        coordinator.beginTouchSession(id: 1, evidenceToken: 100)
        coordinator.bindContext(nil, evidenceToken: 100)

        #expect(coordinator.hasOwnershipDecision)
        #expect(coordinator.selectedContext == nil)
        coordinator.bindContext(blinkContext(), evidenceToken: 100)
        #expect(coordinator.selectedContext == nil)
    }

    @Test("Missing or stale routing state fails open without synchronous work")
    func staleRoutingStateFailsOpen() {
        let display = DisplayID(rawValue: "display-a")!
        var state = OverlayRoutingLeaseState()
        let generation = state.invalidate()

        #expect(state.makeContext(
            sessionGeneration: 1,
            at: 100,
            currentDisplayID: display,
            missionControlSyntheticState: .available
        ) == nil)
        let acceptedDesktop = state.accept(
            routingLease(generation: generation, displayID: display)
        )
        #expect(acceptedDesktop)
        #expect(state.makeContext(
            sessionGeneration: 2,
            at: 100,
            currentDisplayID: display,
            missionControlSyntheticState: .available
        )?.route == .blink)

        _ = state.invalidate()
        let acceptedAppExpose = state.accept(
            routingLease(
                mode: .appExpose,
                generation: state.generation,
                displayID: display
            )
        )
        #expect(acceptedAppExpose)
        #expect(state.makeContext(
            sessionGeneration: 3,
            at: 100,
            currentDisplayID: display,
            missionControlSyntheticState: .available
        )?.route == .system)
        #expect(state.makeContext(
            sessionGeneration: 4,
            at: 131,
            currentDisplayID: display,
            missionControlSyntheticState: .available
        ) == nil)
        #expect(
            GestureSessionContext.observed(
                generation: 1,
                targetDisplayID: display,
                overlayMode: .none,
                missionControlSyntheticState: .available
            ).requiredPostingMode == .instant
        )
        #expect(
            GestureSessionContext.observed(
                generation: 2,
                targetDisplayID: display,
                overlayMode: .missionControl,
                missionControlSyntheticState: .available
            ).requiredPostingMode == .missionControl
        )
        #expect(
            GestureSessionContext.observed(
                generation: 3,
                targetDisplayID: display,
                overlayMode: .appExpose,
                missionControlSyntheticState: .available
            ).route == .system
        )
    }

    @Test("Transition invalidation fails new sessions open without changing the active session")
    func transitionInvalidationRespectsSessionBoundary() {
        let display = DisplayID(rawValue: "display-a")!
        var state = OverlayRoutingLeaseState()
        let sampledGeneration = state.invalidate()
        let accepted = state.accept(
            routingLease(generation: sampledGeneration, displayID: display)
        )
        #expect(accepted)
        let activeContext = state.makeContext(
            sessionGeneration: 1,
            at: 100,
            currentDisplayID: display,
            missionControlSyntheticState: .available
        )!
        _ = state.invalidate()

        #expect(
            state.makeContext(
                sessionGeneration: 2,
                at: 100,
                currentDisplayID: display,
                missionControlSyntheticState: .available
            ) == nil
        )
        #expect(
            activeContext.isValidForDispatch(
                currentDisplayID: display,
                currentMissionControlSyntheticState: .available
            )
        )
    }

    @Test("A late refresh from an invalidated generation is ignored")
    func lateOverlayRefreshIsIgnored() async {
        let display = DisplayID(rawValue: "display-a")!
        let detector = ControlledOverlayDetector(
            modes: [.missionControl, .none],
            blockedSamples: [1]
        )
        let sink = RoutingLeaseSink()
        let sampler = OverlayModeSampler(
            displayLocator: FixedDisplayLocator(displayID: display),
            detector: detector
        )

        let firstGeneration = sink.invalidate()
        await sampler.start(generation: firstGeneration) { sink.accept($0) }
        await detector.waitUntilStarted(1)

        let secondGeneration = sink.invalidate()
        await sampler.start(generation: secondGeneration) { sink.accept($0) }
        #expect(detector.startedSamples == 1)
        detector.release(sample: 1)
        await sink.waitUntilLeaseCount(1)

        #expect(sink.leases.map(\.generation) == [secondGeneration])
        #expect(sink.lease?.overlayMode == OverlayMode.none)
        await sampler.stop(generation: secondGeneration + 1)
    }

    @Test("Reordered callback delivery cannot restore an older lease")
    func reorderedDeliveryIsIgnored() {
        let display = DisplayID(rawValue: "display-a")!
        var state = OverlayRoutingLeaseState()
        let generation = state.invalidate()
        let newer = routingLease(
            mode: .none,
            generation: generation,
            displayID: display,
            requestSequence: 3
        )
        let older = routingLease(
            mode: .missionControl,
            generation: generation,
            displayID: display,
            requestSequence: 2
        )

        let acceptedNewer = state.accept(newer)
        let acceptedOlder = state.accept(older)
        #expect(acceptedNewer)
        #expect(!acceptedOlder)
        #expect(state.lease == newer)
    }

    @Test("A transient restrictive observation gets bounded settling recovery")
    func transientRestrictiveObservationRecovers() async {
        let display = DisplayID(rawValue: "display-a")!
        let clock = RoutingTestClock(now: 100)
        let sleeper = RoutingTestSleeper()
        let detector = ControlledOverlayDetector(modes: [.appExpose, .none])
        let sink = RoutingLeaseSink()
        let generation = sink.invalidate()
        let sampler = OverlayModeSampler(
            displayLocator: FixedDisplayLocator(displayID: display),
            detector: detector,
            freshnessPolicy: .init(
                leaseDuration: 30,
                uncertaintyRetryDelays: [0.5]
            ),
            uptime: { clock.now },
            sleep: { try await sleeper.sleep($0) }
        )

        await sampler.start(
            generation: generation,
            settlesTransition: true
        ) { sink.accept($0) }
        await detector.waitUntilStarted(1)
        await sleeper.waitUntilWaiting(for: 0.5)
        await sleeper.waitUntilWaiting(for: 24)
        #expect(sink.lease?.overlayMode == .appExpose)
        #expect(
            sink.lease?.route(
                at: 100,
                requiredGeneration: generation,
                currentTargetDisplayID: display
            ) == .system
        )

        await sleeper.resumeFirst(for: 0.5)
        await sink.waitUntilLeaseCount(2)
        #expect(detector.startedSamples == 2)
        #expect(await sleeper.waitingDurations == [24])
        await sampler.stop(generation: generation + 1)
        await sleeper.waitUntilEmpty()
    }

    @Test("Settling confirmation follows desktop and Mission Control transitions")
    func settlingConfirmationFollowsOverlayTransitions() async {
        let display = DisplayID(rawValue: "display-a")!
        let scenarios: [(initial: OverlayMode, settled: OverlayMode)] = [
            (.none, .missionControl),
            (.missionControl, .none),
        ]

        for scenario in scenarios {
            let clock = RoutingTestClock(now: 100)
            let sleeper = RoutingTestSleeper()
            let detector = ControlledOverlayDetector(
                modes: [scenario.initial, scenario.settled]
            )
            let sink = RoutingLeaseSink()
            let generation = sink.invalidate()
            let sampler = OverlayModeSampler(
                displayLocator: FixedDisplayLocator(displayID: display),
                detector: detector,
                freshnessPolicy: .init(
                    leaseDuration: 30,
                    uncertaintyRetryDelays: [0.5]
                ),
                uptime: { clock.now },
                sleep: { try await sleeper.sleep($0) }
            )

            await sampler.start(
                generation: generation,
                settlesTransition: true
            ) { sink.accept($0) }
            await sink.waitUntilLeaseCount(1)
            await sleeper.waitUntilWaiting(for: 0.5)
            await sleeper.waitUntilWaiting(for: 24)
            #expect(sink.lease?.overlayMode == scenario.initial)

            await sleeper.resumeFirst(for: 0.5)
            await sink.waitUntilLeaseCount(2)
            #expect(sink.lease?.overlayMode == scenario.settled)
            #expect(await sleeper.waitingDurations == [24])

            await sampler.stop(generation: generation + 1)
            await sleeper.waitUntilEmpty()
        }
    }

    @Test("Stop cancels pending uncertainty recovery")
    func stopCancelsUncertaintyRecovery() async {
        let display = DisplayID(rawValue: "display-a")!
        let sleeper = RoutingTestSleeper()
        let detector = ControlledOverlayDetector(modes: [.unknown, .none])
        let sink = RoutingLeaseSink()
        let generation = sink.invalidate()
        let sampler = OverlayModeSampler(
            displayLocator: FixedDisplayLocator(displayID: display),
            detector: detector,
            freshnessPolicy: .init(
                leaseDuration: 30,
                uncertaintyRetryDelays: [0.5]
            ),
            sleep: { try await sleeper.sleep($0) }
        )

        await sampler.start(generation: generation) { sink.accept($0) }
        await sleeper.waitUntilWaiting(for: 0.5)
        await sampler.stop(generation: generation + 1)
        await sleeper.waitUntilEmpty()

        #expect(detector.startedSamples == 1)
        #expect(sink.lease == nil)
    }

    @Test("Stop and restart reject the previous scan lifecycle")
    func stopAndRestartAreGenerationSafe() async {
        let display = DisplayID(rawValue: "display-a")!
        let clock = RoutingTestClock(now: 100)
        let sleeper = RoutingTestSleeper()
        let detector = ControlledOverlayDetector(
            modes: [.missionControl, .none],
            blockedSamples: [1]
        )
        let sink = RoutingLeaseSink()
        let sampler = OverlayModeSampler(
            displayLocator: FixedDisplayLocator(displayID: display),
            detector: detector,
            uptime: { clock.now },
            sleep: { try await sleeper.sleep($0) }
        )

        let oldGeneration = sink.invalidate()
        await sampler.start(generation: oldGeneration) { sink.accept($0) }
        await detector.waitUntilStarted(1)
        let stoppedGeneration = sink.invalidate()
        let stopTask = Task {
            await sampler.stop(generation: stoppedGeneration)
        }
        #expect(detector.startedSamples == 1)
        detector.release(sample: 1)
        await stopTask.value
        await sampler.start(generation: stoppedGeneration) { sink.accept($0) }
        #expect(detector.startedSamples == 1)
        #expect(await sleeper.waitingDurations.isEmpty)

        let restartedGeneration = sink.invalidate()
        await sampler.start(generation: restartedGeneration) { sink.accept($0) }
        await sink.waitUntilLeaseCount(1)
        #expect(await sleeper.waitingDurations == [24])

        #expect(sink.leases.map(\.generation) == [restartedGeneration])
        await sampler.stop(generation: restartedGeneration + 1)
        await sleeper.waitUntilEmpty()
    }

    @Test("Repeated start coalesces and schedules one pre-expiry renewal")
    func samplerStartAndIdleAreLowFrequency() async {
        let display = DisplayID(rawValue: "display-a")!
        let clock = RoutingTestClock(now: 100)
        let sleeper = RoutingTestSleeper()
        let detector = ControlledOverlayDetector(modes: [.none])
        let sink = RoutingLeaseSink()
        let generation = sink.invalidate()
        let sampler = OverlayModeSampler(
            displayLocator: FixedDisplayLocator(displayID: display),
            detector: detector,
            uptime: { clock.now },
            sleep: { try await sleeper.sleep($0) }
        )

        await sampler.start(generation: generation) { sink.accept($0) }
        await sampler.start(generation: generation) { sink.accept($0) }
        await sink.waitUntilLeaseCount(1)
        #expect(await sleeper.waitingDurations == [24])
        clock.now = 120

        #expect(detector.startedSamples == 1)
        #expect(await sleeper.waitingDurations == [24])
        await sampler.stop(generation: generation + 1)
        await sleeper.waitUntilEmpty()
    }
}
