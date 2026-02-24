//
//  MetalPixelBufferPreviewView.swift
//  AirplayExample
//
//  Created by jason van cleave on 2/24/26.
//
import SwiftUI
import AVKit
import MetalKit

#if os(iOS)
struct MetalPixelBufferPreviewView: UIViewRepresentable
{
    let pixelBuffer: CVPixelBuffer

    func makeCoordinator() -> Coordinator
    {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView
    {
        let view = context.coordinator.makeView()
        context.coordinator.update(pixelBuffer: pixelBuffer)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context)
    {
        context.coordinator.update(pixelBuffer: pixelBuffer)
    }

    final class Coordinator: NSObject, MTKViewDelegate
    {
        private let lock = NSLock()
        private var pixelBuffer: CVPixelBuffer?
        private let device: MTLDevice?
        private let commandQueue: MTLCommandQueue?
        private var textureCache: CVMetalTextureCache?

        private weak var view: MTKView?

        override init()
        {
            let device = MTLCreateSystemDefaultDevice()
            self.device = device
            self.commandQueue = device?.makeCommandQueue()
            super.init()

            if let device
            {
                CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
            }
        }

        func makeView() -> MTKView
        {
            let view = MTKView(frame: .zero, device: device)
            self.view = view
            view.delegate = self
            view.enableSetNeedsDisplay = false
            view.isPaused = false
            view.preferredFramesPerSecond = 60
            view.framebufferOnly = false
            view.colorPixelFormat = .bgra8Unorm
            view.clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0)
            view.contentMode = .scaleAspectFit
            return view
        }

        func update(pixelBuffer: CVPixelBuffer)
        {
            lock.lock()
            self.pixelBuffer = pixelBuffer
            lock.unlock()

            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            view?.drawableSize = CGSize(width: width, height: height)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize)
        {
        }

        func draw(in view: MTKView)
        {
            guard let commandQueue, let commandBuffer = commandQueue.makeCommandBuffer() else { return }
            guard let drawable = view.currentDrawable else { return }

            lock.lock()
            let pixelBuffer = self.pixelBuffer
            lock.unlock()

            guard
                let pixelBuffer,
                let sourceTexture = makeTexture(from: pixelBuffer)
            else
            {
                commandBuffer.present(drawable)
                commandBuffer.commit()
                return
            }

            guard let blit = commandBuffer.makeBlitCommandEncoder() else
            {
                commandBuffer.present(drawable)
                commandBuffer.commit()
                return
            }

            let width = min(sourceTexture.width, drawable.texture.width)
            let height = min(sourceTexture.height, drawable.texture.height)
            if width > 0, height > 0
            {
                blit.copy(
                    from: sourceTexture,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: width, height: height, depth: 1),
                    to: drawable.texture,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
            }
            blit.endEncoding()

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        private func makeTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture?
        {
            guard let textureCache else { return nil }

            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            var cvTexture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                pixelBuffer,
                nil,
                .bgra8Unorm,
                width,
                height,
                0,
                &cvTexture
            )
            guard status == kCVReturnSuccess, let cvTexture else { return nil }
            return CVMetalTextureGetTexture(cvTexture)
        }
    }
}
#endif
