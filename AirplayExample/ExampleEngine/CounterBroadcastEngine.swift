import CoreGraphics
import CoreVideo
import Foundation

final class CounterBroadcastEngine
{
    let airPlayPlaylistURLString: String
    var onRunningChanged: ((Bool) -> Void)?
    var onReadyChanged: ((Bool) -> Void)?
    var onFrameCountChanged: ((Int) -> Void)?
    var onCompareFrameChanged: ((CGImage?) -> Void)?

    private let airplayService: AirplayService
    private let frameRenderer = CounterFrameRenderer()
    private var fps: Double
    private let queue = DispatchQueue(label: "CounterBroadcastEngine.queue", qos: .userInitiated)

    private var outputSize: CGSize
    private var frameTimer: DispatchSourceTimer?
    private var pixelBuffer: CVPixelBuffer?
    private var counter = 0
    private var isRunning = false
    private var isReady = false
    private var hasStarted = false
    private var needsReconfigure = false
    private var isComparePreviewEnabled = false

    init(initialOutputSize: CGSize, airplayService: AirplayService, fps: Double = 15)
    {
        self.airplayService = airplayService
        self.airPlayPlaylistURLString = airplayService.airPlayPlaylistURLString
        self.fps = fps
        self.outputSize = initialOutputSize

        airplayService.onPlaylistReady = { [weak self] in
            self?.queue.async { [weak self] in
                guard let self else { return }
                guard !self.isReady else { return }
                self.isReady = true
                self.onReadyChanged?(true)
            }
        }
    }

    deinit
    {
        frameTimer?.setEventHandler {}
        frameTimer?.cancel()
    }

    func start()
    {
        queue.async { [weak self] in
            guard let self else { return }

            if !self.hasStarted || self.needsReconfigure
            {
                self.resetPipelineStateForNewConfiguration()
                self.pixelBuffer = Self.createPixelBuffer(
                    width: Int(self.outputSize.width),
                    height: Int(self.outputSize.height)
                )
                self.airplayService.configureEncoder(outputSize: self.outputSize, fps: self.fps)
                self.airplayService.startServerIfNeeded()
                self.hasStarted = true
                self.needsReconfigure = false
            }

            guard !self.isRunning else { return }
            self.isRunning = true
            self.onRunningChanged?(true)
            self.startFrameLoopIfNeeded()
        }
    }

    func stop()
    {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.isRunning else { return }
            self.isRunning = false
            self.onRunningChanged?(false)
        }
    }

    func setOutputSize(_ newSize: CGSize)
    {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isRunning else { return }
            guard self.outputSize != newSize else { return }

            self.outputSize = newSize
            self.needsReconfigure = self.hasStarted

            if self.hasStarted
            {
                if self.isReady
                {
                    self.isReady = false
                    self.onReadyChanged?(false)
                }
                self.onFrameCountChanged?(0)
            }
        }
    }

    func setFPS(_ newFPS: Double)
    {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isRunning else { return }
            guard self.fps != newFPS else { return }

            self.fps = newFPS
            self.needsReconfigure = self.hasStarted

            // Rebuild the timer schedule on next start if an old timer is hanging around.
            self.frameTimer?.setEventHandler {}
            self.frameTimer?.cancel()
            self.frameTimer = nil

            if self.hasStarted
            {
                if self.isReady
                {
                    self.isReady = false
                    self.onReadyChanged?(false)
                }
                self.onFrameCountChanged?(0)
            }
        }
    }

    func setReadyBufferSeconds(_ seconds: Double)
    {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isRunning else { return }

            let clampedSeconds = max(0.1, seconds)
            guard self.airplayService.readyBufferSeconds != clampedSeconds else { return }

            self.airplayService.setReadyBufferSeconds(clampedSeconds)

            // Treat as a stream config change so the next start rebuilds readiness state.
            self.needsReconfigure = self.hasStarted

            if self.hasStarted
            {
                if self.isReady
                {
                    self.isReady = false
                    self.onReadyChanged?(false)
                }
                self.onFrameCountChanged?(0)
            }
        }
    }

    func setComparePreviewEnabled(_ isEnabled: Bool)
    {
        queue.async { [weak self] in
            guard let self else { return }
            self.isComparePreviewEnabled = isEnabled
            if !isEnabled
            {
                self.onCompareFrameChanged?(nil)
            }
        }
    }

    private func startFrameLoopIfNeeded()
    {
        guard frameTimer == nil else { return }

        let interval = max(1.0 / fps, 0.001)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.isRunning, let pixelBuffer = self.pixelBuffer else { return }

            self.frameRenderer.render(counter: self.counter, fps: self.fps, size: self.outputSize, into: pixelBuffer)
            self.airplayService.addPixelBuffer(pixelBuffer)
            self.counter += 1
            self.onFrameCountChanged?(self.counter)

            if self.isComparePreviewEnabled, self.counter.isMultiple(of: 3)
            {
                self.onCompareFrameChanged?(self.frameRenderer.makePreviewImage(from: pixelBuffer))
            }
        }
        frameTimer = timer
        timer.resume()
    }

    private func resetPipelineStateForNewConfiguration()
    {
        airplayService.resetStream()
        pixelBuffer = nil
        counter = 0
        if isReady
        {
            isReady = false
            onReadyChanged?(false)
        }
        onCompareFrameChanged?(nil)
        onFrameCountChanged?(0)
    }

    private static func createPixelBuffer(
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
}
