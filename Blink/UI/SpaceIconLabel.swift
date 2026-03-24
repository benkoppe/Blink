//
//  SpaceIconLabel.swift
//  Blink
//
//  Created by Ben on 3/24/26.
//

import SwiftUI

struct SpaceIconLabel: View {
    let info: SpaceInfo?

    var body: some View {
        if let info {
            Text("\(info.displayNumber)")
        } else {
            Image(systemName: "rectangle.3.group")
        }
    }
}
