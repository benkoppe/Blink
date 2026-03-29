//
//  PermissionsManager.swift
//  Blink
//
//  Created by Ben on 3/29/26.
//

import Foundation
import Observation

/// Manages the permissions of the app.
@MainActor @Observable
final class PermissionsManager {
    /// The state of the granted permissions for the app.
    enum PermissionsState {
        case missingPermissions
        case hasAllPermissions
        case hasRequiredPermissions
    }

    /// The state of the granted permissions for the app.
    var permissionsState: PermissionsState = .missingPermissions

    let accessibilityPermission: AccessibilityPermission

    let allPermissions: [Permission]

    private(set) weak var appState: AppState?

    var requiredPermissions: [Permission] {
        allPermissions.filter { $0.isRequired }
    }

    init(appState: AppState) {
        self.appState = appState
        self.accessibilityPermission = AccessibilityPermission()
        self.allPermissions = [
            accessibilityPermission
        ]

        updateState()
        startObservingPermissions()
    }

    private func startObservingPermissions() {
        func observe() {
            withObservationTracking {
                _ = MainActor.assumeIsolated { accessibilityPermission.hasPermission }
            } onChange: {
                Task { @MainActor in
                    self.updateState()
                    observe()
                }
            }
        }

        observe()
    }

    private func updateState() {
        if allPermissions.allSatisfy({ $0.hasPermission }) {
            permissionsState = .hasAllPermissions
        } else if requiredPermissions.allSatisfy({ $0.hasPermission }) {
            permissionsState = .hasRequiredPermissions
        } else {
            permissionsState = .missingPermissions
        }
    }

    func stopAllChecks() {
        for permission in allPermissions {
            permission.stopCheck()
        }
    }
}
