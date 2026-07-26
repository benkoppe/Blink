import CoreGraphics
import Foundation
import Testing

@testable import Blink

@MainActor
@Suite("Swipe recognition and monitoring")
struct SwipeRecognitionTests {
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
        monitor.contextForRecognition = { blinkContext() }
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
            return blinkContext()
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
        monitor.contextForRecognition = { blinkContext() }
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
        monitor.contextForRecognition = { blinkContext() }
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
}
