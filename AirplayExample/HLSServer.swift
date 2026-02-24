//
//  HLSServer.swift
//  Swifter
//
//  Created by jason van cleave on 2/24/26.
//


import Foundation

final class HLSServer
{
    private let airplayServer = HttpServer()

    public var sequences: [(sequence: Int, data: Data)] = []
    private var initData: Data?
    private var sequence: Int = -1

    public var segmentDurationSeconds: Double = 1.0
    private(set) var isRunning = false
    private var isConfigured = false

    private func configureRoutesIfNeeded()
    {
        guard !isConfigured else { return }
        isConfigured = true

        airplayServer["/hls.m3u8"] = { [weak self] _ in
            guard let self,
                  self.sequence >= 5,
                  let m3u8Data = self.m3u8.data(using: .utf8)
            else
            {
                return .notFound
            }
            return .ok(data: m3u8Data, contentType: "application/x-mpegURL")
        }

        airplayServer["/init.mp4"] = { [weak self] _ in
            guard let self, let initData = self.initData
            else
            {
                return .notFound
            }
            return .ok(data: initData, contentType: "video/mp4")
        }

        airplayServer["/files/:path"] = { [weak self] path in
            guard let self else { return .notFound }

            guard let data = self.sequences.first(where: {
                path.hasPrefix("/files/sequence\($0.sequence)")
            })?.data
            else
            {
                return .notFound
            }

            return .ok(data: data, contentType: "video/iso.segment")
        }
    }

    var m3u8: String
    {
        let durationStr = String(format: "%1.5f", segmentDurationSeconds)
        return """
        #EXTM3U
        #EXT-X-TARGETDURATION:\(Int(ceil(segmentDurationSeconds)))
        #EXT-X-VERSION:9
        #EXT-X-MEDIA-SEQUENCE:\(sequence - 2)
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:\(durationStr),
        files/sequence\(sequence - 2).m4s
        #EXTINF:\(durationStr),
        files/sequence\(sequence - 1).m4s
        #EXTINF:\(durationStr),
        files/sequence\(sequence).m4s
        """
    }

    public func addSegment(data: Data)
    {
        sequence += 1

        if sequence == 0
        {
            initData = data
            return
        }

        sequences.append((sequence: sequence, data: data))
        if sequences.count > 10
        {
            sequences.removeFirst()
        }
    }

    public func resetStream()
    {
        sequences.removeAll(keepingCapacity: true)
        initData = nil
        sequence = -1
    }

    public func start(port: UInt16 = 8080)
    {
        guard !isRunning else { return }
        configureRoutesIfNeeded()
        do
        {
            try airplayServer.start(port, priority: .default)
            isRunning = true
            print("✅ HLS Server started on port \(port)")
        }
        catch
        {
            print("❌ Failed to start HLS server: \(error)")
        }
    }
}
