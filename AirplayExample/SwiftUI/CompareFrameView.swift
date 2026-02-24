//
//  CompareFrameView.swift
//  AirplayExample
//
//  Created by jason van cleave on 2/24/26.
//

import SwiftUI

struct CompareFrameView: View
{
    let pixelBuffer: CVPixelBuffer?
    let frameCount: Int
    let onResetCounter: () -> Void

    var body: some View
    {
        VStack(alignment: .leading, spacing: 12)
        {
            Text("Source Pixel Buffer")
                .font(.headline)

            Group
            {
#if os(iOS)
                if let pixelBuffer
                {
                    MetalPixelBufferPreviewView(pixelBuffer: pixelBuffer)
                }
                else
                {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.quaternary)
                        .overlay(
                            Text("Waiting for source frames...")
                                .foregroundStyle(.secondary)
                        )
                }
#else
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary)
                    .overlay(
                        Text("COMPARE preview is iOS-only")
                            .foregroundStyle(.secondary)
                    )
#endif
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack
            {
                Spacer(minLength: 0)
                Button("RESET COUNTER")
                {
                    onResetCounter()
                }
                .buttonStyle(.borderedProminent)
                Spacer(minLength: 0)
            }

            Text("Source frame count: \(frameCount)")
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Text("Compare this number against the AirPlay display to estimate lag.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding()
        .frame(minWidth: 320, minHeight: 260)
    }
}
