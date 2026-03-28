//
//  Hotkey.swift
//  Blink
//
//  Created by Ben on 3/25/26.
//

import Observation

/// A combination of a key and modifiers that can be used to
/// trigger actions on system-wide key-up or key-down events
@Observable
final class Hotkey {
    @ObservationIgnored
    private weak var appState: AppState?

    @ObservationIgnored
    private var listener: Listener?

    let action: BoundAction

    var keyCombination: KeyCombination? {
        didSet {
            guard oldValue != keyCombination else { return }
            updateListener()
        }
    }

    var isEnabled: Bool {
        listener != nil
    }

    init(keyCombination: KeyCombination?, action: BoundAction) {
        self.keyCombination = keyCombination
        self.action = action
    }

    func assignAppState(_ appState: AppState) {
        self.appState = appState
        updateListener()
    }

    // MARK: - Listener lifecycle

    func updateListener() {
        disable()

        guard
            keyCombination != nil,
            let appState
        else { return }

        listener = Listener(
            hotkey: self,
            eventKind: .keyDown,
            appState: appState
        )
    }

    func disable() {
        listener?.invalidate()
        listener = nil
    }
}

extension Hotkey {
    /// An object that manages the lifetime of a hotkey observation.
    private final class Listener {
        private weak var appState: AppState?
        private var id: UInt32?

        var isValid: Bool {
            id != nil
        }

        init?(hotkey: Hotkey, eventKind: HotkeyRegistry.EventKind, appState: AppState?) {
            guard
                let appState,
                hotkey.keyCombination != nil
            else {
                return nil
            }
            let id = appState.hotkeyRegistry.register(
                hotkey: hotkey,
                eventKind: eventKind
            ) { [weak appState] in
                guard let appState else {
                    return
                }
                Task {
                    hotkey.action.execute(appState: appState)
                }
            }
            guard let id else {
                return nil
            }
            self.appState = appState
            self.id = id
        }

        deinit {
            invalidate()
        }

        func invalidate() {
            guard isValid else {
                return
            }
            guard let appState else {
                Logger.hotkey.error("Error invalidating hotkey: Missing AppState")
                return
            }
            defer {
                id = nil
            }
            if let id {
                appState.hotkeyRegistry.unregister(id)
            }
        }
    }
}

// MARK: Hotkey: Codable
extension Hotkey: Codable {
    private enum CodingKeys: CodingKey {
        case keyCombination
        case action
    }

    convenience init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            keyCombination: container.decode(KeyCombination?.self, forKey: .keyCombination),
            action: container.decode(BoundAction.self, forKey: .action)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCombination, forKey: .keyCombination)
        try container.encode(action, forKey: .action)
    }
}

// MARK: Hotkey: Equatable
extension Hotkey: Equatable {
    static func == (lhs: Hotkey, rhs: Hotkey) -> Bool {
        lhs.keyCombination == rhs.keyCombination && lhs.action == rhs.action
    }
}

// MARK: Hotkey: Hashable
extension Hotkey: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCombination)
        hasher.combine(action)
    }
}

// MARK: - Logger
extension Logger {
    fileprivate static let hotkey = Logger(category: "Hotkey")
}
