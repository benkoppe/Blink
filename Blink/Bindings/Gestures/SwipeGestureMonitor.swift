import AppKit
import CoreGraphics
import Foundation

nonisolated final class SwipeRecognitionWorker: @unchecked Sendable {
    typealias Recognition = (
        context: GestureSessionContext,
        direction: SwipeDirection,
        fingerCount: Int
    )

    private let queue: DispatchQueue
    private var recognizer = SwipeRecognizer()
    private var sessionContext: GestureSessionContext?

    init(queue: DispatchQueue = DispatchQueue(
        label: "com.thekoppe.Blink.swipe-recognition"
    )) {
        self.queue = queue
    }

    func consume(
        _ sample: GestureSample,
        configuration: SwipeRecognizer.Configuration,
        proposedContext: GestureSessionContext?,
        completion: @escaping @Sendable (Recognition?) -> Void
    ) {
        queue.async { [self] in
            if sessionContext == nil {
                guard let proposedContext else {
                    // HID delivery can precede route selection. Do not feed that
                    // movement to the recognizer without an authoritative owner.
                    completion(nil)
                    return
                }
                sessionContext = proposedContext
            }

            guard let context = sessionContext else {
                completion(nil)
                return
            }
            let result = recognizer.consume(
                sample,
                configuration: configuration,
                ignoreNewGesture: !context.isAuthoritativeBlinkContext
            )
            completion(result.map {
                Recognition(
                    context: context,
                    direction: $0.direction,
                    fingerCount: $0.fingerCount
                )
            })
        }
    }

    func finishSession(completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            recognizer.reset()
            sessionContext = nil
            completion()
        }
    }

    func reset() {
        queue.async { [self] in
            recognizer.reset()
            sessionContext = nil
        }
    }
}

@MainActor
final class SwipeGestureMonitor {
    var onSwipe: ((GestureSessionContext, SwipeDirection, Int) -> Void)?
    var flipSwipeDirection = false
    var allowSameDirectionRepeat = false
    var sameDirectionRepeatSensitivity = 0.06
    var contextForRecognition: (() -> GestureSessionContext?)?
    var isContextValidBeforeDispatch: ((GestureSessionContext) -> Bool)?
    var onRecognitionSessionMayBegin: (() -> Void)?
    var onRecognitionSessionEnded: (() -> Void)?

    private var eventTap: EventTap?
    private let worker: SwipeRecognitionWorker
    private let requiresHealthyTapForDispatch: Bool
    private var monitorEpoch: UInt64 = 0
    private var recognitionSessionIsActive = false

    init(
        worker: SwipeRecognitionWorker = SwipeRecognitionWorker(),
        requiresHealthyTapForDispatch: Bool = true
    ) {
        self.worker = worker
        self.requiresHealthyTapForDispatch = requiresHealthyTapForDispatch
    }

    func startMonitoring() {
        if let eventTap, eventTap.isHealthy {
            return
        }

        if eventTap != nil {
            invalidateRecognition()
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
                    self.invalidateRecognition()
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

                    self.consume(sample)
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
        monitorEpoch &+= 1
        recognitionSessionIsActive = false
        eventTap?.disable()
        eventTap = nil
        worker.reset()
    }

    func ensureMonitoring() {
        guard eventTap != nil else { return }
        startMonitoring()
    }

    func invalidateRecognition() {
        monitorEpoch &+= 1
        recognitionSessionIsActive = false
        worker.reset()
    }

    func consume(_ sample: GestureSample) {
        guard sample.activeFingerCount > 0 else {
            recognitionSessionIsActive = false
            finishRecognitionSession()
            return
        }
        if !recognitionSessionIsActive {
            recognitionSessionIsActive = true
            onRecognitionSessionMayBegin?()
        }
        let configuration = SwipeRecognizer.Configuration(
            flipsDirection: flipSwipeDirection,
            allowsSameDirectionRepeat: allowSameDirectionRepeat,
            sameDirectionRepeatSensitivity: sameDirectionRepeatSensitivity
        )
        let context = contextForRecognition?()
        let queuedEpoch = monitorEpoch

        worker.consume(
            sample,
            configuration: configuration,
            proposedContext: context
        ) { [weak self] result in
            guard let result else { return }
            DispatchQueue.main.async { [weak self] in
                guard
                    let self,
                    self.monitorEpoch == queuedEpoch,
                    (!self.requiresHealthyTapForDispatch
                        || self.eventTap?.isHealthy == true),
                    self.isContextValidBeforeDispatch?(result.context) ?? true
                else {
                    return
                }
                self.onSwipe?(
                    result.context,
                    result.direction,
                    result.fingerCount
                )
                Logger.swipeGestureMonitor.debug(
                    "recognized direction=\(result.direction) fingers=\(result.fingerCount) session=\(result.context.generation)"
                )
            }
        }
    }

    /// Places normal teardown behind every recognition already accepted by the
    /// serial worker. Main-queue delivery preserves that same order.
    func finishRecognitionSession() {
        let queuedEpoch = monitorEpoch
        worker.finishSession { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.monitorEpoch == queuedEpoch else { return }
                self.onRecognitionSessionEnded?()
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
