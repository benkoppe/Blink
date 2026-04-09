//
//  HotkeyRecorderModel.swift
//  Blink
//
//  Created by Ben on 3/29/26.
//

import Observation
import SwiftUI

@MainActor @Observable
final class HotkeyRecorderModel {
    private weak var appState: AppState?

    private(set) var isRecording = false
    var isPresentingReservedByMacOSError = false

    let hotkey: Hotkey

    @ObservationIgnored
    private lazy var monitor = EventTap(
        label: "HotkeyRecorder",
        options: .defaultTap,
        location: .hidEventTap,
        place: .headInsertEventTap,
        types: [.keyDown],
        callback: { [weak self] proxy, type, event in
            guard let self else { return event }

            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                proxy.enable()
                return event

            case .keyDown:
                guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
                    return nil
                }
                handleKeyDown(event: event)
                return nil

            default:
                return event
            }
        }
    )

    init(hotkey: Hotkey, appState: AppState?) {
        self.hotkey = hotkey
        self.appState = appState
    }

    func startRecording() {
        guard !isRecording else { return }
        hotkey.disable()
        monitor.enable()
        isRecording = true
    }

    func stopRecording() {
        guard isRecording else { return }
        monitor.disable()
        hotkey.enable()
        isRecording = false
    }

    private func handleKeyDown(event: CGEvent) {
        let keyCombination = KeyCombination(cgEvent: event)

        guard !keyCombination.modifiers.isEmpty else {
            if keyCombination.key == .escape {
                stopRecording()
            } else {
                NSSound.beep()
            }
            return
        }

        guard keyCombination.modifiers != .shift else {
            NSSound.beep()
            return
        }

        guard !keyCombination.isReservedBySystem else {
            isPresentingReservedByMacOSError = true
            return
        }

        hotkey.keyCombination = keyCombination
        stopRecording()
    }
}
