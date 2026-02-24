import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

import Darwin

final class AirplayService
{
    let port: UInt16
    private(set) var minimumBufferSeconds: Double
    private(set) var segmentDurationSeconds: Double

    var onPlaylistReady: (() -> Void)?

    private var encoder: HLSEncoder?
    private let server = HLSServer()
    private var didSignalReady = false

    init(port: UInt16 = 8080, minimumBufferSeconds: Double = 5.0, segmentDurationSeconds: Double = 1.0)
    {
        self.port = port
        self.minimumBufferSeconds = minimumBufferSeconds
        self.segmentDurationSeconds = max(0.1, segmentDurationSeconds)
    }

    var playlistURLString: String { "http://127.0.0.1:\(port)/hls.m3u8" }
    var localIPAddress: String? { Self.preferredIPv4() }
    var airPlayPlaylistURLString: String
    {
        let host = localIPAddress ?? "127.0.0.1"
        return "http://\(host):\(port)/hls.m3u8"
    }

    func startServerIfNeeded()
    {
        server.start(port: port)
    }

    func startStream(outputSize: CGSize, fps: Double)
    {
        configureEncoder(outputSize: outputSize, fps: fps)
        startServerIfNeeded()
    }

    func resetStream()
    {
        encoder = nil
        server.resetStream()
        didSignalReady = false
    }

    private func configureEncoder(outputSize: CGSize, fps: Double)
    {
        server.segmentDurationSeconds = segmentDurationSeconds

        let encoder = HLSEncoder()
        self.encoder = encoder

        encoder.onSegmentData = { [weak self] data in
            guard let self else { return }
            self.server.addSegment(data: data)

            let segmentDuration = max(self.server.segmentDurationSeconds, 0.001)
            let requiredSegments = max(1, Int(ceil(self.minimumBufferSeconds / segmentDuration)))
            guard !self.didSignalReady, self.server.sequences.count >= requiredSegments else { return }
            self.didSignalReady = true
            self.onPlaylistReady?()
        }

        encoder.setup(outputSize: outputSize, fps: fps, segmentDurationSeconds: segmentDurationSeconds)
    }

    func addPixelBuffer(_ pixelBuffer: CVPixelBuffer)
    {
        encoder?.addPixelBuffer(pixelBuffer)
    }

    func setMinimumBufferSeconds(_ seconds: Double)
    {
        minimumBufferSeconds = max(0.25, seconds)
    }

    func setSegmentDurationSeconds(_ seconds: Double)
    {
        segmentDurationSeconds = max(0.1, seconds)
    }

    private static func preferredIPv4() -> String?
    {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let first = ifaddr
        else
        {
            return nil
        }
        defer { freeifaddrs(ifaddr) }

        // Prefer Wi-Fi (`en0`) on iPad/iPhone.
        let preferred = ["en0", "bridge0", "en1"]
        var fallback: String?

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next })
        {
            let interface = ptr.pointee
            let family = interface.ifa_addr.pointee.sa_family
            guard family == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            guard result == 0 else { continue }
            let ip = String(cString: host)
            if ip == "127.0.0.1" { continue }

            if preferred.contains(name)
            {
                address = ip
                break
            }

            fallback = fallback ?? ip
        }

        return address ?? fallback
    }
}
