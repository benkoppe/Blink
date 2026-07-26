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

    @Test("Small deltas count toward same-direction repeat distance")
    func recognizerAccumulatesRepeatMovement() {
        var recognizer = SwipeRecognizer()
        let configuration = SwipeRecognizer.Configuration(
            flipsDirection: false,
            allowsSameDirectionRepeat: true,
            sameDirectionRepeatSensitivity: 0.15
        )
        _ = recognizer.consume(
            GestureSample(touches: touches(at: 0)),
            configuration: configuration,
            ignoreNewGesture: false
        )
        #expect(
            recognizer.consume(
                GestureSample(touches: touches(at: 0.03)),
                configuration: configuration,
                ignoreNewGesture: false
            )?.direction == .right
        )

        var repeatResult: (direction: SwipeDirection, fingerCount: Int)?
        for step in 1...5 {
            repeatResult = recognizer.consume(
                GestureSample(touches: touches(at: 0.03 + CGFloat(step) * 0.01)),
                configuration: configuration,
                ignoreNewGesture: false
            ) ?? repeatResult
        }
        #expect(repeatResult?.direction == .right)
    }

    @Test("Vertical movement does not poison a later horizontal window")
    func recognizerResetsVerticalWindow() {
        var recognizer = SwipeRecognizer()
        let configuration = SwipeRecognizer.Configuration(
            flipsDirection: false,
            allowsSameDirectionRepeat: false,
            sameDirectionRepeatSensitivity: 0.06
        )
        _ = recognizer.consume(
            GestureSample(touches: touches(at: 0, y: 0)),
            configuration: configuration,
            ignoreNewGesture: false
        )
        #expect(
            recognizer.consume(
                GestureSample(touches: touches(at: 0, y: 0.2)),
                configuration: configuration,
                ignoreNewGesture: false
            ) == nil
        )
        #expect(
            recognizer.consume(
                GestureSample(touches: touches(at: 0.03, y: 0.2)),
                configuration: configuration,
                ignoreNewGesture: false
            )?.direction == .right
        )
    }

    @Test("Partial touch endings report only active fingers")
    func recognizerCountsActiveTouches() {
        var recognizer = SwipeRecognizer()
        let configuration = SwipeRecognizer.Configuration(
            flipsDirection: false,
            allowsSameDirectionRepeat: false,
            sameDirectionRepeatSensitivity: 0.06
        )
        _ = recognizer.consume(
            GestureSample(touches: touches(at: 0)),
            configuration: configuration,
            ignoreNewGesture: false
        )
        var moved = touches(at: 0.04)
        moved[2] = GestureTouchSample(
            identity: "2",
            position: .zero,
            isEnded: true
        )
        let result = recognizer.consume(
            GestureSample(touches: moved),
            configuration: configuration,
            ignoreNewGesture: false
        )
        #expect(result?.direction == .right)
        #expect(result?.fingerCount == 2)
    }

    @Test("Reversal and same-direction repeat are deterministic")
    func recognizerReversal() {
        var recognizer = SwipeRecognizer()
        let configuration = SwipeRecognizer.Configuration(
            flipsDirection: false,
            allowsSameDirectionRepeat: true,
            sameDirectionRepeatSensitivity: 0.06
        )
        _ = recognizer.consume(
            GestureSample(touches: touches(at: 0)),
            configuration: configuration,
            ignoreNewGesture: false
        )
        #expect(
            recognizer.consume(
                GestureSample(touches: touches(at: 0.03)),
                configuration: configuration,
                ignoreNewGesture: false
            )?.direction == .right
        )
        #expect(
            recognizer.consume(
                GestureSample(touches: touches(at: 0)),
                configuration: configuration,
                ignoreNewGesture: false
            )?.direction == .left
        )
        #expect(
            recognizer.consume(
                GestureSample(touches: touches(at: -0.03)),
                configuration: configuration,
                ignoreNewGesture: false
            )?.direction == .left
        )
    }

    @Test("Pending recognition promotes without requiring fingers to lift")
    func pendingRecognitionPromotesWithinGesture() async {
        let display = DisplayID(rawValue: "display-a")!
        let worker = SwipeRecognitionWorker()
        let probe = RecognitionProbe()
        let configuration = SwipeRecognizer.Configuration(
            flipsDirection: false,
            allowsSameDirectionRepeat: false,
            sameDirectionRepeatSensitivity: 0.06
        )
        let pending = GestureSessionContext.pending(
            generation: 1,
            targetDisplayID: display,
            capturedOverlayMode: .missionControl,
            missionControlSyntheticState: .available
        )
        let blink = GestureSessionContext.observed(
            generation: 2,
            targetDisplayID: display,
            overlayMode: .none,
            missionControlSyntheticState: .available
        )

        worker.consume(
            GestureSample(touches: touches(at: 0)),
            configuration: configuration,
            proposedContext: pending,
            completion: probe.record
        )
        await waitUntil { probe.completionCount == 1 }

        worker.consume(
            GestureSample(touches: touches(at: 0)),
            configuration: configuration,
            proposedContext: blink,
            completion: probe.record
        )
        worker.consume(
            GestureSample(touches: touches(at: 0.08)),
            configuration: configuration,
            proposedContext: blink,
            completion: probe.record
        )
        await waitUntil { probe.completionCount == 3 }

        #expect(probe.recognitions.count == 1)
        #expect(probe.recognitions.first?.context == blink)
        #expect(probe.recognitions.first?.direction == .right)
    }

    @Test("Queued recognition cannot dispatch after monitor stop")
    func queuedRecognitionAfterStopIsDiscarded() async {
        let queue = DispatchQueue(label: "SwipeGestureMonitor.stop-test")
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        let monitor = SwipeGestureMonitor(
            worker: SwipeRecognitionWorker(queue: queue),
            requiresHealthyTapForDispatch: false
        )
        let context = blinkContext()
        monitor.contextForRecognition = { context }
        var dispatchCount = 0
        monitor.onSwipe = { _, _, _ in dispatchCount += 1 }

        monitor.consume(GestureSample(touches: touches(at: 0)))
        monitor.consume(GestureSample(touches: touches(at: 0.08)))
        monitor.stopMonitoring()
        gate.signal()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(dispatchCount == 0)
    }

    @Test("Queued recognition cannot dispatch after tap recreation")
    func queuedRecognitionAfterTapRecreationIsDiscarded() async {
        let queue = DispatchQueue(label: "SwipeGestureMonitor.recreation-test")
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        let monitor = SwipeGestureMonitor(
            worker: SwipeRecognitionWorker(queue: queue),
            requiresHealthyTapForDispatch: false
        )
        let context = blinkContext()
        monitor.contextForRecognition = { context }
        var dispatchCount = 0
        monitor.onSwipe = { _, _, _ in dispatchCount += 1 }

        monitor.consume(GestureSample(touches: touches(at: 0)))
        monitor.consume(GestureSample(touches: touches(at: 0.08)))
        monitor.invalidateRecognition()
        gate.signal()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(dispatchCount == 0)
    }

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
            !OverlayRoutingFreshnessPolicy.standard.shouldRenewOpportunistically(
                lease,
                at: 101
            )
        )
        #expect(
            OverlayRoutingFreshnessPolicy.standard.shouldRenewOpportunistically(
                lease,
                at: 125
            )
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
                currentDisplayID: display,
                at: 100,
                missionControlSyntheticState: .available
            ).route == .system
        )
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

    @Test("Restrictive or stale routing state requires a synchronous gesture refresh")
    func restrictiveRoutingStateRequiresSynchronousRefresh() {
        let display = DisplayID(rawValue: "display-a")!
        var state = OverlayRoutingLeaseState()
        let generation = state.invalidate()

        #expect(state.requiresSynchronousRefresh(currentDisplayID: display, at: 100))
        let acceptedDesktop = state.accept(
            routingLease(generation: generation, displayID: display)
        )
        #expect(acceptedDesktop)
        #expect(!state.requiresSynchronousRefresh(currentDisplayID: display, at: 100))

        _ = state.invalidate()
        let acceptedAppExpose = state.accept(
            routingLease(
                mode: .appExpose,
                generation: state.generation,
                displayID: display
            )
        )
        #expect(acceptedAppExpose)
        #expect(state.requiresSynchronousRefresh(currentDisplayID: display, at: 100))
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

    @Test("A mayBegin renewal does not invalidate an existing lease")
    func mayBeginRenewalPreservesLease() async {
        let display = DisplayID(rawValue: "display-a")!
        let detector = ControlledOverlayDetector(
            modes: [.none, .missionControl],
            blockedSamples: [2]
        )
        let sink = RoutingLeaseSink()
        let generation = sink.invalidate()
        let sampler = OverlayModeSampler(
            displayLocator: FixedDisplayLocator(displayID: display),
            detector: detector
        )

        await sampler.start(generation: generation) { sink.accept($0) }
        await waitUntil { sink.lease != nil }
        let original = sink.lease

        await sampler.opportunisticRefresh(generation: generation)
        await waitUntil { detector.startedSamples >= 2 }
        await sampler.opportunisticRefresh(generation: generation)
        for _ in 0..<20 { await Task.yield() }
        #expect(detector.startedSamples == 2)
        #expect(sink.lease == original)
        #expect(
            sink.lease?.route(
                at: sink.lease!.sampledAtUptime,
                requiredGeneration: generation,
                currentTargetDisplayID: display
            ) == .blink
        )

        detector.release(sample: 2)
        await sampler.stop(generation: generation + 1)
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
            currentDisplayID: display,
            at: 100,
            missionControlSyntheticState: .available
        )
        _ = state.invalidate()

        #expect(
            state.makeContext(
                sessionGeneration: 2,
                currentDisplayID: display,
                at: 100,
                missionControlSyntheticState: .available
            ).route == .system
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
        await waitUntil { detector.startedSamples >= 1 }

        let secondGeneration = sink.invalidate()
        await sampler.invalidate(generation: secondGeneration)
        await sampler.refresh(generation: secondGeneration)
        await waitUntil { sink.lease?.generation == secondGeneration }
        detector.release(sample: 1)
        try? await Task.sleep(for: .milliseconds(20))

        #expect(sink.leases.map(\.generation) == [secondGeneration])
        #expect(sink.lease?.overlayMode == OverlayMode.none)
        await sampler.stop(generation: secondGeneration + 1)
    }

    @Test("An older refresh cannot overwrite a newer sample")
    func olderRefreshCannotReplaceNewerSample() async {
        let display = DisplayID(rawValue: "display-a")!
        let detector = ControlledOverlayDetector(
            modes: [.missionControl, .none],
            blockedSamples: [1]
        )
        let sink = RoutingLeaseSink()
        let generation = sink.invalidate()
        let sampler = OverlayModeSampler(
            displayLocator: FixedDisplayLocator(displayID: display),
            detector: detector
        )

        await sampler.start(generation: generation) { sink.accept($0) }
        await waitUntil { detector.startedSamples >= 1 }
        await sampler.refresh(generation: generation)
        await waitUntil { sink.lease?.overlayMode == OverlayMode.none }
        detector.release(sample: 1)
        try? await Task.sleep(for: .milliseconds(20))

        #expect(sink.leases.map(\.overlayMode) == [.none])
        await sampler.stop(generation: generation + 1)
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

    @Test("Failed renewal preserves a valid lease; failed invalid-state refresh does not")
    func failedRefreshSemantics() async {
        let display = DisplayID(rawValue: "display-a")!
        let detector = ControlledOverlayDetector(modes: [.none, .unknown, .unknown])
        let sink = RoutingLeaseSink()
        let sampler = OverlayModeSampler(
            displayLocator: FixedDisplayLocator(displayID: display),
            detector: detector
        )

        let validGeneration = sink.invalidate()
        await sampler.start(generation: validGeneration) { sink.accept($0) }
        await waitUntil { sink.lease != nil }
        let validLease = sink.lease

        await sampler.refresh(generation: validGeneration)
        await waitUntil { detector.startedSamples >= 2 }
        #expect(sink.lease == validLease)
        #expect(
            validLease?.route(
                at: validLease!.expirationUptime - 0.001,
                requiredGeneration: validGeneration,
                currentTargetDisplayID: display
            ) == .blink
        )
        #expect(
            validLease?.route(
                at: validLease!.expirationUptime,
                requiredGeneration: validGeneration,
                currentTargetDisplayID: display
            ) == .system
        )

        let invalidGeneration = sink.invalidate()
        await sampler.invalidate(generation: invalidGeneration)
        await sampler.refresh(generation: invalidGeneration)
        await waitUntil { detector.startedSamples >= 3 }
        #expect(sink.lease == nil)
        await sampler.stop(generation: invalidGeneration + 1)
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
                safetyRenewalLeadTime: 5,
                activeOverlayRevalidationInterval: 30,
                uncertaintyRetryDelays: [0.5]
            ),
            uptime: { clock.now },
            sleep: { try await sleeper.sleep($0) }
        )

        await sampler.start(
            generation: generation,
            settlesTransition: true
        ) { sink.accept($0) }
        await waitUntil { detector.startedSamples == 1 }
        await waitUntil {
            Set(await sleeper.waitingDurations) == Set([0.5, 30])
        }
        #expect(sink.lease?.overlayMode == .appExpose)
        #expect(
            sink.lease?.route(
                at: 100,
                requiredGeneration: generation,
                currentTargetDisplayID: display
            ) == .system
        )

        await sleeper.resumeFirst(for: 0.5)
        await waitUntil { sink.lease?.overlayMode == OverlayMode.none }
        #expect(detector.startedSamples == 2)
        #expect(await sleeper.waitingDurations == [25])
        await sampler.stop(generation: generation + 1)
        await waitUntil { await sleeper.waitingDurations.isEmpty }
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
                    safetyRenewalLeadTime: 5,
                    activeOverlayRevalidationInterval: 30,
                    uncertaintyRetryDelays: [0.5]
                ),
                uptime: { clock.now },
                sleep: { try await sleeper.sleep($0) }
            )

            await sampler.start(
                generation: generation,
                settlesTransition: true
            ) { sink.accept($0) }
            await waitUntil { sink.leases.count == 1 }
            let initialSafetyDelay = scenario.initial == .none ? 25.0 : 30.0
            await waitUntil {
                Set(await sleeper.waitingDurations) == Set([0.5, initialSafetyDelay])
            }
            #expect(sink.lease?.overlayMode == scenario.initial)

            await sleeper.resumeFirst(for: 0.5)
            await waitUntil { sink.leases.count == 2 }
            #expect(sink.lease?.overlayMode == scenario.settled)
            let settledSafetyDelay = scenario.settled == .none ? 25.0 : 30.0
            #expect(await sleeper.waitingDurations == [settledSafetyDelay])

            await sampler.stop(generation: generation + 1)
            await waitUntil { await sleeper.waitingDurations.isEmpty }
        }
    }

    @Test("Active-overlay revalidation detects an unnotified Mission Control exit")
    func activeOverlayRevalidationDetectsExit() async {
        let display = DisplayID(rawValue: "display-a")!
        let clock = RoutingTestClock(now: 100)
        let sleeper = RoutingTestSleeper()
        let detector = ControlledOverlayDetector(
            modes: [.missionControl, .unknown, .none]
        )
        let sink = RoutingLeaseSink()
        let generation = sink.invalidate()
        let sampler = OverlayModeSampler(
            displayLocator: FixedDisplayLocator(displayID: display),
            detector: detector,
            freshnessPolicy: .init(
                leaseDuration: 30,
                safetyRenewalLeadTime: 5,
                activeOverlayRevalidationInterval: 0.5,
                uncertaintyRetryDelays: []
            ),
            uptime: { clock.now },
            sleep: { try await sleeper.sleep($0) }
        )

        await sampler.start(generation: generation) { sink.accept($0) }
        await waitUntil { sink.lease?.overlayMode == .missionControl }
        await waitUntil { await sleeper.waitingDurations == [0.5] }
        #expect(
            OverlayRoutingFreshnessPolicy.standard.shouldRenewOpportunistically(
                sink.lease!,
                at: 100
            )
        )

        clock.now = 129
        await sleeper.resumeFirst()
        await waitUntil { detector.startedSamples == 2 }
        await waitUntil { await sleeper.waitingDurations == [0.5] }
        #expect(sink.lease?.overlayMode == .missionControl)

        clock.now = 129.5
        await sleeper.resumeFirst()
        await waitUntil { sink.lease?.overlayMode == OverlayMode.none }
        #expect(detector.startedSamples == 3)
        #expect(await sleeper.waitingDurations == [25])

        await sampler.stop(generation: generation + 1)
        await waitUntil { await sleeper.waitingDurations.isEmpty }
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
                safetyRenewalLeadTime: 5,
                uncertaintyRetryDelays: [0.5]
            ),
            sleep: { try await sleeper.sleep($0) }
        )

        await sampler.start(generation: generation) { sink.accept($0) }
        await waitUntil { await sleeper.waitingDurations == [0.5] }
        await sampler.stop(generation: generation + 1)
        await waitUntil { await sleeper.waitingDurations.isEmpty }
        for _ in 0..<20 { await Task.yield() }

        #expect(detector.startedSamples == 1)
        #expect(sink.lease == nil)
    }

    @Test("Safety renewal is scheduled from expiration and refreshes before it")
    func safetyRenewalPrecedesExpiration() async {
        let display = DisplayID(rawValue: "display-a")!
        let clock = RoutingTestClock(now: 100)
        let sleeper = RoutingTestSleeper()
        let detector = ControlledOverlayDetector(modes: [.none, .none])
        let sink = RoutingLeaseSink()
        let generation = sink.invalidate()
        let sampler = OverlayModeSampler(
            displayLocator: FixedDisplayLocator(displayID: display),
            detector: detector,
            freshnessPolicy: .init(
                leaseDuration: 10,
                safetyRenewalLeadTime: 2
            ),
            uptime: { clock.now },
            sleep: { try await sleeper.sleep($0) }
        )

        await sampler.start(generation: generation) { sink.accept($0) }
        await waitUntil { sink.lease != nil }
        await waitUntil { await sleeper.waitingDurations == [8] }
        #expect(sink.lease?.expirationUptime == 110)

        clock.now = 108
        await sleeper.resumeFirst()
        await waitUntil { sink.leases.count == 2 }
        #expect(sink.leases.last?.sampledAtUptime == 108)
        #expect(sink.leases.last?.expirationUptime == 118)
        await sampler.stop(generation: generation + 1)
    }

    @Test("Stop cancels renewal and restart rejects the previous lifecycle")
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
        await waitUntil { detector.startedSamples >= 1 }
        let stoppedGeneration = sink.invalidate()
        await sampler.stop(generation: stoppedGeneration)
        await sampler.start(generation: stoppedGeneration) { sink.accept($0) }
        for _ in 0..<20 { await Task.yield() }
        #expect(detector.startedSamples == 1)
        #expect(await sleeper.waitingDurations.isEmpty)

        let restartedGeneration = sink.invalidate()
        await sampler.start(generation: restartedGeneration) { sink.accept($0) }
        await waitUntil { sink.lease?.generation == restartedGeneration }
        await waitUntil { await sleeper.waitingDurations.count == 1 }
        detector.release(sample: 1)
        try? await Task.sleep(for: .milliseconds(20))

        #expect(sink.leases.map(\.generation) == [restartedGeneration])
        await sampler.stop(generation: restartedGeneration + 1)
        await waitUntil { await sleeper.waitingDurations.isEmpty }
    }

    @Test("Repeated start has one renewal task and idle does not enumerate repeatedly")
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
        await waitUntil { sink.lease != nil }
        await waitUntil { await sleeper.waitingDurations.count == 1 }
        clock.now = 120
        for _ in 0..<50 { await Task.yield() }

        #expect(detector.startedSamples == 1)
        #expect(await sleeper.waitingDurations == [25])
        await sampler.stop(generation: generation + 1)
        await waitUntil { await sleeper.waitingDurations.isEmpty }
    }

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

    @Test("Diagnostics report overlay scan lifetime metrics")
    func diagnosticsReportOverlayMetrics() {
        let store = DiagnosticsStore()
        store.recordOverlayScan(startedAt: 10, endedAt: 10.01)
        store.recordOverlayScan(startedAt: 20, endedAt: 20.03)

        let report = store.report(version: "test", build: "1")
        #expect(report.contains("count=2 lifetime-average-hz=0.100"))
        #expect(report.contains("duration-ms(avg/max)=20.000/30.000"))
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
                currentSpaceID: first
            ) == nil
        )
        #expect(
            DisplayTopology(
                displayID: displayID,
                spaceIDs: [first, first],
                currentSpaceID: first
            ) == nil
        )
        #expect(
            DisplayTopology(
                displayID: displayID,
                spaceIDs: [first, second],
                currentSpaceID: missing
            ) == nil
        )
        #expect(
            DisplayTopology(
                displayID: displayID,
                spaceIDs: [first, second],
                currentSpaceID: first
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

    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async {
        for _ in 0..<1_000 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for routing state")
    }

    private func routingLease(
        mode: OverlayMode = .none,
        generation: UInt64 = 1,
        displayID: DisplayID,
        sampledAtUptime: TimeInterval = 100,
        expirationUptime: TimeInterval = 130,
        requestSequence: UInt64 = 1
    ) -> OverlayRoutingLease {
        OverlayRoutingLease(
            generation: generation,
            targetDisplayID: displayID,
            overlayMode: mode,
            sampledAtUptime: sampledAtUptime,
            expirationUptime: expirationUptime,
            requestSequence: requestSequence
        )
    }

    private func version(_ major: Int, _ minor: Int) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
    }

    private func touches(at x: CGFloat, y: CGFloat = 0) -> [GestureTouchSample] {
        (0..<3).map {
            GestureTouchSample(
                identity: String($0),
                position: CGPoint(x: x, y: y + CGFloat($0) * 0.01),
                isEnded: false
            )
        }
    }

    private func blinkContext() -> GestureSessionContext {
        GestureSessionContext(
            generation: 1,
            route: .blink,
            targetDisplayID: DisplayID(rawValue: "display-a")!,
            capturedOverlayMode: .none,
            missionControlSyntheticState: .available,
            requiredPostingMode: .instant
        )
    }

    private func dockWindow(layer: Int, bounds: CGRect) -> WindowDescriptor {
        WindowDescriptor(
            ownerName: "Dock",
            ownerBundleID: "com.apple.dock",
            layer: layer,
            bounds: bounds
        )
    }
}

private nonisolated final class RecognitionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCompletionCount = 0
    private var storedRecognitions: [SwipeRecognitionWorker.Recognition] = []

    var completionCount: Int { lock.withLock { storedCompletionCount } }
    var recognitions: [SwipeRecognitionWorker.Recognition] {
        lock.withLock { storedRecognitions }
    }

    func record(_ recognition: SwipeRecognitionWorker.Recognition?) {
        lock.withLock {
            storedCompletionCount += 1
            if let recognition {
                storedRecognitions.append(recognition)
            }
        }
    }
}

private nonisolated struct FixedDisplayLocator: DisplayLocating {
    let displayID: DisplayID

    func cursorDisplayID() throws -> DisplayID { displayID }

    func bounds(for displayID: DisplayID) -> CGRect? {
        displayID == self.displayID
            ? CGRect(x: 0, y: 0, width: 1920, height: 1080)
            : nil
    }
}

private nonisolated final class ControlledOverlayDetector: OverlayDetecting, @unchecked Sendable {
    private let condition = NSCondition()
    private let modes: [OverlayMode]
    private var blockedSamples: Set<Int>
    private var sampleCount = 0

    init(modes: [OverlayMode], blockedSamples: Set<Int> = []) {
        self.modes = modes
        self.blockedSamples = blockedSamples
    }

    var startedSamples: Int {
        condition.withLock { sampleCount }
    }

    func detect(on displayID: DisplayID) -> OverlayMode {
        _ = displayID
        condition.lock()
        sampleCount += 1
        let sample = sampleCount
        condition.broadcast()
        while blockedSamples.contains(sample) {
            condition.wait()
        }
        let mode = modes.indices.contains(sample - 1)
            ? modes[sample - 1]
            : .unknown
        condition.unlock()
        return mode
    }

    func release(sample: Int) {
        condition.withLock {
            blockedSamples.remove(sample)
            condition.broadcast()
        }
    }
}

private nonisolated final class RoutingLeaseSink: @unchecked Sendable {
    private let lock = NSLock()
    private var state = OverlayRoutingLeaseState()
    private var storedLeases: [OverlayRoutingLease] = []

    var lease: OverlayRoutingLease? {
        lock.withLock { state.lease }
    }

    var leases: [OverlayRoutingLease] {
        lock.withLock { storedLeases }
    }

    func invalidate() -> UInt64 {
        lock.withLock { state.invalidate() }
    }

    func accept(_ lease: OverlayRoutingLease) {
        lock.withLock {
            guard state.accept(lease) else { return }
            storedLeases.append(lease)
        }
    }
}

private nonisolated final class RoutingTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedNow: TimeInterval

    init(now: TimeInterval) {
        storedNow = now
    }

    var now: TimeInterval {
        get { lock.withLock { storedNow } }
        set { lock.withLock { storedNow = newValue } }
    }
}

private actor RoutingTestSleeper {
    private struct Waiter {
        let id: UUID
        let duration: TimeInterval
        let continuation: CheckedContinuation<Void, Never>
    }

    private var waiters: [Waiter] = []

    var waitingDurations: [TimeInterval] {
        waiters.map(\.duration)
    }

    func sleep(_ duration: TimeInterval) async throws {
        try Task.checkCancellation()
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters.append(
                        Waiter(
                            id: id,
                            duration: duration,
                            continuation: continuation
                        )
                    )
                }
            }
        } onCancel: {
            Task { await self.resume(id: id) }
        }
        try Task.checkCancellation()
    }

    func resumeFirst() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume()
    }

    func resumeFirst(for duration: TimeInterval) {
        guard let index = waiters.firstIndex(where: { $0.duration == duration }) else {
            return
        }
        waiters.remove(at: index).continuation.resume()
    }

    private func resume(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume()
    }
}
