//
//  ContentView.swift
//  AirplayApp
//
//  Created by jason van cleave on 2/24/26.
//

import SwiftUI
import Observation
import CoreVideo

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

    private(set) var isShowingCompare = false
    private(set) var comparePixelBuffer: CVPixelBuffer?
    private(set) var frameCount = 0
    
    var isRunning: Bool { airplayServiceViewModel.isRunning }
    var isReady: Bool { airplayServiceViewModel.isReady }
    var minimumBufferSeconds: Double { airplayServiceViewModel.minimumBufferSeconds }
    var automaticallyWaitsToMinimizeStalling: Bool { airplayServiceViewModel.automaticallyWaitsToMinimizeStalling }
    var canChangeOutputResolution: Bool { !isRunning }
    var outputResolution: OutputResolution
    {
        switch airplayServiceViewModel.outputSize
        {
        case OutputResolution.p1080.size:
            return .p1080
        default:
            return .p720
        }
    }
    var frameRate: FrameRate
    {
        switch airplayServiceViewModel.fps
        {
        case 60:
            return .fps60
        default:
            return .fps30
        }
    }
    
    @ObservationIgnored
    private let engine: CounterBroadcastEngine
    let airplayServiceViewModel: AirplayServiceViewModel
    
    init()
    {
        let initialResolution = OutputResolution.p720
        let initialFrameRate = FrameRate.fps30
        let initialSegmentDurationSeconds = 0.25
        let initialMinimumBufferSeconds = 1.0
        let initialAutomaticallyWaitsToMinimizeStalling = false
        let airplayServiceViewModel = AirplayServiceViewModel(
            automaticallyWaitsToMinimizeStalling: initialAutomaticallyWaitsToMinimizeStalling,
            outputSize: initialResolution.size,
            fps: initialFrameRate.value
        )
        airplayServiceViewModel.setMinimumBufferSeconds(initialMinimumBufferSeconds)
        airplayServiceViewModel.setSegmentDurationSeconds(initialSegmentDurationSeconds)
        let airplayService = airplayServiceViewModel.airplayService
        let engine = CounterBroadcastEngine(
            initialOutputSize: initialResolution.size,
            fps: initialFrameRate.value
        )
        self.engine = engine
        self.airplayServiceViewModel = airplayServiceViewModel

        engine.onStreamResetRequested = { [weak airplayService] in
            airplayService?.resetStream()
        }

        engine.onStreamConfigureRequested = { [weak airplayService] outputSize, fps in
            airplayService?.startStream(outputSize: outputSize, fps: fps)
        }

        engine.onPixelBufferRendered = { [weak airplayService] pixelBuffer in
            airplayService?.addPixelBuffer(pixelBuffer)
        }

        airplayService.onPlaylistReady = { [weak engine] in
            engine?.handlePlaylistReady()
        }

        engine.onRunningChanged = { [weak self] isRunning in
            Task { @MainActor [weak self] in
                self?.airplayServiceViewModel.setRunning(isRunning)
            }
        }

        engine.onReadyChanged = { [weak self] isReady in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.airplayServiceViewModel.setReady(isReady)
                self.airplayServiceViewModel.handlePlaylistReadyChanged(isReady)
            }
        }

        engine.onFrameCountChanged = { [weak self] frameCount in
            Task { @MainActor [weak self] in
                self?.frameCount = frameCount
            }
        }

        engine.onComparePixelBufferChanged = { [weak self] pixelBuffer in
            Task { @MainActor [weak self] in
                self?.comparePixelBuffer = pixelBuffer
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
        guard airplayServiceViewModel.outputSize != resolution.size else { return }

        airplayServiceViewModel.setOutputSize(resolution.size)
        engine.setOutputSize(resolution.size)
    }

    func setFrameRate(_ frameRate: FrameRate)
    {
        guard !isRunning else { return }
        guard airplayServiceViewModel.fps != frameRate.value else { return }

        airplayServiceViewModel.setFPS(frameRate.value)
        engine.setFPS(frameRate.value)
    }

    func setMinimumBufferSeconds(_ seconds: Double)
    {
        guard !isRunning else { return }

        let steppedSeconds = (seconds / 0.25).rounded() * 0.25
        let clampedSeconds = max(0.25, min(10.0, steppedSeconds))
        guard airplayServiceViewModel.minimumBufferSeconds != clampedSeconds else { return }

        airplayServiceViewModel.setMinimumBufferSeconds(clampedSeconds)
        engine.setMinimumBufferSeconds(clampedSeconds)
    }

    func setAutomaticallyWaitsToMinimizeStalling(_ isEnabled: Bool)
    {
        guard airplayServiceViewModel.automaticallyWaitsToMinimizeStalling != isEnabled else { return }
        airplayServiceViewModel.setAutomaticallyWaitsToMinimizeStalling(isEnabled)
    }

    func resetCounterToZero()
    {
        engine.resetCounterToZero()
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
    
}


struct ContentView: View
{
    @State private var viewModel = ContentViewModel()
    @State private var showsOptions = false

    
    private var resolution: Binding<ContentViewModel.OutputResolution>
    {
        Binding(
            get: { viewModel.outputResolution },
            set: { viewModel.setOutputResolution($0) }
        )
    }
    
    private var frameRate: Binding<ContentViewModel.FrameRate>
    {
        Binding(
            get: { viewModel.frameRate },
            set: { viewModel.setFrameRate($0) }
        )
    }
    
    private var minimumBufferSeconds: Binding<Double>
    {
        Binding(
            get: { viewModel.minimumBufferSeconds },
            set: { viewModel.setMinimumBufferSeconds($0) }
        )
    }
    
    private var waitsToMinimizeStalling: Binding<Bool>
    {
        Binding(
            get: { viewModel.automaticallyWaitsToMinimizeStalling },
            set: { viewModel.setAutomaticallyWaitsToMinimizeStalling($0) }
        )
    }

    var body: some View
    {
        VStack(alignment: .leading, spacing: 14)
        {
            AirplayServiceView(
                viewModel: viewModel.airplayServiceViewModel
            )
            HStack(spacing: 10)
            {
               

               

                Button(viewModel.isRunning ? "STOP" : "START")
                {
                    viewModel.toggleStreaming()
                }
                .buttonStyle(.borderedProminent)

                AirPlayRoutePicker().frame(width: 72, height: 72)

                Button(viewModel.isShowingCompare ? "HIDE COMPARE" : "COMPARE")
                {
                    viewModel.setComparePresented(!viewModel.isShowingCompare)
                }
                .buttonStyle(.bordered)
                /*if viewModel.isReady
                {

                    
                }*/
                
                Button
                {
                    showsOptions.toggle()

                } label: {
                    Label(showsOptions ? "Hide Options" : "Options", systemImage: "slider.horizontal.3")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                
            }
            .frame(maxWidth: .infinity, alignment: .center)
            if showsOptions
            {
                StreamOptionsView(
                    canChangeOutputResolution: viewModel.canChangeOutputResolution,
                    minimumBufferSecondsValue: viewModel.minimumBufferSeconds,
                    resolution: resolution,
                    frameRate: frameRate,
                    minimumBufferSeconds: minimumBufferSeconds,
                    waitsToMinimizeStalling: waitsToMinimizeStalling
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Divider()
            VStack
            {
                Text(viewModel.isRunning ? "Server Status: Streaming" : "Server Status: Stopped")
                HStack(spacing: 6)
                {
                    Text("Frames sent: \(viewModel.frameCount)").monospacedDigit()
                    
                    Text(viewModel.isReady ? "Playlist ready (segments buffered)" : "Waiting for initial segments...")
                        .foregroundStyle(viewModel.isReady ? .green : .secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
           

            if viewModel.isReady
            {
                if viewModel.isShowingCompare
                {
                    AirplayCompareSheetView(
                        pixelBuffer: viewModel.comparePixelBuffer,
                        frameCount: viewModel.frameCount,
                        onResetCounter: { viewModel.resetCounterToZero() }
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    
}

private struct StreamOptionsView: View
{
    let canChangeOutputResolution: Bool
    let minimumBufferSecondsValue: Double

    @Binding var resolution: ContentViewModel.OutputResolution
    @Binding var frameRate: ContentViewModel.FrameRate
    @Binding var minimumBufferSeconds: Double
    @Binding var waitsToMinimizeStalling: Bool

    var body: some View
    {
        VStack(alignment: .leading, spacing: 10)
        {
            Picker("Resolution", selection: $resolution)
            {
                ForEach(ContentViewModel.OutputResolution.allCases)
                { resolution in
                    Text(resolution.rawValue).tag(resolution)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!canChangeOutputResolution)

            Picker("FPS", selection: $frameRate)
            {
                ForEach(ContentViewModel.FrameRate.allCases)
                { frameRate in
                    Text(frameRate.rawValue).tag(frameRate)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!canChangeOutputResolution)

            VStack(alignment: .leading, spacing: 6)
            {
                Text("Startup Buffer: \(minimumBufferSecondsValue.formatted(.number.precision(.fractionLength(0...2))))s")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Slider(value: $minimumBufferSeconds, in: 0.25...10, step: 0.25)
                    .disabled(!canChangeOutputResolution)
            }

            Toggle("AVPlayer waits to minimize stalling", isOn: $waitsToMinimizeStalling)
        }
    }
}
