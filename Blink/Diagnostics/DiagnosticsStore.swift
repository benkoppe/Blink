import AppKit
import CoreGraphics
import Foundation

nonisolated struct DiagnosticEvent: Sendable {
    let date: Date
    let category: String
    let message: String
}

actor DiagnosticsStore {
    static let shared = DiagnosticsStore()

    private static let capacity = 200
    private var events: [DiagnosticEvent] = []

    func record(_ category: String, _ message: String) {
        events.append(
            DiagnosticEvent(date: Date(), category: category, message: message)
        )
        if events.count > Self.capacity {
            events.removeFirst(events.count - Self.capacity)
        }
    }

    func report(version: String, build: String) -> String {
        let process = ProcessInfo.processInfo
        let formatter = ISO8601DateFormatter()
        var lines = [
            "Blink diagnostics",
            "Version: \(version) (\(build))",
            "macOS: \(process.operatingSystemVersionString)",
            "Process uptime: \(Int(process.systemUptime)) seconds",
            "Generated: \(formatter.string(from: Date()))",
            "",
            "Event taps:",
        ]

        lines.append(contentsOf: eventTapReport())
        lines.append("")
        lines.append("Recent events:")
        lines.append(
            contentsOf: events.map {
                "\(formatter.string(from: $0.date)) [\($0.category)] \($0.message)"
            }
        )
        return lines.joined(separator: "\n")
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
        let version = Constants.versionString
        let build = Constants.buildString
        Task {
            let report = await DiagnosticsStore.shared.report(
                version: version,
                build: build
            )
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
        }
    }
}
