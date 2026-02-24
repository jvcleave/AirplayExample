//
//  ContentView.swift
//  AirplayApp
//
//  Created by jason van cleave on 2/24/26.
//

import SwiftUI
import AVKit

import AVFoundation
import CoreGraphics
import Observation

@MainActor
@Observable
final class ContentViewModel
{
    enum FrameRate: String, CaseIterable, Identifiable
    {
        case fps30 = "30 fps"
        case fps60 = "60 fps"

        var id: String { rawValue }
        var value: Double
        {
            switch self
            {
            case .fps30:
                return 30
            case .fps60:
                return 60
            }
        }
    }

    enum OutputResolution: String, CaseIterable, Identifiable
    {
        case p720 = "720p"
        case p1080 = "1080p"

        var id: String { rawValue }

        var size: CGSize
        {
            switch self
            {
            case .p720:
                return CGSize(width: 1280, height: 720)
            case .p1080:
                return CGSize(width: 1920, height: 1080)
            }
        }
    }
    
    private(set) var isRunning = false
    private(set) var isReady = false
    private(set) var frameCount = 0
    private(set) var outputResolution: OutputResolution = .p720
    private(set) var frameRate: FrameRate = .fps30
    private(set) var readyBufferSeconds = 5.0
    private(set) var player: AVPlayer?
    private(set) var isShowingCompare = false
    private(set) var compareFrameImage: CGImage?
    
    var canChangeOutputResolution: Bool { !isRunning }
    
    @ObservationIgnored
    private let engine: CounterBroadcastEngine
    private let airPlayPlaylistURLString: String
    
    init()
    {
        let initialResolution = OutputResolution.p720
        let initialFrameRate = FrameRate.fps30
        let initialReadyBufferSeconds = 5.0
        let airplayService = AirplayService(readyBufferSeconds: initialReadyBufferSeconds)
        let engine = CounterBroadcastEngine(
            initialOutputSize: initialResolution.size,
            airplayService: airplayService,
            fps: initialFrameRate.value
        )
        self.engine = engine
        self.outputResolution = initialResolution
        self.frameRate = initialFrameRate
        self.readyBufferSeconds = initialReadyBufferSeconds
        self.airPlayPlaylistURLString = engine.airPlayPlaylistURLString
        engine.onRunningChanged = { [weak self] isRunning in
            Task { @MainActor [weak self] in
                self?.isRunning = isRunning
            }
        }

        engine.onReadyChanged = { [weak self] isReady in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isReady = isReady
                if isReady
                {
                    self.startAirPlayPlaybackIfNeeded()
                }
            }
        }

        engine.onFrameCountChanged = { [weak self] frameCount in
            Task { @MainActor [weak self] in
                self?.frameCount = frameCount
            }
        }

        engine.onCompareFrameChanged = { [weak self] image in
            DispatchQueue.main.async { [weak self] in
                self?.compareFrameImage = image
            }
        }
    }

    func toggleStreaming()
    {
        if isRunning
        {
            stop()
        }
        else
        {
            start()
        }
    }
    
    func setOutputResolution(_ resolution: OutputResolution)
    {
        guard !isRunning else { return }
        guard outputResolution != resolution else { return }

        outputResolution = resolution
        engine.setOutputSize(resolution.size)
    }

    func setFrameRate(_ frameRate: FrameRate)
    {
        guard !isRunning else { return }
        guard self.frameRate != frameRate else { return }

        self.frameRate = frameRate
        engine.setFPS(frameRate.value)
    }

    func setReadyBufferSeconds(_ seconds: Double)
    {
        guard !isRunning else { return }

        let clampedSeconds = max(1.0, min(10.0, seconds.rounded()))
        guard readyBufferSeconds != clampedSeconds else { return }

        readyBufferSeconds = clampedSeconds
        engine.setReadyBufferSeconds(clampedSeconds)
    }

    func setComparePresented(_ isPresented: Bool)
    {
        isShowingCompare = isPresented
        engine.setComparePreviewEnabled(isPresented)
    }
    
    private func start()
    {
        engine.start()
    }
    
    private func stop()
    {
        engine.stop()
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
        
        guard let url = URL(string: airPlayPlaylistURLString)
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


struct ContentView: View
{
    @State private var viewModel = ContentViewModel()

    var body: some View
    {
        VStack(alignment: .leading, spacing: 14)
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

            HStack(spacing: 10)
            {
                Circle()
                    .fill(viewModel.isRunning ? .green : .gray)
                    .frame(width: 10, height: 10)
                Text(viewModel.isRunning ? "Streaming" : "Stopped")
            }

            VStack(alignment: .leading, spacing: 10)
            {
                Picker("Resolution", selection: resolutionBinding)
                {
                    ForEach(ContentViewModel.OutputResolution.allCases)
                    { resolution in
                        Text(resolution.rawValue).tag(resolution)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!viewModel.canChangeOutputResolution)

                Picker("FPS", selection: frameRateBinding)
                {
                    ForEach(ContentViewModel.FrameRate.allCases)
                    { frameRate in
                        Text(frameRate.rawValue).tag(frameRate)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!viewModel.canChangeOutputResolution)

                VStack(alignment: .leading, spacing: 6)
                {
                    Text("Startup Buffer: \(Int(viewModel.readyBufferSeconds))s")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Slider(value: readyBufferSecondsBinding, in: 1...10, step: 1)
                        .disabled(!viewModel.canChangeOutputResolution)
                }

                HStack
                {
                    Spacer(minLength: 0)

                    Button(viewModel.isRunning ? "STOP" : "START")
                    {
                        viewModel.toggleStreaming()
                    }

                    Spacer(minLength: 0)
                }
            }

            

            Text("Frames sent: \(viewModel.frameCount)").monospacedDigit()

            Text(viewModel.isReady ? "Playlist ready (segments buffered)" : "Waiting for initial segments...")
                .foregroundStyle(viewModel.isReady ? .green : .secondary)
            
#if os(iOS)
            if viewModel.isReady
            {
                HStack
                {
                    Spacer(minLength: 0)
                    AirPlayRoutePicker().frame(width: 72, height: 72)
                    Button("COMPARE")
                    {
                        viewModel.setComparePresented(true)
                    }
                    .buttonStyle(.bordered)
                    Spacer(minLength: 0)
                }
            }
#endif

            Spacer(minLength: 0)

        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: comparePresentedBinding)
        {
            CompareFrameView(
                image: viewModel.compareFrameImage,
                frameCount: viewModel.frameCount
            )
        }
    }

    private var resolutionBinding: Binding<ContentViewModel.OutputResolution>
    {
        Binding(
            get: { viewModel.outputResolution },
            set: { viewModel.setOutputResolution($0) }
        )
    }

    private var frameRateBinding: Binding<ContentViewModel.FrameRate>
    {
        Binding(
            get: { viewModel.frameRate },
            set: { viewModel.setFrameRate($0) }
        )
    }

    private var readyBufferSecondsBinding: Binding<Double>
    {
        Binding(
            get: { viewModel.readyBufferSeconds },
            set: { viewModel.setReadyBufferSeconds($0) }
        )
    }

    private var comparePresentedBinding: Binding<Bool>
    {
        Binding(
            get: { viewModel.isShowingCompare },
            set: { viewModel.setComparePresented($0) }
        )
    }
}

private struct CompareFrameView: View
{
    let image: CGImage?
    let frameCount: Int

    var body: some View
    {
        VStack(alignment: .leading, spacing: 12)
        {
            Text("Source Pixel Buffer")
                .font(.headline)

            Group
            {
                if let image
                {
                    Image(decorative: image, scale: 1.0)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
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
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))

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
