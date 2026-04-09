//
//  ResetButton.swift
//  Blink
//
//  Created by Ben on 4/8/26.
//

import SwiftUI

struct ResetButton<Value: Equatable>: View {
    @Binding var binding: Value
    let defaultValue: Value

    init(
        binding: Binding<Value>,
        default defaultValue: Value
    ) {
        self._binding = binding
        self.defaultValue = defaultValue
    }

    var body: some View {
        Button {
            binding = defaultValue
        } label: {
            Image(systemName: "arrow.counterclockwise.circle.fill")
        }
        .buttonStyle(.borderless)
        .help("Reset to default")
        .disabled(binding == defaultValue)

    }
}
