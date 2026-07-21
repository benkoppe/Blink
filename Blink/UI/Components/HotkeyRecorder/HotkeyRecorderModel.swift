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
    private(set) var isRecording = false
    var isPresentingReservedByMacOSError = false

    let hotkey: Hotkey
    private let onRecordingChanged: (Bool) -> Void

    @ObservationIgnored
    private lazy var monitor = LocalEventMonitor(
        mask: .keyDown,
        handler: { [weak self] event in
            guard let self, isRecording else { return event }
            guard !event.isARepeat else { return nil }
            handleKeyDown(event: event)
            return nil
        }
    )

    init(
        hotkey: Hotkey,
        onRecordingChanged: @escaping (Bool) -> Void
    ) {
        self.hotkey = hotkey
        self.onRecordingChanged = onRecordingChanged
    }

    func startRecording() {
        guard !isRecording else { return }
        onRecordingChanged(true)
        monitor.start()
        isRecording = true
    }

    func stopRecording() {
        guard isRecording else { return }
        monitor.stop()
        onRecordingChanged(false)
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
