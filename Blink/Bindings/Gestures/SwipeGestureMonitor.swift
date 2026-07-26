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
                    // HID delivery can precede Dock ownership. Preserve the
                    // touch baseline without allowing recognition to dispatch.
                    recognizer.prime(sample, configuration: configuration)
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

    func drain(completion: @escaping @Sendable () -> Void) {
        queue.async(execute: completion)
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
    var onRecognitionSessionBegan: ((UInt64) -> Void)?
    var onRecognitionSessionEnded: ((UInt64) -> Void)?
    var onPhysicalContactEnded: ((UInt64) -> Void)?
    var onOperationalStateChanged: ((EventTapOperationalState) -> Void)?

    private var eventTap: EventTap?
    private let worker: SwipeRecognitionWorker
    private let deliveryQueue = DispatchQueue(
        label: "com.thekoppe.Blink.swipe-recognition-delivery",
        target: .main
    )
    private let requiresHealthyTapForDispatch: Bool
    private let contactInactivityDuration: Duration
    private var monitorEpoch: UInt64 = 0
    private var contactLifetime = PhysicalContactLifetimeState()
    private var contactInactivityTask: Task<Void, Never>?
    private var deliverableRecognitionTokens: Set<RecognitionToken> = []

    var operationalState: EventTapOperationalState {
        eventTap?.operationalState ?? .disabled
    }

    private struct RecognitionToken: Hashable, Sendable {
        let epoch: UInt64
        let contactID: UInt64
    }

    init(
        worker: SwipeRecognitionWorker = SwipeRecognitionWorker(),
        requiresHealthyTapForDispatch: Bool = true,
        contactInactivityDuration: Duration = .seconds(2)
    ) {
        self.worker = worker
        self.requiresHealthyTapForDispatch = requiresHealthyTapForDispatch
        self.contactInactivityDuration = contactInactivityDuration
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
                    self.onOperationalStateChanged?(.degraded)
                    self.invalidateRecognition()
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.eventTap?.recoverIfNeeded()
                        self.onOperationalStateChanged?(self.operationalState)
                    }
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
        onOperationalStateChanged?(operationalState)
    }

    func stopMonitoring() {
        monitorEpoch &+= 1
        contactInactivityTask?.cancel()
        contactInactivityTask = nil
        contactLifetime.reset()
        deliverableRecognitionTokens.removeAll(keepingCapacity: true)
        eventTap?.disable()
        eventTap = nil
        onOperationalStateChanged?(.disabled)
        worker.reset()
    }

    func ensureMonitoring() {
        guard eventTap != nil else { return }
        startMonitoring()
    }

    func invalidateRecognition() {
        monitorEpoch &+= 1
        contactInactivityTask?.cancel()
        contactInactivityTask = nil
        if let transition = contactLifetime.interrupt(),
            case .ended(let id) = transition
        {
            onPhysicalContactEnded?(id)
        }
        deliverableRecognitionTokens.removeAll(keepingCapacity: true)
        worker.reset()
    }

    func consume(_ sample: GestureSample) {
        let transitions = contactLifetime.consume(sample)
        var observedActivity = false
        for transition in transitions {
            switch transition {
            case .began(let id):
                observedActivity = true
                let token = RecognitionToken(epoch: monitorEpoch, contactID: id)
                deliverableRecognitionTokens.insert(token)
                onRecognitionSessionBegan?(id)
            case .ended(let id):
                finishRecognitionSession(id: id)
            case .sample(let id):
                observedActivity = true
                consume(sample, contactID: id)
            }
        }
        if observedActivity {
            scheduleContactInactivityIfNeeded()
        } else if contactLifetime.activeID == nil {
            contactInactivityTask?.cancel()
            contactInactivityTask = nil
        }
    }

    private func consume(_ sample: GestureSample, contactID: UInt64) {
        let configuration = SwipeRecognizer.Configuration(
            flipsDirection: flipSwipeDirection,
            allowsSameDirectionRepeat: allowSameDirectionRepeat,
            sameDirectionRepeatSensitivity: sameDirectionRepeatSensitivity
        )
        let context = contextForRecognition?()
        let queuedEpoch = monitorEpoch
        let recognitionToken = RecognitionToken(
            epoch: queuedEpoch,
            contactID: contactID
        )

        worker.consume(
            sample,
            configuration: configuration,
            proposedContext: context
        ) { [weak self] result in
            guard let result else { return }
            self?.deliveryQueue.async { [weak self] in
                MainActor.assumeIsolated {
                    guard
                        let self,
                        self.monitorEpoch == queuedEpoch,
                        self.deliverableRecognitionTokens.contains(recognitionToken),
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
    }

    /// Places normal teardown behind every recognition already accepted by the
    /// serial worker. The serial delivery queue preserves that order on main.
    func finishRecognitionSession() {
        guard let transition = contactLifetime.finish(),
            case .ended(let id) = transition
        else {
            return
        }
        finishRecognitionSession(id: id)
    }

    private func finishRecognitionSession(id: UInt64) {
        let token = RecognitionToken(epoch: monitorEpoch, contactID: id)
        onPhysicalContactEnded?(id)
        worker.finishSession { [weak self] in
            self?.deliveryQueue.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.deliverableRecognitionTokens.remove(token)
                    if self.contactLifetime.activeID == nil {
                        self.onRecognitionSessionEnded?(id)
                    }
                }
            }
        }
    }

    private func scheduleContactInactivityIfNeeded() {
        contactInactivityTask?.cancel()
        guard let activityToken = contactLifetime.activityToken else {
            contactInactivityTask = nil
            return
        }
        let duration = contactInactivityDuration
        contactInactivityTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            guard let transition = contactLifetime.expire(
                activityToken: activityToken
            ), case .ended(let id) = transition else {
                return
            }
            contactInactivityTask = nil
            finishRecognitionSession(id: id)
        }
    }

    func drain() async {
        await withCheckedContinuation { continuation in
            worker.drain { [deliveryQueue] in
                deliveryQueue.async {
                    continuation.resume()
                }
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
