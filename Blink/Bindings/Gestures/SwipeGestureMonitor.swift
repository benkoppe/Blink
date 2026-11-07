//
//  SwipeGestureMonitor.swift
//  Blink
//
//  Created by Ben on 3/24/26.
//

import CoreGraphics
import Foundation

/// A recognized swipe remains actionable after the physical touches end. The
/// Dock stream can start a new policy session before this main-queue action runs.
@MainActor
final class SwipeActionDelivery {
    private var generation: UInt64 = 0
    private let schedule: (@escaping @MainActor () -> Void) -> Void

    init(schedule: @escaping (@escaping @MainActor () -> Void) -> Void = { action in
        DispatchQueue.main.async { action() }
    }) {
        self.schedule = schedule
    }

    func enqueue(_ action: @escaping @MainActor () -> Void) {
        let generation = generation
        schedule { [weak self] in
            guard self?.generation == generation else { return }
            action()
        }
    }

    func invalidate() {
        generation &+= 1
    }
}

@MainActor
final class SwipeGestureMonitor {
    /// Parameters: (direction, fingerCount)
    var onSwipe: ((SwipeDirection, Int) -> Void)?

    /// Reports each swipe in the opposite direction.
    var flipSwipeDirection: Bool {
        get { recognizer.flipDirection }
        set { recognizer.flipDirection = newValue }
    }

    /// When true, the same direction can fire multiple times within a single gesture.
    var allowSameDirectionRepeat: Bool {
        get { recognizer.allowSameDirectionRepeat }
        set { recognizer.allowSameDirectionRepeat = newValue }
    }

    /// Extra travel before the same direction fires again.
    var sameDirectionRepeatSensitivity: Double {
        get { recognizer.sameDirectionRepeatSensitivity }
        set { recognizer.sameDirectionRepeatSensitivity = newValue }
    }

    private var recognizer = SwipeRecognizer()
    var policy = NativeSwipePolicy()
    private let actionDelivery = SwipeActionDelivery()
    private var policySession: NativeSwipePolicy.Session?
    private var shouldIgnoreCurrentGesture = false
    private var ignoreUntilFingersLift = false

    private var eventTap: EventTap?

    // MARK - Monitoring lifecycle

    func startMonitoring() {
        guard eventTap == nil else { return }

        let tap = EventTap(
            label: "SwipeGestureMonitor",
            options: .defaultTap,
            location: .hidEventTap,
            place: .headInsertEventTap,
            types: [.gesture],
            callback: { [weak self] proxy, type, cgEvent in
                guard let self else { return cgEvent }

                switch type {
                case .tapDisabledByTimeout, .tapDisabledByUserInput:
                    self.resetGesture()
                    self.policy.reset()
                    self.ignoreUntilFingersLift = true
                    self.actionDelivery.invalidate()
                    proxy.enable()
                    return cgEvent

                case .gesture:
                    self.process(cgEvent)
                    return cgEvent

                default:
                    return cgEvent
                }
            }
        )
        tap.enable()
        self.eventTap = tap
    }

    func stopMonitoring() {
        actionDelivery.invalidate()
        policy.reset()
        eventTap?.disable()
        eventTap = nil
        resetGesture()
        ignoreUntilFingersLift = false
    }

    // MARK: - Event handling

    func process(_ event: CGEvent) {
        guard !NativeSwipePolicy.isAppPosted(event), let frame = TouchFrame(event) else { return }

        if ignoreUntilFingersLift {
            if frame.contacts.isEmpty { ignoreUntilFingersLift = false }
            return
        }

        for output in recognizer.consume(frame) {
            switch output {
            case .began:
                let session = policy.begin(.recognition)
                policySession = session
                shouldIgnoreCurrentGesture = session.bypass
            case .ended:
                policy.end(.recognition, session: policySession)
                policySession = nil
                shouldIgnoreCurrentGesture = false
            case .swipe(let direction, let fingers):
                // After a shared session reset, ignore the rest of this gesture.
                if policySession?.generation != policy.generation {
                    shouldIgnoreCurrentGesture = true
                }
                guard !shouldIgnoreCurrentGesture else { continue }
                // Defer the action so the event-tap callback can return immediately.
                actionDelivery.enqueue { [weak self] in
                    self?.onSwipe?(direction, fingers)
                }
            }
        }
    }

    private func resetGesture() {
        recognizer.reset()
        policySession = nil
        shouldIgnoreCurrentGesture = false
    }
}
