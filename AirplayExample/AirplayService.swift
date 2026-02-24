import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

final class AirplayService
{
    let port: UInt16

    var onPlaylistReady: (() -> Void)?

    private var encoder: HLSEncoder?
    private let server = HLSServer()
    private var didSignalReady = false

    init(port: UInt16 = 8080)
    {
        self.port = port
    }

    func startServerIfNeeded()
    {
        server.start(port: port)
    }

    func resetStream()
    {
        encoder = nil
        server.resetStream()
        didSignalReady = false
    }

    func configureEncoder(outputSize: CGSize, fps: Double)
    {
        let encoder = HLSEncoder()
        self.encoder = encoder

        encoder.onSegmentData = { [weak self] data in
            guard let self else { return }
            self.server.addSegment(data: data)

            guard !self.didSignalReady, self.server.sequences.count >= 5 else { return }
            self.didSignalReady = true
            self.onPlaylistReady?()
        }

        encoder.setup(outputSize: outputSize, fps: fps)
    }

    func addPixelBuffer(_ pixelBuffer: CVPixelBuffer)
    {
        encoder?.addPixelBuffer(pixelBuffer)
    }
}
