import CoreVideo
import Foundation
import Metal

public final class MetalContext
{
    private static let device: MTLDevice = {
        guard let device = MTLCreateSystemDefaultDevice()
        else
        {
            fatalError("Metal is unavailable on this Mac.")
        }
        return device
    }()

    private static let commandQueue: MTLCommandQueue = {
        guard let queue = device.makeCommandQueue()
        else
        {
            fatalError("Failed to create Metal command queue.")
        }
        return queue
    }()

    private static let textureCache: CVMetalTextureCache = {
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache
        else
        {
            fatalError("Failed to create CVMetalTextureCache: \(status)")
        }
        return cache
    }()

    public static func createPixelBuffer(
        width: Int,
        height: Int,
        pixelFormat: OSType = kCVPixelFormatType_32BGRA
    ) -> CVPixelBuffer
    {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            max(1, width),
            max(1, height),
            pixelFormat,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let pixelBuffer
        else
        {
            fatalError("Failed to create pixel buffer: \(status)")
        }

        return pixelBuffer
    }

    public static func createRenderTargetTextureWithSize(_ size: CGSize) -> MTLTexture
    {
        createRenderTargetTexture(width: Int(size.width), height: Int(size.height))
    }

    public static func createRenderTargetTexture(
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat = .bgra8Unorm
    ) -> MTLTexture
    {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: max(1, width),
            height: max(1, height),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor)
        else
        {
            fatalError("Failed to create render target texture.")
        }
        return texture
    }

    public static func renderTextureToTexture(_ source: MTLTexture, _ destination: MTLTexture)
    {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder()
        else
        {
            return
        }

        let copyWidth = min(source.width, destination.width)
        let copyHeight = min(source.height, destination.height)
        guard copyWidth > 0, copyHeight > 0 else { return }

        blitEncoder.copy(
            from: source,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: copyWidth, height: copyHeight, depth: 1),
            to: destination,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()
        commandBuffer.commit()
    }

    // Simplified version for AirplayApp: direct GPU copy into a BGRA pixel buffer texture.
    public static func flattenTextureToPixelBuffer(_ sourceTexture: MTLTexture, _ pixelBuffer: CVPixelBuffer)
    {
        guard let destinationTexture = makeTexture(
            from: pixelBuffer,
            pixelFormat: .bgra8Unorm,
            width: sourceTexture.width,
            height: sourceTexture.height
        ),
        let commandBuffer = commandQueue.makeCommandBuffer(),
        let blitEncoder = commandBuffer.makeBlitCommandEncoder()
        else
        {
            return
        }

        let copyWidth = min(sourceTexture.width, destinationTexture.width)
        let copyHeight = min(sourceTexture.height, destinationTexture.height)
        guard copyWidth > 0, copyHeight > 0 else { return }

        blitEncoder.copy(
            from: sourceTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: copyWidth, height: copyHeight, depth: 1),
            to: destinationTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()
        commandBuffer.commit()
    }

    private static func makeTexture(
        from pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int
    ) -> MTLTexture?
    {
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            max(1, width),
            max(1, height),
            0,
            &cvTexture
        )

        guard status == kCVReturnSuccess, let cvTexture
        else
        {
            return nil
        }

        return CVMetalTextureGetTexture(cvTexture)
    }
}
