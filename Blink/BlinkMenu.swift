import AppKit
import SwiftUI

/// The status item's native menu. Items retain their identity while tracking;
/// state updates don't rebuild the menu underneath the keyboard or pointer.
@MainActor
final class BlinkMenu: NSObject, NSMenuDelegate {
    enum Command {
        case bound(BoundAction)
        case index(Int)
        case settings, toggleBindings, quit
    }

    let menu = NSMenu()
    private let appState: AppState
    private let jumpMenu = NSMenu(title: "Jump to...")
    private var actionItems: [BoundAction: NSMenuItem] = [:]
    private var indexedItems: [NSMenuItem] = []
    private var toggleItem: NSMenuItem!
    private var isTracking = false

    init(appState: AppState) {
        self.appState = appState
        super.init()
        menu.autoenablesItems = false
        jumpMenu.autoenablesItems = false
        menu.delegate = self
        actionItems[.left] = add("Switch left", command: .bound(.left), symbol: "arrow.left")
        actionItems[.right] = add("Switch right", command: .bound(.right), symbol: "arrow.right")
        menu.addItem(.separator())
        let jump = NSMenuItem(title: "Jump to...", action: nil, keyEquivalent: "")
        jump.image = NSImage(systemSymbolName: "square.and.line.vertical.and.square", accessibilityDescription: nil)
        jump.submenu = jumpMenu
        menu.addItem(jump)
        actionItems[.lastSpace] = add("Last Space", command: .bound(.lastSpace), to: jumpMenu)
        jumpMenu.addItem(.separator())
        menu.addItem(.separator())
        let version = NSMenuItem(title: "\(Constants.appName) \(Constants.versionString)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        add("Settings...", command: .settings, symbol: "gearshape").keyEquivalent = ","
        toggleItem = add("Disable", command: .toggleBindings)
        toggleItem.keyEquivalent = "e"
        add("Quit", command: .quit).keyEquivalent = "q"
        update()
    }

    @discardableResult
    private func add(_ title: String, command: Command, symbol: String? = nil, to parent: NSMenu? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(performCommand(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = command
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        (parent ?? menu).addItem(item)
        return item
    }

    func update() {
        let switcher = appState.spaceSwitcher
        actionItems[.left]?.isEnabled = switcher.canMoveLeft()
        actionItems[.right]?.isEnabled = switcher.canMoveRight()
        actionItems[.lastSpace]?.isEnabled = switcher.canSwitchToLastSpace()
        for (action, item) in actionItems { updateShortcut(item, action: action) }

        let count = switcher.spaceInfo?.spaceCount ?? 0
        // Defer structural edits until tracking ends, but disable obsolete rows
        // immediately so a removed Space cannot be selected.
        if !isTracking && indexedItems.count != count {
            for item in indexedItems { jumpMenu.removeItem(item) }
            indexedItems = (0..<count).map { add("Space \($0 + 1)", command: .index($0), to: jumpMenu) }
        }
        for (index, item) in indexedItems.enumerated() {
            item.isEnabled = index < count
            item.state = index == switcher.spaceInfo?.currentIndex ? .on : .off
            updateShortcut(item, action: BoundAction.indexedSpaceActions.indices.contains(index)
                           ? BoundAction.indexedSpaceActions[index] : nil)
        }
        toggleItem.title = appState.settingsManager.generalSettingsManager.bindingsEnabled ? "Disable" : "Enable"
    }

    private func updateShortcut(_ item: NSMenuItem, action: BoundAction?) {
        let combination = action.flatMap { appState.settingsManager.hotkeySettingsManager.hotkey(withAction: $0)?.keyCombination }
        item.keyEquivalent = combination?.key.swiftUIKeyEquivalent.map { String($0.character) } ?? ""
        item.keyEquivalentModifierMask = combination?.modifiers.nsEventFlags ?? []
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        appState.spaceSwitcher.refreshSpaceInfo()
        update()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isTracking = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isTracking = false
        update()
    }

    @objc private func performCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? Command else { return }
        switch command {
        case .bound(let action): action.execute(appState: appState)
        case .index(let index): appState.spaceSwitcher.switchToIndex(index)
        case .settings: appState.appDelegate?.openSettingsWindow()
        case .toggleBindings: appState.settingsManager.generalSettingsManager.bindingsEnabled.toggle()
        case .quit: NSApp.terminate(nil)
        }
    }
}
