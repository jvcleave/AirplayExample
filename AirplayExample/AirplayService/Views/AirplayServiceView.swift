//
//  AirplayServiceView.swift
//  AirplayExample
//
//  Created by Codex on 2/24/26.
//

import SwiftUI
import AVKit
import AVFoundation
import Observation

@MainActor
@Observable
final class AirplayServiceViewModel
{
    let airplayService: AirplayService

    private(set) var player: AVPlayer?
    private(set) var isRunning = false
    private(set) var isReady = false
    private(set) var frameCount = 0
    private(set) var readyBufferSeconds: Double
    private(set) var automaticallyWaitsToMinimizeStalling: Bool
    private(set) var outputSize: CGSize
    private(set) var fps: Double

    init(
        port: UInt16 = 8080,
        readyBufferSeconds: Double = 5.0,
        segmentDurationSeconds: Double = 1.0,
        automaticallyWaitsToMinimizeStalling: Bool,
        outputSize: CGSize = CGSize(width: 1280, height: 720),
        fps: Double = 30
    )
    {
        self.airplayService = AirplayService(
            port: port,
            readyBufferSeconds: readyBufferSeconds,
            segmentDurationSeconds: segmentDurationSeconds
        )
        self.readyBufferSeconds = readyBufferSeconds
        self.automaticallyWaitsToMinimizeStalling = automaticallyWaitsToMinimizeStalling
        self.outputSize = outputSize
        self.fps = fps
    }

    func handlePlaylistReadyChanged(_ isReady: Bool)
    {
        guard isReady else { return }
        if player != nil { return }
        startAirPlayPlayback()
    }

    func setAutomaticallyWaitsToMinimizeStalling(_ isEnabled: Bool)
    {
        guard automaticallyWaitsToMinimizeStalling != isEnabled else { return }
        automaticallyWaitsToMinimizeStalling = isEnabled
        player?.automaticallyWaitsToMinimizeStalling = isEnabled
    }

    func setRunning(_ isRunning: Bool)
    {
        guard self.isRunning != isRunning else { return }
        self.isRunning = isRunning
    }

    func setReady(_ isReady: Bool)
    {
        guard self.isReady != isReady else { return }
        self.isReady = isReady
    }

    func setFrameCount(_ frameCount: Int)
    {
        guard self.frameCount != frameCount else { return }
        self.frameCount = frameCount
    }

    func setReadyBufferSeconds(_ seconds: Double)
    {
        guard readyBufferSeconds != seconds else { return }
        readyBufferSeconds = seconds
        airplayService.setReadyBufferSeconds(seconds)
    }

    func setSegmentDurationSeconds(_ seconds: Double)
    {
        airplayService.setSegmentDurationSeconds(seconds)
    }

    func setOutputSize(_ outputSize: CGSize)
    {
        guard self.outputSize != outputSize else { return }
        self.outputSize = outputSize
    }

    func setFPS(_ fps: Double)
    {
        guard self.fps != fps else { return }
        self.fps = fps
    }

    private func startAirPlayPlayback()
    {
#if os(iOS)
        do
        {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay])
            try AVAudioSession.sharedInstance().setActive(true)
        }
        catch
        {
            print("AVAudioSession setup failed: \(error)")
        }
#endif

        guard let url = URL(string: airplayService.airPlayPlaylistURLString)
        else
        {
            return
        }

        let player = AVPlayer()
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = automaticallyWaitsToMinimizeStalling
#if os(iOS) || os(tvOS)
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
#endif
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        self.player = player
        player.play()
    }
}

struct AirplayServiceView: View
{
    @Bindable var viewModel: AirplayServiceViewModel

    var body: some View
    {
        Group
        {
            if let player = viewModel.player
            {
                VideoPlayer(player: player)
            }
            else
            {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary)
                    .overlay(
                        Text("Local Preview")
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
