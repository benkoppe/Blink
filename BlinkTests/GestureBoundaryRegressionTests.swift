import CoreGraphics
import Foundation
import Testing

@testable import Blink

@MainActor
@Suite("Gesture boundary regressions")
struct GestureBoundaryRegressionTests {
    @Test("Verified raw Dock records preserve desktop evidence")
    func verifiedWindowServerParsing() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let raw = rawDockWindow(pid: 42, layer: -2_147_483_624, bounds: bounds)

        let result = WindowServerWindowParser().parse(
            [raw],
            verifiedDockBundleIDsByPID: [42: "com.apple.dock"]
        )
        guard case .verified(let windows) = result else {
            Issue.record("Expected verified Dock evidence")
            return
        }
        #expect(OverlayClassifier().classify(
            windows: windows,
            displayBounds: bounds
        ) == .none)
    }

    @Test("Partial, malformed, and unverified Dock records are unknown")
    func uncertainWindowServerParsing() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let parser = WindowServerWindowParser()
        var missingLayer = rawDockWindow(pid: 42, layer: 18, bounds: bounds)
        missingLayer.removeValue(forKey: kCGWindowLayer as String)
        var missingBounds = rawDockWindow(pid: 42, layer: 18, bounds: bounds)
        missingBounds[kCGWindowBounds as String] = "invalid"
        let unverified = rawDockWindow(pid: 42, layer: 18, bounds: bounds)

        #expect(parser.parse(
            [missingLayer],
            verifiedDockBundleIDsByPID: [42: "com.apple.dock"]
        ) == .unknown)
        #expect(parser.parse(
            [missingBounds],
            verifiedDockBundleIDsByPID: [42: "com.apple.dock"]
        ) == .unknown)
        #expect(parser.parse(
            [unverified],
            verifiedDockBundleIDsByPID: [:]
        ) == .unknown)
    }

    @Test("Overlay renewal starts before lease expiration")
    func overlayLeaseRenewsBeforeExpiration() async {
        let display = DisplayID(rawValue: "display-a")!
        let clock = RoutingTestClock(now: 100)
        let sleeper = RoutingTestSleeper()
        let detector = ControlledOverlayDetector(modes: [.none, .none])
        let sink = RoutingLeaseSink()
        let generation = sink.invalidate()
        let sampler = OverlayModeSampler(
            displayLocator: FixedDisplayLocator(displayID: display),
            detector: detector,
            freshnessPolicy: .init(leaseDuration: 10),
            uptime: { clock.now },
            sleep: { try await sleeper.sleep($0) }
        )

        await sampler.start(generation: generation) { sink.accept($0) }
        await sink.waitUntilLeaseCount(1)
        await sleeper.waitUntilWaiting(for: 8)
        #expect(sink.lease?.expirationUptime == 110)

        clock.now = 108
        await sleeper.resumeFirst(for: 8)
        await sink.waitUntilLeaseCount(2)
        #expect(sink.lease?.sampledAtUptime == 108)
        #expect(sink.lease?.expirationUptime == 118)
        await sampler.stop(generation: generation + 1)
    }

    @Test("Overlay renewal accounts for time spent scanning")
    func overlayRenewalUsesSampleAge() async {
        let display = DisplayID(rawValue: "display-a")!
        let clock = RoutingTestClock(now: 100)
        let sleeper = RoutingTestSleeper()
        let detector = ControlledOverlayDetector(
            modes: [.none],
            blockedSamples: [1]
        )
        let sink = RoutingLeaseSink()
        let generation = sink.invalidate()
        let sampler = OverlayModeSampler(
            displayLocator: FixedDisplayLocator(displayID: display),
            detector: detector,
            freshnessPolicy: .init(leaseDuration: 10),
            uptime: { clock.now },
            sleep: { try await sleeper.sleep($0) }
        )

        await sampler.start(generation: generation) { sink.accept($0) }
        await detector.waitUntilStarted(1)
        clock.now = 103
        detector.release(sample: 1)
        await sink.waitUntilLeaseCount(1)
        await sleeper.waitUntilWaiting(for: 5)

        #expect(sink.lease?.sampledAtUptime == 100)
        #expect(sink.lease?.expirationUptime == 110)
        await sampler.stop(generation: generation + 1)
    }

    @Test("Uncertain renewal retries while the prior lease is still valid")
    func uncertainRenewalRetriesBeforeExpiration() async {
        let display = DisplayID(rawValue: "display-a")!
        let clock = RoutingTestClock(now: 100)
        let sleeper = RoutingTestSleeper()
        let detector = ControlledOverlayDetector(modes: [.none, .unknown, .none])
        let sink = RoutingLeaseSink()
        let generation = sink.invalidate()
        let sampler = OverlayModeSampler(
            displayLocator: FixedDisplayLocator(displayID: display),
            detector: detector,
            freshnessPolicy: .init(leaseDuration: 10),
            uptime: { clock.now },
            sleep: { try await sleeper.sleep($0) }
        )

        await sampler.start(generation: generation) { sink.accept($0) }
        await sink.waitUntilLeaseCount(1)
        await sleeper.waitUntilWaiting(for: 8)
        clock.now = 108
        await sleeper.resumeFirst(for: 8)
        await detector.waitUntilStarted(2)
        await sleeper.waitUntilWaiting(for: 0.2)
        #expect(sink.lease?.expirationUptime == 110)

        clock.now = 108.2
        await sleeper.resumeFirst(for: 0.2)
        await sink.waitUntilLeaseCount(2)
        #expect(sink.lease?.expirationUptime == 118.2)
        await sampler.stop(generation: generation + 1)
    }

    @Test("Refresh requests coalesce behind one serial scan")
    func overlayRefreshesCoalesce() async {
        let displayA = DisplayID(rawValue: "display-a")!
        let displayB = DisplayID(rawValue: "display-b")!
        let detector = ControlledOverlayDetector(
            modes: [.none, .none],
            blockedSamples: [1]
        )
        let sink = RoutingLeaseSink()
        let generation = sink.invalidate()
        let sampler = OverlayModeSampler(
            displayLocator: FixedDisplayLocator(displayID: displayA),
            detector: detector
        )

        await sampler.start(generation: generation) { sink.accept($0) }
        await detector.waitUntilStarted(1)
        for token in 1...10 {
            await sampler.refresh(
                generation: generation,
                targetDisplayID: displayB,
                evidenceToken: UInt64(token)
            )
        }
        #expect(detector.startedSamples == 1)

        detector.release(sample: 1)
        await detector.waitUntilStarted(2)
        await sink.waitUntilLeaseCount(1)
        #expect(detector.startedSamples == 2)
        await sampler.stop(generation: generation + 1)
    }

    @Test("Lease cache validates the actual cursor display and expiry")
    func cachedLeaseUsesActualDisplay() {
        let displayA = DisplayID(rawValue: "display-a")!
        let displayB = DisplayID(rawValue: "display-b")!
        var state = OverlayRoutingLeaseState()
        let generation = state.invalidate()
        let accepted = state.accept(routingLease(
            generation: generation,
            displayID: displayA,
            evidenceToken: 7
        ))
        #expect(accepted)

        #expect(state.selectContext(
            sessionGeneration: 1,
            at: 100,
            currentDisplayID: displayB,
            missionControlSyntheticState: .available
        ) == .refresh(displayID: displayB))
        #expect(state.selectContext(
            sessionGeneration: 2,
            at: 130,
            currentDisplayID: displayA,
            missionControlSyntheticState: .available
        ) == .refresh(displayID: displayA))
    }

    @Test("Suppressor-only Dock ownership tears down with its segment")
    func suppressorOnlySegmentTeardown() {
        var coordinator = TouchRoutingSessionCoordinator()
        coordinator.beginDockSegment(id: 1, evidenceToken: 10)
        coordinator.bindContext(blinkContext(), evidenceToken: 10)
        #expect(coordinator.hasOwnershipDecision)
        let ended = coordinator.endDockSegment(id: 1)
        #expect(ended)
        #expect(!coordinator.hasOwnershipDecision)
    }

    @Test("Dock-first and continuous segments retain one contact decision")
    func dockFirstContinuousSegments() {
        var coordinator = TouchRoutingSessionCoordinator()
        let original = blinkContext(generation: 1)
        coordinator.beginDockSegment(id: 1, evidenceToken: 10)
        coordinator.bindContext(original, evidenceToken: 10)
        let touchToken = coordinator.beginTouchSession(id: 20, evidenceToken: 11)
        let ended = coordinator.endDockSegment(id: 1)
        let secondDockToken = coordinator.beginDockSegment(id: 2, evidenceToken: 12)
        #expect(touchToken == 10)
        #expect(ended)
        #expect(secondDockToken == 10)
        coordinator.bindContext(nil, evidenceToken: 10)

        #expect(coordinator.selectedContext == original)
    }

    @Test("Lease invalidation cannot change an owned physical contact")
    func contactOwnershipSurvivesLeaseInvalidation() {
        var coordinator = TouchRoutingSessionCoordinator()
        let context = blinkContext(generation: 1)
        coordinator.beginTouchSession(id: 1, evidenceToken: 10)
        coordinator.beginDockSegment(id: 1, evidenceToken: 11)
        coordinator.bindContext(context, evidenceToken: 10)

        var leases = OverlayRoutingLeaseState()
        let generation = leases.invalidate()
        let accepted = leases.accept(routingLease(
            generation: generation,
            displayID: context.targetDisplayID,
            evidenceToken: 10
        ))
        #expect(accepted)
        _ = leases.invalidate()
        let ended = coordinator.endDockSegment(id: 1)
        let nextToken = coordinator.beginDockSegment(id: 2, evidenceToken: 12)
        #expect(ended)
        #expect(nextToken == 10)
        #expect(coordinator.selectedContext == context)
    }

    @Test("Stale Dock inactivity tokens cannot end a newer segment")
    func dockInactivityIsTokenized() {
        var lifetime = DockSegmentLifetimeState()
        let first = lifetime.prepare()
        let firstActivity = lifetime.activityToken!
        let second = lifetime.prepare()
        let secondActivity = lifetime.activityToken!

        #expect(first.began == 1)
        #expect(second.ended == 1)
        #expect(second.began == 2)
        #expect(lifetime.expire(activityToken: firstActivity) == nil)
        #expect(lifetime.expire(activityToken: secondActivity) == 2)
    }

    @Test("A missing Dock terminal cannot transfer old ownership")
    func missingDockTerminalFailsNewContactOpen() {
        var coordinator = TouchRoutingSessionCoordinator()
        coordinator.beginDockSegment(id: 1, evidenceToken: 10)
        coordinator.beginTouchSession(id: 1, evidenceToken: 11)
        coordinator.bindContext(blinkContext(), evidenceToken: 10)
        let ended = coordinator.endTouchSession(id: 1)
        #expect(ended)

        coordinator.beginTouchSession(id: 2, evidenceToken: 12)
        #expect(coordinator.hasOwnershipDecision)
        #expect(coordinator.selectedContext == nil)
    }

    @Test("Missing HID terminal quarantines identities until real separation")
    func hidInactivityQuarantinesIdentities() {
        var lifetime = PhysicalContactLifetimeState()
        #expect(lifetime.consume(GestureSample(touches: touches(at: 0))) == [
            .began(id: 1), .sample(id: 1),
        ])
        let activity = lifetime.activityToken!
        #expect(lifetime.expire(activityToken: activity) == .ended(id: 1))
        #expect(lifetime.isQuarantined)
        #expect(lifetime.consume(GestureSample(touches: touches(at: 0.1))).isEmpty)

        let replacements = touches(at: 0).map {
            GestureTouchSample(
                identity: "new-\($0.identity)",
                position: $0.position,
                isEnded: false
            )
        }
        #expect(lifetime.consume(GestureSample(touches: replacements)) == [
            .began(id: 2), .sample(id: 2),
        ])
    }

    @Test("Disjoint contacts end before begin and empty samples are nonterminal")
    func physicalContactOrdering() {
        var lifetime = PhysicalContactLifetimeState()
        _ = lifetime.consume(GestureSample(touches: touches(at: 0)))
        let activityToken = lifetime.activityToken
        #expect(lifetime.consume(GestureSample(touches: [])).isEmpty)
        #expect(lifetime.activityToken == activityToken)
        let replacements = touches(at: 0).map {
            GestureTouchSample(
                identity: "replacement-\($0.identity)",
                position: $0.position,
                isEnded: false
            )
        }

        #expect(lifetime.consume(GestureSample(touches: replacements)) == [
            .ended(id: 1), .began(id: 2), .sample(id: 2),
        ])
    }

    @Test("Tap interruption quarantines contact and invalidates stale ownership")
    func tapInterruptionQuarantinesContact() {
        var lifetime = PhysicalContactLifetimeState()
        _ = lifetime.consume(GestureSample(touches: touches(at: 0)))
        #expect(lifetime.interrupt() == .ended(id: 1))
        #expect(lifetime.consume(GestureSample(touches: touches(at: 0.1))).isEmpty)

        var coordinator = TouchRoutingSessionCoordinator()
        coordinator.beginTouchSession(id: 1, evidenceToken: 1)
        coordinator.bindContext(blinkContext(), evidenceToken: 1)
        coordinator.interrupt()
        #expect(!coordinator.hasOwnershipDecision)
    }

    @Test("Operational health epochs arm, degrade fail-open, and recover")
    func suppressorOperationalHealthEpochs() {
        var health = SuppressorOperationalHealth()
        #expect(health.state == .disabled)
        let armed = health.update(configured: true, tapIsHealthy: true)
        #expect(armed)
        #expect(health.state == .armed)
        let armedEpoch = health.epoch

        let interrupted = health.update(
            configured: true,
            tapIsHealthy: true,
            interrupted: true
        )
        #expect(interrupted)
        #expect(health.state == .degraded)
        #expect(health.epoch > armedEpoch)
        let interruptedEpoch = health.epoch

        let recovered = health.update(configured: true, tapIsHealthy: true)
        #expect(recovered)
        #expect(health.state == .armed)
        #expect(health.epoch > interruptedEpoch)
        let disabled = health.update(configured: false, tapIsHealthy: false)
        #expect(disabled)
        #expect(health.state == .disabled)
    }

    @Test("Native ownership requires every operational input dependency")
    func nativeSuppressionReadiness() {
        #expect(NativeSuppressionReadiness.canOwnInput(
            suppressionState: .armed,
            recognitionRequired: false,
            recognitionState: .disabled
        ))
        #expect(!NativeSuppressionReadiness.canOwnInput(
            suppressionState: .degraded,
            recognitionRequired: false,
            recognitionState: .armed
        ))
        #expect(!NativeSuppressionReadiness.canOwnInput(
            suppressionState: .armed,
            recognitionRequired: true,
            recognitionState: .degraded
        ))
        #expect(NativeSuppressionReadiness.canOwnInput(
            suppressionState: .armed,
            recognitionRequired: true,
            recognitionState: .armed
        ))
    }

    @Test("Only matching current evidence can bind native ownership")
    func nativeOwnershipRequiresMatchingEvidence() {
        var coordinator = TouchRoutingSessionCoordinator()
        coordinator.beginTouchSession(id: 1, evidenceToken: 9)
        coordinator.bindContext(blinkContext(), evidenceToken: 8)
        #expect(!coordinator.hasOwnershipDecision)
        coordinator.bindContext(nil, evidenceToken: 9)
        coordinator.bindContext(blinkContext(), evidenceToken: 9)
        #expect(coordinator.hasOwnershipDecision)
        #expect(coordinator.selectedContext == nil)
    }
}

private func rawDockWindow(
    pid: Int,
    layer: Int,
    bounds: CGRect
) -> [String: Any] {
    [
        kCGWindowOwnerName as String: "Dock",
        kCGWindowOwnerPID as String: NSNumber(value: pid),
        kCGWindowLayer as String: NSNumber(value: layer),
        kCGWindowBounds as String: bounds.dictionaryRepresentation,
    ]
}
