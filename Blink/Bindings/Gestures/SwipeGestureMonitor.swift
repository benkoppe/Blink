import AppKit
import CoreGraphics
import Foundation

private final class SwipeRecognitionWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.thekoppe.Blink.swipe-recognition")
    private var recognizer = SwipeRecognizer()

    func consume(
        _ sample: GestureSample,
        configuration: SwipeRecognizer.Configuration,
        ignoreNewGesture: Bool,
        completion: @escaping @Sendable (
            (direction: SwipeDirection, fingerCount: Int)?
        ) -> Void
    ) {
        queue.async { [self] in
            completion(
                recognizer.consume(
                    sample,
                    configuration: configuration,
                    ignoreNewGesture: ignoreNewGesture
                )
            )
        }
    }

    func reset() {
        queue.async { [self] in
            recognizer.reset()
        }
    }
}

final class SwipeGestureMonitor {
    var onSwipe: ((SwipeDirection, Int) -> Void)?
    var flipSwipeDirection = false
    var allowSameDirectionRepeat = false
    var sameDirectionRepeatSensitivity = 0.06
    var shouldIgnoreSwipe: (() -> Bool)?

    private var eventTap: EventTap?
    private let worker = SwipeRecognitionWorker()

    func startMonitoring() {
        if let eventTap, eventTap.isHealthy {
            return
        }

        eventTap?.disable()

        let tap = EventTap(
            label: "SwipeGestureMonitor",
            options: .listenOnly,
            location: .hidEventTap,
            place: .headInsertEventTap,
            types: [.gesture],
            callback: { [weak self] _, type, event in
                guard let self else { return event }

                switch type {
                case .tapDisabledByTimeout, .tapDisabledByUserInput:
                    self.worker.reset()
                    return event
                case .gesture:
                    guard
                        event.getIntegerValueField(
                            SyntheticGestureProtocol.markerField
                        ) != SyntheticGestureProtocol.markerValue,
                        let sample = Self.makeSample(from: event)
                    else {
                        return event
                    }

                    DispatchQueue.main.async { [weak self] in
                        self?.consume(sample)
                    }
                    return event
                default:
                    return event
                }
            }
        )

        tap.enable()
        eventTap = tap
    }

    func stopMonitoring() {
        eventTap?.disable()
        eventTap = nil
        worker.reset()
    }

    func ensureMonitoring() {
        guard eventTap != nil else { return }
        startMonitoring()
    }

    private func consume(_ sample: GestureSample) {
        let configuration = SwipeRecognizer.Configuration(
            flipsDirection: flipSwipeDirection,
            allowsSameDirectionRepeat: allowSameDirectionRepeat,
            sameDirectionRepeatSensitivity: sameDirectionRepeatSensitivity
        )
        let shouldIgnore = shouldIgnoreSwipe?() ?? false

        worker.consume(
            sample,
            configuration: configuration,
            ignoreNewGesture: shouldIgnore
        ) { [weak self] result in
            guard let result else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onSwipe?(result.direction, result.fingerCount)
                Logger.swipeGestureMonitor.debug(
                    "recognized direction=\(result.direction) fingers=\(result.fingerCount)"
                )
            }
        }
    }

    private static func makeSample(from event: CGEvent) -> GestureSample? {
        guard let nsEvent = NSEvent(cgEvent: event) else { return nil }

        let touches = nsEvent.allTouches().map {
            GestureTouchSample(
                identity: String(describing: $0.identity),
                position: $0.normalizedPosition,
                isEnded: $0.phase == .ended || $0.phase == .cancelled
            )
        }
        return GestureSample(touches: touches)
    }
}

extension Logger {
    fileprivate static let swipeGestureMonitor = Logger(category: "SwipeGestureMonitor")
}
