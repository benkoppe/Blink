import AppKit
import Observation

@MainActor
final class MenuBarController {
    private let appState: AppState
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let blinkMenu: BlinkMenu
    private var renderedModel: SpaceIconRenderModel?
    private var hasRendered = false
    private var isStopped = false

    init(appState: AppState) {
        self.appState = appState
        blinkMenu = BlinkMenu(appState: appState)
        statusItem.autosaveName = "Blink.SpaceIndicator"
        statusItem.menu = blinkMenu.menu
        observeState()
    }

    private func observeState() {
        guard !isStopped else { return }
        withObservationTracking {
            let model = SpaceIconRenderModel.current(appState: appState)
            if !hasRendered || model != renderedModel {
                hasRendered = true
                renderedModel = model
                let image = model.flatMap(SpaceIconRenderer.image(for:))
                    ?? NSImage(systemSymbolName: Constants.sfSymbol, accessibilityDescription: "Blink")
                statusItem.button?.image = image
            }
            let description = appState.spaceSwitcher.spaceInfo.map {
                "Blink, Space \($0.currentIndex + 1) of \($0.spaceCount)"
            } ?? "Blink, Space unavailable"
            statusItem.button?.setAccessibilityLabel(description)
            statusItem.button?.toolTip = description
            blinkMenu.update()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeState() }
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    deinit {
        MainActor.assumeIsolated { stop() }
    }
}
