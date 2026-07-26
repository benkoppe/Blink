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

    deinit {
        MainActor.assumeIsolated {
            guard isRecording else { return }
            monitor.stop()
            onRecordingChanged(false)
        }
    }

    func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        onRecordingChanged(true)
        monitor.start()
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        monitor.stop()
        onRecordingChanged(false)
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

        hotkey.keyCombination = keyCombination
        stopRecording()
    }
}
