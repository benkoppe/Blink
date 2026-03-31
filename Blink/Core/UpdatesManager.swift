//
//  UpdatesManager.swift
//  Blink
//
//  Created by Ben on 3/31/26.
//

import Combine
import Observation
import Sparkle
import SwiftUI

/// Manager for app updates.
@MainActor @Observable
final class UpdatesManager: NSObject {
    /// A Boolean value that indicates whether the user can check for updates
    var canCheckForUpdates = false

    /// The date of the last update check
    var lastUpdateCheckDate: Date?

    private var cancellables = Set<AnyCancellable>()

    /// The shared app state.
    @ObservationIgnored private(set) weak var appState: AppState?

    /// The underlying updater controller.
    @ObservationIgnored private(set) lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: self
    )

    /// The underlying updater.
    var updater: SPUUpdater {
        updaterController.updater
    }

    /// A Boolean value that indicates whether to automatically check for updates.
    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    /// A Boolean value that indicates whether to automatically download updates.
    var automaticallyDownloadsUpdates: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }

    /// Creates an updates manager with the given app state.
    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    /// Sets up the manager.
    func performSetup() {
        _ = updaterController
        configureCancellables()
    }

    private func configureCancellables() {
        updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &cancellables)

        updater.publisher(for: \.lastUpdateCheckDate)
            .sink { [weak self] in self?.lastUpdateCheckDate = $0 }
            .store(in: &cancellables)
    }

    // MARK: - Actions

    @objc func checkForUpdates() {
        #if DEBUG
            let alert = NSAlert()
            alert.messageText = "Checking for updates is not supported in debug mode."
            alert.runModal()
        #else
            guard let appState else { return }

            appState.activate(withPolicy: .regular)
            appState.openSettingsWindow()
            updater.checkForUpdates()
        #endif
    }
}

// MARK: UpdatesManager: SPUUpdaterDelegate
extension UpdatesManager: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        guard let appState else { return }
        appState.userNotificationManager.requestAuthorization()
    }
}

// MARK: UpdatesManager: SPUStandardUserDriverDelegate
extension UpdatesManager: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        if NSApp.isActive {
            return immediateFocus
        } else {
            return false
        }
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard let appState else { return }
        if !state.userInitiated {
            appState.userNotificationManager.addRequest(
                with: .updateCheck,
                title: "A new update is available",
                body: "Version \(update.displayVersionString) is now available"
            )
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        guard let appState else { return }
        appState.userNotificationManager.removeDeliveredNotifications(with: [.updateCheck])
    }
}
