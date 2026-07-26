import CoreGraphics
import Foundation
import Testing

@testable import Blink

func waitUntil(
    _ condition: @escaping @MainActor () async -> Bool
) async {
    for _ in 0..<1_000 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timed out waiting for gesture test condition")
}

func routingLease(
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

func version(_ major: Int, _ minor: Int) -> OperatingSystemVersion {
    OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
}

func touches(
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

func blinkContext(generation: UInt64 = 1) -> GestureSessionContext {
    GestureSessionContext(
        generation: generation,
        route: .blink,
        targetDisplayID: DisplayID(rawValue: "display-a")!,
        capturedOverlayMode: .none,
        missionControlSyntheticState: .available,
        requiredPostingMode: .instant
    )
}

func dockWindow(layer: Int, bounds: CGRect) -> WindowDescriptor {
    WindowDescriptor(
        ownerName: "Dock",
        ownerBundleID: "com.apple.dock",
        layer: layer,
        bounds: bounds
    )
}

nonisolated final class RecognitionProbe: @unchecked Sendable {
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

nonisolated struct FixedDisplayLocator: DisplayLocating {
    let displayID: DisplayID

    func cursorDisplayID() throws -> DisplayID { displayID }

    func bounds(for displayID: DisplayID) -> CGRect? {
        displayID == self.displayID
            ? CGRect(x: 0, y: 0, width: 1920, height: 1080)
            : nil
    }
}

nonisolated final class ControlledOverlayDetector: OverlayDetecting, @unchecked Sendable {
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

nonisolated final class RoutingLeaseSink: @unchecked Sendable {
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

nonisolated final class RoutingTestClock: @unchecked Sendable {
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

actor RoutingTestSleeper {
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
