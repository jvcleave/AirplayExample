//
//  AirplayCompareSheetView.swift
//  AirplayExample
//
//  Created by Codex on 2/24/26.
//

import SwiftUI
import CoreVideo

struct AirplayCompareSheetView<Content: View>: View
{
    @Binding var isPresented: Bool
    let pixelBuffer: CVPixelBuffer?
    let frameCount: Int
    let onResetCounter: () -> Void
    let content: Content

    init(
        isPresented: Binding<Bool>,
        pixelBuffer: CVPixelBuffer?,
        frameCount: Int,
        onResetCounter: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    )
    {
        self._isPresented = isPresented
        self.pixelBuffer = pixelBuffer
        self.frameCount = frameCount
        self.onResetCounter = onResetCounter
        self.content = content()
    }

    var body: some View
    {
        content
            .sheet(isPresented: $isPresented)
            {
                CompareFrameView(
                    pixelBuffer: pixelBuffer,
                    frameCount: frameCount,
                    onResetCounter: onResetCounter
                )
            }
    }
}
