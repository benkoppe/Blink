//
//  SpaceIndicatorPresentation.swift
//  Blink
//

import Foundation
import Observation

/// Keeps predicted feedback stable through delayed or interleaved Space notifications.
@MainActor
@Observable
final class SpaceIndicatorPresentation {
    private struct Prediction {
        let spaceID: UInt64
        let revision = UUID()
    }

    private var predictions: [String: Prediction] = [:]

    @ObservationIgnored
    private var reconciliationTasks: [String: Task<Void, Never>] = [:]

    @ObservationIgnored
    private let waitForSettling: @MainActor () async throws -> Void

    @ObservationIgnored
    private let refreshObservedState: @MainActor () -> Void

    init(
        waitForSettling: @MainActor @escaping () async throws -> Void = {
            try await Task.sleep(for: .seconds(3))
        },
        refreshObservedState: @MainActor @escaping () -> Void
    ) {
        self.waitForSettling = waitForSettling
        self.refreshObservedState = refreshObservedState
    }

    func displayedSpaceIndex(in topology: SpaceSwitchCoordinator.Topology) -> Int? {
        let spaceID = predictions[topology.displayIdentifier]?.spaceID ?? topology.currentSpaceID
        return topology.index(of: spaceID) ?? topology.index(of: topology.currentSpaceID)
    }

    func predict(spaceID: UInt64, for displayIdentifier: String) {
        reconciliationTasks.removeValue(forKey: displayIdentifier)?.cancel()
        let prediction = Prediction(spaceID: spaceID)
        predictions[displayIdentifier] = prediction
        let wait = waitForSettling
        reconciliationTasks[displayIdentifier] = Task { @MainActor [weak self] in
            do {
                try await wait()
            } catch {
                return
            }
            guard
                !Task.isCancelled,
                let self,
                self.predictions[displayIdentifier]?.revision == prediction.revision
            else { return }
            self.refreshObservedState()
            // Refresh may invalidate the topology; never remove a newer request.
            guard self.predictions[displayIdentifier]?.revision == prediction.revision else { return }
            self.predictions.removeValue(forKey: displayIdentifier)
            self.reconciliationTasks.removeValue(forKey: displayIdentifier)
        }
    }

    func discardInvalidPredictions(in topologies: [String: SpaceSwitchCoordinator.Topology]) {
        for (displayIdentifier, prediction) in predictions {
            if topologies[displayIdentifier]?.spaceIDs.contains(prediction.spaceID) != true {
                predictions.removeValue(forKey: displayIdentifier)
                reconciliationTasks.removeValue(forKey: displayIdentifier)?.cancel()
            }
        }
    }

    func cancelAll() {
        for task in reconciliationTasks.values {
            task.cancel()
        }
        reconciliationTasks.removeAll()
        predictions.removeAll()
    }
}
