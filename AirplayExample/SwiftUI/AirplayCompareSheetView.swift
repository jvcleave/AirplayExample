//
//  AirplayCompareSheetView.swift
//  AirplayExample
//
//  Created by Codex on 2/24/26.
//

import SwiftUI
import CoreVideo

struct AirplayCompareSheetView: View
{
    let pixelBuffer: CVPixelBuffer?
    let frameCount: Int
    let onResetCounter: () -> Void

    var body: some View
    {
        CompareFrameView(
            pixelBuffer: pixelBuffer,
            frameCount: frameCount,
            onResetCounter: onResetCounter
        )
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
