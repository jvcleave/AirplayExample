//
//  HLSWebService.swift
//  Swifter
//
//  Created by jason van cleave on 2/24/26.
//


import CoreVideo
import Metal

final class HLSWebService
{
    private var outputBuffer: CVPixelBuffer?
    private let hlsEncoder = HLSEncoder()
    var hlsServer = HLSServer()
    private var internalTexture: MTLTexture?
    private var framePumpTimer: DispatchSourceTimer?
    private var targetFPS: Double = 30
    private let frameQueue = DispatchQueue(label: "HLSWebService.framePump")

    var onEncoderReady: (() -> Void)?

    private(set) var hasStarted = false
    var isRunning = false

    func setupAndStart(outputSize: CGSize, fps: Double)
    {
        guard !hasStarted
        else
        {
            print("⚠️ HLSWebService already started.")
            return
        }

        targetFPS = fps
        internalTexture = MetalContext.createRenderTargetTextureWithSize(outputSize)
        outputBuffer = MetalContext.createPixelBuffer(
            width: Int(outputSize.width),
            height: Int(outputSize.height)
        )

        hlsEncoder.onSegmentData = { [weak self] segmentData in
            guard let self else { return }
            hlsServer.addSegment(data: segmentData)

            print("📦 HLS Server segment count: \(hlsServer.sequences.count)")

            if hlsServer.sequences.count >= 5
            {
                self.onEncoderReady?()
            }
        }

        hlsEncoder.setup(outputSize: outputSize, fps: fps)

        hlsServer.start() // Will only start once internally
        startFramePump()

        hasStarted = true
        isRunning = true
        print("✅ HLSWebService started")
    }

    func handle(previewTexture: MTLTexture)
    {
        guard isRunning else { return }

        if internalTexture == nil
        {
            internalTexture = MetalContext.createRenderTargetTextureWithSize(
                CGSize(width: previewTexture.width, height: previewTexture.height)
            )
        }

        guard let internalTexture else { return }
        MetalContext.renderTextureToTexture(previewTexture, internalTexture)
    }

    private func startFramePump()
    {
        guard framePumpTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: frameQueue)
        let interval = UInt64((1.0 / max(1.0, targetFPS)) * 1000000000.0)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(interval)))
        timer.setEventHandler
        { [weak self] in
            self?.appendLatestFrame()
        }
        framePumpTimer = timer
        timer.resume()
    }

    private func appendLatestFrame()
    {
        guard isRunning,
              let internalTexture,
              let outputBuffer
        else { return }

        MetalContext.flattenTextureToPixelBuffer(internalTexture, outputBuffer)
        hlsEncoder.addPixelBuffer(outputBuffer)
    }
}
