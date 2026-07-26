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

    @Test("Finger cardinality grows until the first recognition")
    func recognizerWaitsForCompleteFingerCardinality() {
        var recognizer = SwipeRecognizer()
        let configuration = SwipeRecognizer.Configuration(
            flipsDirection: false,
            allowsSameDirectionRepeat: true,
            sameDirectionRepeatSensitivity: 0
        )
        #expect(recognizer.consume(
            GestureSample(touches: touches(count: 1, at: 0)),
            configuration: configuration,
            ignoreNewGesture: false
        ) == nil)
        #expect(recognizer.consume(
            GestureSample(touches: touches(count: 1, at: 0.08)),
            configuration: configuration,
            ignoreNewGesture: false
        ) == nil)
        #expect(recognizer.consume(
            GestureSample(touches: touches(count: 2, at: 0.08)),
            configuration: configuration,
            ignoreNewGesture: false
        ) == nil)
        let first = recognizer.consume(
            GestureSample(touches: touches(count: 3, at: 0.08)),
            configuration: configuration,
            ignoreNewGesture: false
        )
        let reversed = recognizer.consume(
            GestureSample(touches: touches(count: 2, at: 0)),
            configuration: configuration,
            ignoreNewGesture: false
        )

        #expect(first?.direction == .right)
        #expect(first?.fingerCount == 3)
        #expect(reversed?.direction == .left)
        #expect(reversed?.fingerCount == 3)
    }

    @Test("Four-finger cardinality is captured before recognition")
    func recognizerCapturesFourFingerCardinality() {
        var recognizer = SwipeRecognizer()
        let configuration = SwipeRecognizer.Configuration(
            flipsDirection: false,
            allowsSameDirectionRepeat: false,
            sameDirectionRepeatSensitivity: 0.06
        )
        _ = recognizer.consume(
            GestureSample(touches: touches(count: 1, at: 0)),
            configuration: configuration,
            ignoreNewGesture: false
        )
        _ = recognizer.consume(
            GestureSample(touches: touches(count: 2, at: 0)),
            configuration: configuration,
            ignoreNewGesture: false
        )
        _ = recognizer.consume(
            GestureSample(touches: touches(count: 3, at: 0)),
            configuration: configuration,
            ignoreNewGesture: false
        )
        _ = recognizer.consume(
            GestureSample(touches: touches(count: 4, at: 0)),
            configuration: configuration,
            ignoreNewGesture: false
        )
        let result = recognizer.consume(
            GestureSample(touches: touches(count: 4, at: 0.08)),
            configuration: configuration,
            ignoreNewGesture: false
        )

        #expect(result?.fingerCount == 4)
    }

    @Test("Deferred ownership preserves the initial touch baseline")
    func recognizerPreservesDeferredOwnershipBaseline() {
        var recognizer = SwipeRecognizer()
        let configuration = SwipeRecognizer.Configuration(
            flipsDirection: false,
            allowsSameDirectionRepeat: false,
            sameDirectionRepeatSensitivity: 0.06
        )

        recognizer.prime(
            GestureSample(touches: touches(at: 0)),
            configuration: configuration
        )
        let result = recognizer.consume(
            GestureSample(touches: touches(at: 0.08)),
            configuration: configuration,
            ignoreNewGesture: false
        )

        #expect(result?.direction == .right)
        #expect(result?.fingerCount == 3)
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

    @Test("Partial touch endings preserve the session finger count")
    func recognizerPreservesSessionCardinality() {
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
        #expect(result?.fingerCount == 3)
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

    @Test("Uncertain routing remains system-owned for the whole gesture")
    func uncertainRecognitionFailsOpenForWholeGesture() async {
        let display = DisplayID(rawValue: "display-a")!
        let worker = SwipeRecognitionWorker()
        let probe = RecognitionProbe()
        let configuration = SwipeRecognizer.Configuration(
            flipsDirection: false,
            allowsSameDirectionRepeat: false,
            sameDirectionRepeatSensitivity: 0.06
        )
        let system = GestureSessionContext.system(
            generation: 1,
            targetDisplayID: display,
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
            proposedContext: system,
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

        #expect(probe.recognitions.isEmpty)
    }

    @Test("Recognition keeps its input-time route for the whole gesture")
    func recognitionKeepsInputTimeContext() async {
        let display = DisplayID(rawValue: "display-a")!
        let worker = SwipeRecognitionWorker()
        let probe = RecognitionProbe()
        let configuration = SwipeRecognizer.Configuration(
            flipsDirection: false,
            allowsSameDirectionRepeat: false,
            sameDirectionRepeatSensitivity: 0.06
        )
        let missionControl = GestureSessionContext.observed(
            generation: 1,
            targetDisplayID: display,
            overlayMode: .missionControl,
            missionControlSyntheticState: .available
        )
        let desktop = GestureSessionContext.observed(
            generation: 1,
            targetDisplayID: display,
            overlayMode: .none,
            missionControlSyntheticState: .available
        )

        worker.consume(
            GestureSample(touches: touches(at: 0)),
            configuration: configuration,
            proposedContext: missionControl,
            completion: probe.record
        )
        await waitUntil { probe.completionCount == 1 }
        worker.consume(
            GestureSample(touches: touches(at: 0)),
            configuration: configuration,
            proposedContext: desktop,
            completion: probe.record
        )
        worker.consume(
            GestureSample(touches: touches(at: 0.08)),
            configuration: configuration,
            proposedContext: desktop,
            completion: probe.record
        )
        await waitUntil { probe.completionCount == 3 }

        #expect(probe.recognitions.count == 1)
        #expect(probe.recognitions.first?.context == missionControl)
        #expect(probe.recognitions.first?.direction == .right)
    }

    @Test("Alternating swipes remain active until physical finger-up")
    func alternatingSwipesSharePhysicalTouchSession() async {
        let monitor = SwipeGestureMonitor(requiresHealthyTapForDispatch: false)
        let context = blinkContext()
        monitor.contextForRecognition = { context }
        var directions: [SwipeDirection] = []
        monitor.onSwipe = { _, direction, _ in directions.append(direction) }

        monitor.consume(GestureSample(touches: touches(at: 0)))
        monitor.consume(GestureSample(touches: touches(at: 0.08)))
        monitor.consume(GestureSample(touches: touches(at: 0)))
        monitor.consume(GestureSample(touches: touches(at: 0.08)))
        await waitUntil { directions.count == 3 }

        #expect(directions == [.right, .left, .right])
    }

    @Test("Empty companion events do not end physical touch ownership")
    func emptyCompanionDoesNotEndTouchSession() async {
        let monitor = SwipeGestureMonitor(requiresHealthyTapForDispatch: false)
        let context = blinkContext()
        monitor.contextForRecognition = { context }
        var beginnings: [UInt64] = []
        var endings: [UInt64] = []
        var directions: [SwipeDirection] = []
        monitor.onRecognitionSessionBegan = { beginnings.append($0) }
        monitor.onRecognitionSessionEnded = { endings.append($0) }
        monitor.onSwipe = { _, direction, _ in directions.append(direction) }

        monitor.consume(GestureSample(touches: touches(at: 0)))
        monitor.consume(GestureSample(touches: touches(at: 0.08)))
        monitor.consume(GestureSample(touches: []))
        monitor.consume(GestureSample(touches: touches(at: 0)))
        await waitUntil { directions.count == 2 }

        #expect(directions == [.right, .left])
        #expect(beginnings.count == 1)
        #expect(endings.isEmpty)
    }

    @Test("Disjoint touch identities begin a new physical session")
    func disjointTouchIdentitiesBeginNewSession() async {
        let monitor = SwipeGestureMonitor(requiresHealthyTapForDispatch: false)
        monitor.contextForRecognition = { self.blinkContext() }
        var beginnings: [UInt64] = []
        monitor.onRecognitionSessionBegan = { beginnings.append($0) }

        monitor.consume(GestureSample(touches: touches(at: 0)))
        let replacements = touches(at: 0).map {
            GestureTouchSample(
                identity: "new-\($0.identity)",
                position: $0.position,
                isEnded: false
            )
        }
        monitor.consume(GestureSample(touches: replacements))
        for _ in 0..<20 { await Task.yield() }

        #expect(beginnings == [1, 2])
    }

    @Test("Recognition queued before normal end dispatches before teardown")
    func recognitionPrecedesNormalTeardown() async {
        let monitor = SwipeGestureMonitor(requiresHealthyTapForDispatch: false)
        let context = blinkContext()
        monitor.contextForRecognition = { context }
        var events: [String] = []
        monitor.onSwipe = { _, _, _ in events.append("swipe") }
        monitor.onRecognitionSessionEnded = { _ in events.append("end") }

        monitor.consume(GestureSample(touches: touches(at: 0)))
        monitor.consume(GestureSample(touches: touches(at: 0.08)))
        monitor.consume(GestureSample(touches: touches(at: 0).map {
            GestureTouchSample(identity: $0.identity, position: $0.position, isEnded: true)
        }))
        await waitUntil { events.count == 2 }

        #expect(events == ["swipe", "end"])
    }

    @Test("An ending sample cannot create context for the next gesture")
    func endingSampleDoesNotCreateContext() async {
        let monitor = SwipeGestureMonitor(requiresHealthyTapForDispatch: false)
        var contextSelections = 0
        var endings = 0
        monitor.contextForRecognition = {
            contextSelections += 1
            return self.blinkContext()
        }
        monitor.onRecognitionSessionEnded = { _ in endings += 1 }

        monitor.consume(GestureSample(touches: []))
        for _ in 0..<20 { await Task.yield() }

        #expect(contextSelections == 0)
        #expect(endings == 0)
    }

    @Test("Recognition teardown is idempotent within a touch session")
    func recognitionTeardownIsIdempotent() async {
        let monitor = SwipeGestureMonitor(requiresHealthyTapForDispatch: false)
        monitor.contextForRecognition = { self.blinkContext() }
        var endings = 0
        monitor.onRecognitionSessionEnded = { _ in endings += 1 }

        monitor.consume(GestureSample(touches: touches(at: 0)))
        monitor.finishRecognitionSession()
        monitor.finishRecognitionSession()
        await waitUntil { endings == 1 }

        #expect(endings == 1)
    }

    @Test("Delayed teardown cannot clear a newer recognition session")
    func delayedTeardownCannotClearNewSession() async {
        let monitor = SwipeGestureMonitor(requiresHealthyTapForDispatch: false)
        monitor.contextForRecognition = { self.blinkContext() }
        var endings = 0
        monitor.onRecognitionSessionEnded = { _ in endings += 1 }

        monitor.consume(GestureSample(touches: touches(at: 0)))
        monitor.finishRecognitionSession()
        monitor.consume(GestureSample(touches: touches(at: 0)))
        for _ in 0..<20 { await Task.yield() }
        #expect(endings == 0)

        monitor.finishRecognitionSession()
        await waitUntil { endings == 1 }
        #expect(endings == 1)
    }

    @Test("Partial lift keeps four-finger repeat cardinality")
    func fourFingerRepeatKeepsCardinality() {
        var recognizer = SwipeRecognizer()
        let configuration = SwipeRecognizer.Configuration(
            flipsDirection: false,
            allowsSameDirectionRepeat: true,
            sameDirectionRepeatSensitivity: 0.02
        )
        func fourTouches(_ x: CGFloat, endingFourth: Bool = false) -> [GestureTouchSample] {
            (0..<4).map {
                GestureTouchSample(
                    identity: String($0),
                    position: CGPoint(x: x, y: CGFloat($0) * 0.01),
                    isEnded: endingFourth && $0 == 3
                )
            }
        }

        _ = recognizer.consume(
            GestureSample(touches: fourTouches(0)),
            configuration: configuration,
            ignoreNewGesture: false
        )
        #expect(recognizer.consume(
            GestureSample(touches: fourTouches(0.03)),
            configuration: configuration,
            ignoreNewGesture: false
        )?.fingerCount == 4)
        #expect(recognizer.consume(
            GestureSample(touches: fourTouches(0.06, endingFourth: true)),
            configuration: configuration,
            ignoreNewGesture: false
        )?.fingerCount == 4)
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
                missionControlSyntheticState: .available
            )?.route == .blink)

            _ = state.invalidate()
            #expect(state.makeContext(
                sessionGeneration: 2,
                at: 100,
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

        coordinator.beginTouchSession(id: 10)
        coordinator.bindContext(original)
        coordinator.bindContext(replacement)

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

        coordinator.bindContext(context)
        coordinator.beginTouchSession(id: 1)

        #expect(coordinator.hasOwnershipDecision)
        #expect(coordinator.selectedContext == context)
        let acceptedEnd = coordinator.endTouchSession(id: 1)
        #expect(acceptedEnd)
    }

    @Test("A system decision is stable across an entire touch session")
    func nilOwnershipDecisionRemainsDecided() {
        var coordinator = TouchRoutingSessionCoordinator()
        coordinator.beginTouchSession(id: 1)
        coordinator.bindContext(nil)

        #expect(coordinator.hasOwnershipDecision)
        #expect(coordinator.selectedContext == nil)
        coordinator.bindContext(blinkContext())
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
            missionControlSyntheticState: .available
        ) == nil)
        let acceptedDesktop = state.accept(
            routingLease(generation: generation, displayID: display)
        )
        #expect(acceptedDesktop)
        #expect(state.makeContext(
            sessionGeneration: 2,
            at: 100,
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
            missionControlSyntheticState: .available
        )?.route == .system)
        #expect(state.makeContext(
            sessionGeneration: 4,
            at: 131,
            missionControlSyntheticState: .available
        )?.route == .system)
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
            missionControlSyntheticState: .available
        )!
        _ = state.invalidate()

        #expect(
            state.makeContext(
                sessionGeneration: 2,
                at: 100,
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
        await waitUntil { detector.startedSamples >= 1 }

        let secondGeneration = sink.invalidate()
        await sampler.start(generation: secondGeneration) { sink.accept($0) }
        for _ in 0..<20 { await Task.yield() }
        #expect(detector.startedSamples == 1)
        detector.release(sample: 1)
        await waitUntil { sink.lease?.generation == secondGeneration }

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
        await waitUntil { detector.startedSamples == 1 }
        await waitUntil { await sleeper.waitingDurations == [0.5] }
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
        #expect(await sleeper.waitingDurations.isEmpty)
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
            await waitUntil { await sleeper.waitingDurations == [0.5] }
            #expect(sink.lease?.overlayMode == scenario.initial)

            await sleeper.resumeFirst(for: 0.5)
            await waitUntil { sink.leases.count == 2 }
            #expect(sink.lease?.overlayMode == scenario.settled)
            #expect(await sleeper.waitingDurations.isEmpty)

            await sampler.stop(generation: generation + 1)
            await waitUntil { await sleeper.waitingDurations.isEmpty }
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
        await waitUntil { await sleeper.waitingDurations == [0.5] }
        await sampler.stop(generation: generation + 1)
        await waitUntil { await sleeper.waitingDurations.isEmpty }
        for _ in 0..<20 { await Task.yield() }

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
        await waitUntil { detector.startedSamples >= 1 }
        let stoppedGeneration = sink.invalidate()
        let stopTask = Task {
            await sampler.stop(generation: stoppedGeneration)
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(detector.startedSamples == 1)
        detector.release(sample: 1)
        await stopTask.value
        await sampler.start(generation: stoppedGeneration) { sink.accept($0) }
        for _ in 0..<20 { await Task.yield() }
        #expect(detector.startedSamples == 1)
        #expect(await sleeper.waitingDurations.isEmpty)

        let restartedGeneration = sink.invalidate()
        await sampler.start(generation: restartedGeneration) { sink.accept($0) }
        await waitUntil { sink.lease?.generation == restartedGeneration }
        #expect(await sleeper.waitingDurations.isEmpty)

        #expect(sink.leases.map(\.generation) == [restartedGeneration])
        await sampler.stop(generation: restartedGeneration + 1)
        await waitUntil { await sleeper.waitingDurations.isEmpty }
    }

    @Test("Repeated start performs one scan and idle does not poll")
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
        #expect(await sleeper.waitingDurations.isEmpty)
        clock.now = 120
        for _ in 0..<50 { await Task.yield() }

        #expect(detector.startedSamples == 1)
        #expect(await sleeper.waitingDurations.isEmpty)
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

    @Test("Mission Control failure recovery is display- and time-scoped")
    func missionControlCapabilityResetPolicy() {
        let capability = MissionControlSyntheticCapability()
        let displayA = DisplayID(rawValue: "display-a")!
        let displayB = DisplayID(rawValue: "display-b")!
        #expect(capability.markUnavailable(on: displayA, at: 100))
        #expect(capability.state == .unavailableUntilOverlayExit)
        #expect(!capability.observeOverlay(
            .none,
            on: displayB,
            sampledAtUptime: 101
        ))
        #expect(!capability.observeOverlay(
            .none,
            on: displayA,
            sampledAtUptime: 99
        ))
        #expect(!capability.observeOverlay(
            .missionControl,
            on: displayA,
            sampledAtUptime: 102
        ))
        #expect(capability.state == .unavailableUntilOverlayExit)
        #expect(capability.observeOverlay(
            .none,
            on: displayA,
            sampledAtUptime: 103
        ))
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
        _ condition: @escaping @MainActor () async -> Bool
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

    private func touches(
        count: Int = 3,
        at x: CGFloat,
        y: CGFloat = 0
    ) -> [GestureTouchSample] {
        (0..<count).map {
            GestureTouchSample(
                identity: String($0),
                position: CGPoint(x: x, y: y + CGFloat($0) * 0.01),
                isEnded: false
            )
        }
    }

    private func blinkContext(generation: UInt64 = 1) -> GestureSessionContext {
        GestureSessionContext(
            generation: generation,
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
