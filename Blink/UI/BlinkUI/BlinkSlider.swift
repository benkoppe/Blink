//
//  BlinkSlider.swift
//  Blink
//
//  Created by Ben on 3/25/26.
//

import CompactSlider
import SwiftUI

struct BlinkSlider<
    Value: BinaryFloatingPoint, ValueLabel: View, ValueLabelSelectability: TextSelectability
>: View {
    private let value: Binding<Value>
    private let bounds: ClosedRange<Value>
    private let step: Value
    private let valueLabel: ValueLabel
    private let valueLabelSelectability: ValueLabelSelectability

    init(
        value: Binding<Value>,
        in bounds: ClosedRange<Value> = 0...1,
        step: Value = 0,
        valueLabelSelectability: ValueLabelSelectability = .disabled,
        @ViewBuilder valueLabel: () -> ValueLabel
    ) {
        self.value = value
        self.bounds = bounds
        self.step = step
        self.valueLabel = valueLabel()
        self.valueLabelSelectability = valueLabelSelectability
    }

    init(
        _ valueLabelKey: LocalizedStringKey,
        valueLabelSelectability: ValueLabelSelectability = .disabled,
        value: Binding<Value>,
        in bounds: ClosedRange<Value> = 0...1,
        step: Value = 0
    ) where ValueLabel == Text {
        self.init(
            value: value,
            in: bounds,
            step: step,
            valueLabelSelectability: valueLabelSelectability
        ) {
            Text(valueLabelKey)
        }
    }

    var tickCount: Int {
        Int(((bounds.upperBound - bounds.lowerBound) / step).rounded()) + 1
    }

    @State private var isHovered = false

    var body: some View {
        ZStack {
            GeometryReader { geo in
                CompactSlider(
                    value: value,
                    in: bounds,
                    step: step
                )
                .compactSliderOptions(.snapToSteps)
                .compactSliderScaleStyles(
                    visibility: .default, alignment: .top,
                    .linear(count: tickCount, lineLength: 3)
                )
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let width = geo.size.width
                    let percent = location.x / width

                    let range = bounds.upperBound - bounds.lowerBound
                    let rawValue = bounds.lowerBound + Value(percent) * range

                    if step > 0 {
                        let steps = ((rawValue - bounds.lowerBound) / step).rounded()
                        value.wrappedValue = bounds.lowerBound + steps * step
                    } else {
                        value.wrappedValue = rawValue
                    }
                }
            }

            valueLabel
                .foregroundStyle(isHovered ? .primary : .secondary)
                .textSelection(valueLabelSelectability)
                .allowsHitTesting(false)
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
