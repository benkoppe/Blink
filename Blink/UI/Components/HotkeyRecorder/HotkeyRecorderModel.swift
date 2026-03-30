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
    private lazy var monitor = LocalEventMonitor(mask: .keyDown) { [weak self] event in
        guard let self else { return event }
        handleKeyDown(event: event)
        return nil
    }

    init(hotkey: Hotkey, appState: AppState?) {
        self.hotkey = hotkey
        self.appState = appState
    }

    func startRecording() {
        guard !isRecording else { return }
        hotkey.disable()
        monitor.start()
        isRecording = true
    }

    func stopRecording() {
        guard isRecording else { return }
        monitor.stop()
        hotkey.enable()
        isRecording = false
    }

    private func handleKeyDown(event: NSEvent) {
        let keyCombination = KeyCombination(event: event)

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
