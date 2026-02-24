import Combine
import CoreVideo
import Foundation

final class CounterBroadcastService: ObservableObject
{
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

    @Published private(set) var isRunning = false
    @Published private(set) var isReady = false
    @Published private(set) var frameCount = 0
    @Published private(set) var outputResolution: OutputResolution = .p720

    private lazy var airplayService = AirplayService()
    private let frameRenderer = CounterFrameRenderer()
    private let workQueue = DispatchQueue(label: "CounterBroadcastService.queue")
    private var timer: DispatchSourceTimer?
    private var pixelBuffer: CVPixelBuffer?

    private let fps: Double = 15
    private var counter = 0
    private var hasStarted = false
    private var needsReconfigure = false

    var canChangeOutputResolution: Bool { !isRunning }
    var outputSize: CGSize { outputResolution.size }
    var airPlayPlaylistURLString: String { airplayService.airPlayPlaylistURLString }

    init()
    {
        airplayService.onPlaylistReady = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.isReady = true
            }
        }
    }

    func setOutputResolution(_ resolution: OutputResolution)
    {
        guard !isRunning else { return }
        guard outputResolution != resolution else { return }
        outputResolution = resolution
        needsReconfigure = hasStarted
        if hasStarted
        {
            isReady = false
            frameCount = 0
        }
    }

    func start()
    {
        guard !isRunning else { return }

        if !hasStarted || needsReconfigure
        {
            resetPipelineStateForNewConfiguration()
            let outputSize = self.outputSize
            pixelBuffer = MetalContext.createPixelBuffer(
                width: Int(outputSize.width),
                height: Int(outputSize.height)
            )
            airplayService.configureEncoder(outputSize: outputSize, fps: fps)
            airplayService.startServerIfNeeded()
            startTimer()
            hasStarted = true
            needsReconfigure = false
        }

        isRunning = true
    }

    func stop()
    {
        isRunning = false
    }

    private func startTimer()
    {
        guard timer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        let intervalNanos = Int((1.0 / fps) * 1_000_000_000.0)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(max(1, intervalNanos)))
        timer.setEventHandler { [weak self] in
            self?.emitFrame()
        }
        self.timer = timer
        timer.resume()
    }

    private func emitFrame()
    {
        guard isRunning, let pixelBuffer else { return }

        let outputSize = self.outputSize
        frameRenderer.render(counter: counter, fps: fps, size: outputSize, into: pixelBuffer)
        airplayService.addPixelBuffer(pixelBuffer)
        counter += 1

        let currentFrame = counter
        Task { @MainActor in
            self.frameCount = currentFrame
        }
    }

    private func resetPipelineStateForNewConfiguration()
    {
        airplayService.resetStream()
        pixelBuffer = nil
        counter = 0
        isReady = false
        frameCount = 0
    }
}
