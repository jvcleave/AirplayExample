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
    @StateObject private var broadcaster = CounterBroadcastService()
    @State private var player: AVPlayer?

    var body: some View
    {
        VStack(alignment: .leading, spacing: 14)
        {
            Group
            {
                if let player
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
                Button(broadcaster.isRunning ? "STOP" : "START")
                {
                    if broadcaster.isRunning
                    {
                        broadcaster.stop()
                    }
                    else
                    {
                        broadcaster.start()
                    }
                }

                Picker("Resolution", selection: resolutionBinding)
                {
                    ForEach(CounterBroadcastService.OutputResolution.allCases)
                    { resolution in
                        Text(resolution.rawValue).tag(resolution)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!broadcaster.canChangeOutputResolution)
            }

            #if os(iOS)
            if broadcaster.isReady
            {
                AirPlayRoutePicker()
                    .frame(width: 44, height: 44)
            }
            #endif

            Text("Frames sent: \(broadcaster.frameCount)").monospacedDigit()

            Text(broadcaster.isReady ? "Playlist ready (segments buffered)" : "Waiting for initial segments...")
                .foregroundStyle(broadcaster.isReady ? .green : .secondary)

        }
        .padding()
        .frame(minWidth: 520, minHeight: 280)
        .onChange(of: broadcaster.isReady)
        { _, isReady in
            guard isReady else { return }
            startAirPlayPlaybackIfNeeded()
        }
    }

    private var resolutionBinding: Binding<CounterBroadcastService.OutputResolution>
    {
        Binding(
            get: { broadcaster.outputResolution },
            set: { broadcaster.setOutputResolution($0) }
        )
    }

    private func startAirPlayPlaybackIfNeeded()
    {
        if player != nil { return }
        startAirPlayPlayback()
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
