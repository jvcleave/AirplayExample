//
//  ContentView.swift
//  AirplayApp
//
//  Created by jason van cleave on 2/24/26.
//

import SwiftUI
import AVKit
import AVFoundation

struct ContentView: View
{
    @StateObject private var broadcaster = CounterBroadcastService(doWebserver: false)
    @State private var player: AVPlayer?

    var body: some View
    {
        VStack(alignment: .leading, spacing: 14)
        {
            Text("AirplayApp HLS Counter")
                .font(.title2.bold())

            HStack(spacing: 10)
            {
                Circle()
                    .fill(broadcaster.isRunning ? .green : .gray)
                    .frame(width: 10, height: 10)
                Text(broadcaster.isRunning ? "Streaming" : "Stopped")
            }

            HStack(spacing: 10)
            {
                Button("Start Counter Stream")
                {
                    broadcaster.start()
                }
                .disabled(broadcaster.isRunning)

                Button("Pause")
                {
                    broadcaster.stop()
                }
                .disabled(!broadcaster.isRunning)
            }

            HStack(spacing: 12)
            {
                Button("Play HLS (AirPlay-capable)")
                {
                    startAirPlayPlayback()
                }
                .disabled(!broadcaster.isReady)

                #if os(iOS)
                AirPlayRoutePicker()
                    .frame(width: 44, height: 44)
                #endif
            }

            Text("Frames sent: \(broadcaster.frameCount)")
                .monospacedDigit()

            Text(broadcaster.isReady ? "Playlist ready (segments buffered)" : "Waiting for initial segments...")
                .foregroundStyle(broadcaster.isReady ? .green : .secondary)

            Divider()

            if let browserTestURLString = broadcaster.browserTestURLString
            {
                Text("Open in browser (same device):")
                    .font(.headline)
                Link(browserTestURLString, destination: URL(string: browserTestURLString)!)
            }
            Link(broadcaster.playlistURLString, destination: URL(string: broadcaster.playlistURLString)!)
            Link(broadcaster.airPlayPlaylistURLString, destination: URL(string: broadcaster.airPlayPlaylistURLString)!)

            Text("Use the LAN URL for AirPlay devices (it uses this iPad's local network IP).")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let player
            {
                VideoPlayer(player: player)
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 280)
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

        guard let url = URL(string: broadcaster.airPlayPlaylistURLString)
        else
        {
            return
        }

        let player = AVPlayer()
        player.allowsExternalPlayback = true
        #if os(iOS) || os(tvOS)
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        #endif
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        self.player = player
        player.play()
    }
}
