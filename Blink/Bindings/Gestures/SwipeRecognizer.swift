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
        touches.allSatisfy(\.isEnded) ? 0 : touches.count
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
    private var postFireAccumulator = 0.0
    private var accumulatedX = 0.0
    private var accumulatedY = 0.0
    private var previousPositions: [String: CGPoint] = [:]

    mutating func consume(
        _ sample: GestureSample,
        configuration: Configuration,
        ignoreNewGesture: Bool
    ) -> (direction: SwipeDirection, fingerCount: Int)? {
        let fingerCount = sample.activeFingerCount
        guard !sample.touches.isEmpty, fingerCount > 0 else {
            reset()
            return nil
        }

        if !isActive {
            isActive = true
            ignoresCurrentGesture = ignoreNewGesture
        }

        guard !ignoresCurrentGesture else { return nil }

        var deltaX = 0.0
        var deltaY = 0.0

        for touch in sample.touches {
            if let previous = previousPositions[touch.identity] {
                deltaX += touch.position.x - previous.x
                deltaY += touch.position.y - previous.y
            }

            if touch.isEnded {
                previousPositions.removeValue(forKey: touch.identity)
            } else {
                previousPositions[touch.identity] = touch.position
            }
        }

        accumulatedX += deltaX
        accumulatedY += deltaY

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
            postFireAccumulator += abs(deltaX)
            guard
                configuration.allowsSameDirectionRepeat,
                postFireAccumulator >= configuration.sameDirectionRepeatSensitivity
            else {
                accumulatedX = 0
                return nil
            }
        }

        lastDirection = direction
        postFireAccumulator = 0
        accumulatedX = 0
        return (direction, fingerCount)
    }

    mutating func reset() {
        isActive = false
        ignoresCurrentGesture = false
        lastDirection = nil
        postFireAccumulator = 0
        accumulatedX = 0
        accumulatedY = 0
        previousPositions.removeAll(keepingCapacity: true)
    }
}
