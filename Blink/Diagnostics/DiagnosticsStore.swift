import AppKit
import CoreGraphics
import Foundation

nonisolated struct DiagnosticEvent: Sendable {
    let date: Date
    let category: String
    let message: String
}

nonisolated final class DiagnosticsStore: @unchecked Sendable {
    static let shared = DiagnosticsStore()

    private struct Snapshot {
        let events: [DiagnosticEvent]
        let totalEventCount: UInt64
        let categoryCounts: [String: UInt64]
        let overlayScanCount: UInt64
        let firstOverlayScanUptime: TimeInterval?
        let lastOverlayScanUptime: TimeInterval?
        let totalOverlayScanDuration: TimeInterval
        let maximumOverlayScanDuration: TimeInterval
    }

    private static let capacity = 200
    private let processStartedAtUptime: TimeInterval = {
        let now = ProcessInfo.processInfo.systemUptime
        guard let launchDate = NSRunningApplication.current.launchDate else {
            return now
        }
        return now - max(0, Date().timeIntervalSince(launchDate))
    }()
    private let lock = NSLock()
    private var events: [DiagnosticEvent] = []
    private var totalEventCount: UInt64 = 0
    private var categoryCounts: [String: UInt64] = [:]
    private var overlayScanCount: UInt64 = 0
    private var firstOverlayScanUptime: TimeInterval?
    private var lastOverlayScanUptime: TimeInterval?
    private var totalOverlayScanDuration: TimeInterval = 0
    private var maximumOverlayScanDuration: TimeInterval = 0

    func record(_ category: String, _ message: String) {
        lock.withLock {
            totalEventCount &+= 1
            categoryCounts[category, default: 0] &+= 1
            events.append(
                DiagnosticEvent(date: Date(), category: category, message: message)
            )
            if events.count > Self.capacity {
                events.removeFirst(events.count - Self.capacity)
            }
        }
    }

    func recordOverlayScan(startedAt: TimeInterval, endedAt: TimeInterval) {
        let duration = max(0, endedAt - startedAt)
        lock.withLock {
            overlayScanCount &+= 1
            firstOverlayScanUptime = firstOverlayScanUptime ?? startedAt
            lastOverlayScanUptime = endedAt
            totalOverlayScanDuration += duration
            maximumOverlayScanDuration = max(maximumOverlayScanDuration, duration)
        }
    }

    func report(version: String, build: String) -> String {
        let process = ProcessInfo.processInfo
        let formatter = ISO8601DateFormatter()
        let stored = lock.withLock {
            Snapshot(
                events: events,
                totalEventCount: totalEventCount,
                categoryCounts: categoryCounts,
                overlayScanCount: overlayScanCount,
                firstOverlayScanUptime: firstOverlayScanUptime,
                lastOverlayScanUptime: lastOverlayScanUptime,
                totalOverlayScanDuration: totalOverlayScanDuration,
                maximumOverlayScanDuration: maximumOverlayScanDuration
            )
        }
        var lines = [
            "Blink diagnostics",
            "Version: \(version) (\(build))",
            "macOS: \(process.operatingSystemVersionString)",
            "Process uptime: \(Int(max(0, process.systemUptime - processStartedAtUptime))) seconds",
            "Generated: \(formatter.string(from: Date()))",
            "",
            "Diagnostics volume:",
            "retained=\(stored.events.count)/\(Self.capacity) total=\(stored.totalEventCount) dropped=\(stored.totalEventCount - UInt64(stored.events.count))",
            "categories=" + stored.categoryCounts.keys.sorted().map {
                "\($0):\(stored.categoryCounts[$0] ?? 0)"
            }.joined(separator: ","),
            "",
            "Overlay scans:",
        ]

        lines.append(contentsOf: overlayScanReport(stored))
        lines.append("")
        lines.append("Event taps:")
        lines.append(contentsOf: eventTapReport())
        lines.append("")
        lines.append("Recent events:")
        lines.append(
            contentsOf: stored.events.map {
                "\(formatter.string(from: $0.date)) [\($0.category)] \($0.message)"
            }
        )
        return lines.joined(separator: "\n")
    }

    private func overlayScanReport(_ stored: Snapshot) -> [String] {
        let frequency: String
        if let first = stored.firstOverlayScanUptime,
            let last = stored.lastOverlayScanUptime,
            last > first
        {
            frequency = String(
                format: "%.3f",
                Double(stored.overlayScanCount - 1) / (last - first)
            )
        } else {
            frequency = "n/a"
        }
        let averageDuration = stored.overlayScanCount == 0
            ? 0
            : stored.totalOverlayScanDuration / Double(stored.overlayScanCount) * 1_000
        return [
            "count=\(stored.overlayScanCount) lifetime-average-hz=\(frequency) "
                + "duration-ms(avg/max)="
                + String(
                    format: "%.3f/%.3f",
                    averageDuration,
                    stored.maximumOverlayScanDuration * 1_000
                )
        ]
    }

    private func eventTapReport() -> [String] {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success else {
            return ["Unavailable"]
        }
        guard count > 0 else { return ["None"] }

        var taps = Array(repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &taps, &count) == .success else {
            return ["Unavailable"]
        }

        let ownTaps = taps.prefix(Int(count)).filter { $0.tappingProcess == getpid() }
        guard !ownTaps.isEmpty else { return ["No Blink taps installed"] }

        return ownTaps.map {
            "id=\($0.eventTapID) point=\($0.tapPoint) enabled=\($0.enabled) "
                + "latency-us(min/avg/max)=\($0.minUsecLatency)/\($0.avgUsecLatency)/\($0.maxUsecLatency)"
        }
    }
}

@MainActor
final class DiagnosticsController {
    func copyReport() {
        let report = DiagnosticsStore.shared.report(
            version: Constants.versionString,
            build: Constants.buildString
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
}
