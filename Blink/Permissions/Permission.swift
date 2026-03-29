//
//  Permission.swift
//  Blink
//
//  Created by Ben on 3/29/26.
//

import AXSwift
import Cocoa

// MARK: - Permission

/// An object that encapsulates the behavior of checking for and requesting
/// a specific permission for the app.
@MainActor @Observable
class Permission: Identifiable {
    /// A boolean value that indicates whether the app has this permission.
    private(set) var hasPermission = false

    /// The title of the permission.
    let title: String
    /// Descriptive details for the permission.
    let details: [String]
    /// A boolean value that indicates if the app can work without this permission.
    let isRequired: Bool

    /// The URL of the settings pane to oepn.
    private let settingsURL: URL?
    /// The function that checks permissions.
    private let check: () -> Bool
    /// The function that requests permissions.
    private let request: () -> Void

    /// Runs on a timer to check permissions.
    @ObservationIgnored private var timerTask: Task<Void, Never>?

    /// Creates a permission.
    ///
    /// - Parameters:
    ///   - title: The title of the permission.
    ///   - details: Descriptive details for the permission.
    ///   - isRequired: A Boolean value that indicates if the app can work without this permission.
    ///   - settingsURL: The URL of the settings pane to open.
    ///   - check: A function that checks permissions.
    ///   - request: A function that requests permissions.
    init(
        title: String,
        details: [String],
        isRequired: Bool,
        settingsURL: URL?,
        check: @escaping () -> Bool,
        request: @escaping () -> Void
    ) {
        self.title = title
        self.details = details
        self.isRequired = isRequired
        self.settingsURL = settingsURL
        self.check = check
        self.request = request
        self.hasPermission = check()
        configureTimer()
    }

    /// Sets up the internal timer Task for the permission.
    private func configureTimer() {
        timerTask?.cancel()

        timerTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.hasPermission = self.check()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// Performs the request and opens the System Settings app to the appropriate pane.
    func performRequest() {
        request()
        if let settingsURL {
            NSWorkspace.shared.open(settingsURL)
        }
    }

    /// Asynchronously waits for the app to be granted this permission.
    func waitForPermission() async {
        configureTimer()

        guard !hasPermission else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                var resumed = false

                func observe() {
                    withObservationTracking {
                        _ = MainActor.assumeIsolated { self.hasPermission }
                    } onChange: {
                        Task { @MainActor in
                            guard !resumed else { return }

                            if self.hasPermission {
                                resumed = true
                                continuation.resume()
                            } else {
                                observe()  // re-arm
                            }
                        }
                    }
                }

                observe()
            }
        }
    }

    /// Stops running the permission check.
    func stopCheck() {
        timerTask?.cancel()
        timerTask = nil
    }
}

// MARK - AccessibilityPermission

final class AccessibilityPermission: Permission {
    init() {
        super.init(
            title: "Accessibility",
            details: [
                "Perform instant space switches.",
                "Capture your gesture inputs.",
            ],
            isRequired: true,
            settingsURL: nil,
            check: {
                checkIsProcessTrusted()
            },
            request: {
                checkIsProcessTrusted(prompt: true)
            }
        )
    }
}
