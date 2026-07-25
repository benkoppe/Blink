import CoreGraphics
import Foundation

nonisolated struct GestureTouchSample: Equatable, Sendable {
    let identity: String
    let position: CGPoint
    let isEnded: Bool
}

nonisolated struct GestureSample: Equatable, Sendable {
    let touches: [GestureTouchSample]

    var activeFingerCount: Int {
        touches.count { !$0.isEnded }
    }
}

nonisolated struct SwipeRecognizer: Sendable {
    struct Configuration: Equatable, Sendable {
        let flipsDirection: Bool
        let allowsSameDirectionRepeat: Bool
        let sameDirectionRepeatSensitivity: Double
    }

    private static let threshold = 0.06
    private static let horizontalDominance = 1.35

    private var isActive = false
    private var ignoresCurrentGesture = false
    private var lastDirection: SwipeDirection?
    private var movementSinceLastFireX = 0.0
    private var accumulatedX = 0.0
    private var accumulatedY = 0.0
    private var previousPositions: [String: CGPoint] = [:]

    mutating func consume(
        _ sample: GestureSample,
        configuration: Configuration,
        ignoreNewGesture: Bool
    ) -> (direction: SwipeDirection, fingerCount: Int)? {
        let activeTouches = sample.touches.filter { !$0.isEnded }
        let fingerCount = activeTouches.count
        guard fingerCount > 0 else {
            reset()
            return nil
        }

        if !isActive {
            isActive = true
            ignoresCurrentGesture = ignoreNewGesture
        }

        guard !ignoresCurrentGesture else { return nil }

        let activeIdentities = Set(activeTouches.map(\.identity))
        previousPositions = previousPositions.filter {
            activeIdentities.contains($0.key)
        }

        var deltaX = 0.0
        var deltaY = 0.0
        for touch in activeTouches {
            if let previous = previousPositions[touch.identity] {
                deltaX += touch.position.x - previous.x
                deltaY += touch.position.y - previous.y
            }
            previousPositions[touch.identity] = touch.position
        }

        if startsHorizontalWindow(deltaX: deltaX, deltaY: deltaY) {
            resetRecognitionWindow()
        } else if isHorizontalReversal(deltaX: deltaX, deltaY: deltaY) {
            resetRecognitionWindow()
        }

        accumulatedX += deltaX
        accumulatedY += deltaY
        movementSinceLastFireX += deltaX

        guard
            abs(accumulatedX) > abs(accumulatedY) * Self.horizontalDominance,
            abs(accumulatedX) >= Self.threshold
        else {
            return nil
        }

        let rawDirection: SwipeDirection = accumulatedX > 0 ? .right : .left
        let direction = configuration.flipsDirection
            ? rawDirection.opposite
            : rawDirection

        if direction == lastDirection {
            let signedDistance = direction == (configuration.flipsDirection ? .left : .right)
                ? movementSinceLastFireX
                : -movementSinceLastFireX
            guard
                configuration.allowsSameDirectionRepeat,
                signedDistance >= max(0, configuration.sameDirectionRepeatSensitivity)
            else {
                // Keep horizontal distance so every delta since the previous
                // fire contributes to repeat sensitivity. Vertical movement is
                // scoped to the completed recognition window.
                accumulatedY = 0
                return nil
            }
        }

        lastDirection = direction
        movementSinceLastFireX = 0
        resetRecognitionWindow()
        return (direction, fingerCount)
    }

    mutating func reset() {
        isActive = false
        ignoresCurrentGesture = false
        lastDirection = nil
        movementSinceLastFireX = 0
        resetRecognitionWindow()
        previousPositions.removeAll(keepingCapacity: true)
    }

    private func startsHorizontalWindow(deltaX: Double, deltaY: Double) -> Bool {
        abs(deltaX) > abs(deltaY) * Self.horizontalDominance
            && abs(accumulatedY) > abs(accumulatedX)
    }

    private func isHorizontalReversal(deltaX: Double, deltaY: Double) -> Bool {
        guard abs(deltaX) > abs(deltaY) * Self.horizontalDominance else {
            return false
        }
        return accumulatedX != 0 && deltaX.sign != accumulatedX.sign
    }

    private mutating func resetRecognitionWindow() {
        accumulatedX = 0
        accumulatedY = 0
    }
}
