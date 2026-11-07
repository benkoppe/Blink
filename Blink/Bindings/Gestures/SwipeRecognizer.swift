//
//  SwipeRecognizer.swift
//  Blink
//

import CoreGraphics

/// Horizontal travel that fires a swipe, in normalized trackpad units summed across fingers.
private let minimumSwipeTravel: Double = 0.06

/// How many times larger horizontal travel must be than vertical travel to fire a swipe.
private let horizontalDominance: Double = 1.35

/// Turns a stream of touch frames into gesture boundaries and swipes.
struct SwipeRecognizer {
    enum Output {
        case began
        case swipe(SwipeDirection, fingers: Int)
        case ended
    }

    /// Reports each swipe in the opposite direction.
    var flipDirection = false

    /// When true, the same direction can fire multiple times within a single gesture.
    var allowSameDirectionRepeat = false

    /// Extra travel, beyond `minimumSwipeTravel` and in the same units, before the
    /// same direction fires again when `allowSameDirectionRepeat` is true. Zero
    /// repeats as easily as the first swipe.
    var sameDirectionRepeatSensitivity: Double = 0.06

    private var previousPositions: [Int: CGPoint]?
    private var lastFiredDirection: SwipeDirection?
    /// Horizontal travel since the last swipe fired, which gates same-direction repeats.
    private var travelSinceLastSwipe: Double = 0
    private var accumulatedDeltaX: Double = 0
    private var accumulatedDeltaY: Double = 0

    private var isActive: Bool { previousPositions != nil }

    mutating func consume(_ frame: TouchFrame) -> [Output] {
        guard !frame.contacts.isEmpty else {
            guard isActive else { return [] }
            reset()
            return [.ended]
        }

        var outputs: [Output] = []
        if previousPositions == nil {
            previousPositions = [:]
            outputs.append(.began)
        }

        var dx = 0.0
        var dy = 0.0
        var positions: [Int: CGPoint] = [:]
        for contact in frame.contacts {
            if let previous = previousPositions?[contact.id] {
                dx += contact.position.x - previous.x
                dy += contact.position.y - previous.y
            }
            positions[contact.id] = contact.position
        }
        previousPositions = positions

        accumulatedDeltaX += dx
        accumulatedDeltaY += dy

        guard abs(accumulatedDeltaX) > abs(accumulatedDeltaY) * horizontalDominance,
            abs(accumulatedDeltaX) >= minimumSwipeTravel
        else { return outputs }

        let rawDirection: SwipeDirection = accumulatedDeltaX > 0 ? .right : .left
        let direction = flipDirection ? rawDirection.opposite : rawDirection

        if direction == lastFiredDirection {
            travelSinceLastSwipe += abs(dx)
            guard allowSameDirectionRepeat,
                travelSinceLastSwipe >= sameDirectionRepeatSensitivity
            else {
                accumulatedDeltaX = 0
                return outputs
            }
        }

        lastFiredDirection = direction
        travelSinceLastSwipe = 0
        accumulatedDeltaX = 0
        outputs.append(.swipe(direction, fingers: frame.contacts.count))
        return outputs
    }

    mutating func reset() {
        previousPositions = nil
        lastFiredDirection = nil
        travelSinceLastSwipe = 0
        accumulatedDeltaX = 0
        accumulatedDeltaY = 0
    }
}
