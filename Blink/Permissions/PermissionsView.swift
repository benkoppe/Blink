//
//  PermissionsView.swift
//  Blink
//
//  Created by Ben on 3/29/26.
//

import SwiftUI

struct PermissionsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var permissionsManager: PermissionsManager {
        appState.permissionsManager
    }

    private var continueButtonText: LocalizedStringKey {
        if case .hasRequiredPermissions = permissionsManager.permissionsState {
            "Continue in Limited Mode"
        } else {
            "Continue"
        }
    }

    private var continueButtonForegroundStyle: some ShapeStyle {
        if case .hasRequiredPermissions = permissionsManager.permissionsState {
            AnyShapeStyle(.yellow)
        } else {
            AnyShapeStyle(.primary)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .padding(.vertical)

            explanationView
            permissionsGroupStack

            footerView
                .padding(.vertical)
        }
        .padding(.horizontal)
        .fixedSize()
        .readWindow { window in
            guard let window else { return }
            window.styleMask.remove([.closable, .miniaturizable])
            if let contentView = window.contentView {
                with(contentView.safeAreaInsets) { insets in
                    insets.bottom = -insets.bottom
                    insets.left = -insets.left
                    insets.right = -insets.right
                    insets.top = -insets.top
                    contentView.additionalSafeAreaInsets = insets
                }
            }
        }
    }

    @ViewBuilder
    private var headerView: some View {
        Label {
            Text("Permissions")
                .font(.system(size: 36))
        } icon: {
            if let nsImage = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 75, height: 75)
            }
        }
    }

    @ViewBuilder
    private var explanationView: some View {
        BlinkSection {
            VStack {
                Text("Blink needs permission for instant space switches.")
                Text("Absolutely no personal information is collected or stored.")
                    .bold()
                    .foregroundStyle(.red)
            }
            .padding()
        }
        .font(.title3)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var permissionsGroupStack: some View {
        VStack(spacing: 7.5) {
            ForEach(permissionsManager.allPermissions) { permission in
                permissionBox(permission)
            }
        }
    }

    @ViewBuilder
    private var footerView: some View {
        HStack {
            quitButton
            continueButton
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var quitButton: some View {
        Button {
            quit()
        } label: {
            Text("Quit")
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var continueButton: some View {
        Button {
            appState.performSetup()
            appState.permissionsWindow?.close()
            appState.appDelegate?.openSettingsWindow()
        } label: {
            Text(continueButtonText)
                .frame(maxWidth: .infinity)
                .foregroundStyle(continueButtonForegroundStyle)
        }
        .disabled(permissionsManager.permissionsState == .missingPermissions)
    }

    @ViewBuilder
    private func permissionBox(_ permission: Permission) -> some View {
        BlinkSection {
            VStack(spacing: 10) {
                Text(permission.title)
                    .font(.title)
                    .underline()

                VStack(spacing: 0) {
                    Text("Blink needs this to:")
                        .font(.title3)
                        .bold()

                    VStack(alignment: .leading) {
                        ForEach(permission.details, id: \.self) { detail in
                            HStack {
                                Text("•").bold()
                                Text(detail)
                            }
                        }
                    }
                }

                Button {
                    permission.performRequest()
                    Task {
                        await permission.waitForPermission()
                        appState.activate(withPolicy: .regular)
                        openWindow(id: Constants.permissionsWindowID)
                    }
                } label: {
                    if permission.hasPermission {
                        Text("Permission Granted")
                            .foregroundStyle(.green)
                    } else {
                        Text("Grant Permission")
                    }
                }
                .allowsHitTesting(!permission.hasPermission)

                if !permission.isRequired {
                    BlinkGroupBox {
                        AnnotationView(alignment: .center, font: .callout.bold()) {
                            Label {
                                Text("Blink can work in a limited mode without this permission.")
                            } icon: {
                                Image(systemName: "checkmark.shield")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
        }
    }
}

#Preview {
    PermissionsView()
}
