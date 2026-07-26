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
    typealias BeginRecording = @MainActor (
        @escaping (HotkeyKeyEvent) -> Void
    ) -> Bool
    typealias LoadReservedCombinations = @MainActor () -> Set<KeyCombination>

    private(set) var isRecording = false
    var isPresentingReservedByMacOSError = false

    let hotkey: Hotkey

    @ObservationIgnored private let beginRecording: BeginRecording
    @ObservationIgnored private let endRecording: () -> Void
    @ObservationIgnored private let assignCombination: (KeyCombination) -> Void
    @ObservationIgnored private let loadReservedCombinations: LoadReservedCombinations
    @ObservationIgnored private var reservedCombinations: Set<KeyCombination> = []

    init(
        hotkey: Hotkey,
        beginRecording: @escaping BeginRecording,
        endRecording: @escaping () -> Void,
        assignCombination: @escaping (KeyCombination) -> Void,
        loadReservedCombinations: @escaping LoadReservedCombinations
    ) {
        self.hotkey = hotkey
        self.beginRecording = beginRecording
        self.endRecording = endRecording
        self.assignCombination = assignCombination
        self.loadReservedCombinations = loadReservedCombinations
    }

    deinit {
        MainActor.assumeIsolated {
            guard isRecording else { return }
            endRecording()
        }
    }

    func startRecording() {
        guard !isRecording else { return }
        // Carbon preference lookup happens on the button action, never in the
        // suppressing HID callback.
        reservedCombinations = loadReservedCombinations()
        guard beginRecording({ [weak self] event in
            self?.handleKeyEvent(event)
        }) else {
            NSSound.beep()
            return
        }
        isRecording = true
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        endRecording()
    }

    func handleKeyEvent(_ event: HotkeyKeyEvent) {
        guard isRecording else { return }
        let keyCombination = event.keyCombination

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

        guard !reservedCombinations.contains(keyCombination) else {
            isPresentingReservedByMacOSError = true
            return
        }

        assignCombination(keyCombination)
        stopRecording()
    }
}
