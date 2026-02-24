import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
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

    let port: UInt16 = 8080

    private lazy var airplay = AirplayService(port: port)
    private let workQueue = DispatchQueue(label: "CounterBroadcastService.queue")
    private var timer: DispatchSourceTimer?
    private var pixelBuffer: CVPixelBuffer?
    private var ciContext = CIContext()
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let textGenerator = CIFilter.textImageGenerator()

    private let fps: Double = 15
    private var counter = 0
    private var hasStarted = false
    private var needsReconfigure = false

    var playlistURLString: String { "http://127.0.0.1:\(port)/hls.m3u8" }
    var canChangeOutputResolution: Bool { !isRunning }
    var outputSize: CGSize { outputResolution.size }
    var localIPAddress: String? { LocalNetworkAddress.preferredIPv4() }
    var airPlayPlaylistURLString: String
    {
        let host = localIPAddress ?? "127.0.0.1"
        return "http://\(host):\(port)/hls.m3u8"
    }

    init()
    {
        airplay.onPlaylistReady = { [weak self] in
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
            airplay.configureEncoder(outputSize: outputSize, fps: fps)
            airplay.startServerIfNeeded()
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
        let image = makeCounterImage(counter: counter, size: outputSize)
        ciContext.render(image, to: pixelBuffer, bounds: image.extent, colorSpace: colorSpace)
        airplay.addPixelBuffer(pixelBuffer)
        counter += 1

        let currentFrame = counter
        Task { @MainActor in
            self.frameCount = currentFrame
        }
    }

    private func resetPipelineStateForNewConfiguration()
    {
        airplay.resetStream()
        pixelBuffer = nil
        counter = 0
        isReady = false
        frameCount = 0
    }

    private func makeCounterImage(counter: Int, size: CGSize) -> CIImage
    {
        let bounds = CGRect(origin: .zero, size: size)

        let phase = Double(counter) * 0.04
        let r = CGFloat(0.08 + 0.06 * (sin(phase) * 0.5 + 0.5))
        let g = CGFloat(0.10 + 0.08 * (sin(phase + 2.1) * 0.5 + 0.5))
        let b = CGFloat(0.12 + 0.10 * (sin(phase + 4.2) * 0.5 + 0.5))
        let bg = CIImage(color: CIColor(red: r, green: g, blue: b, alpha: 1.0))
            .cropped(to: bounds)

        let grid = makeGrid(size: size)
        let timeText = makeText("COUNT \(counter)", fontSize: 42, x: 40, y: size.height - 120)
        let frameText = makeText("FRAME \(counter)  FPS \(Int(fps))", fontSize: 22, x: 42, y: 46)

        return [grid, timeText, frameText]
            .compactMap { $0 }
            .reduce(bg) { current, overlay in
                overlay.composited(over: current)
            }
    }

    private func makeGrid(size: CGSize) -> CIImage?
    {
        let width = Int(size.width)
        let height = Int(size.height)
        let spacing = 60
        let lineColor = CIColor(red: 1, green: 1, blue: 1, alpha: 0.08)
        let base = CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: size))
        let verticalLine = CIImage(color: lineColor).cropped(to: CGRect(x: 0, y: 0, width: 1, height: height))
        let horizontalLine = CIImage(color: lineColor).cropped(to: CGRect(x: 0, y: 0, width: width, height: 1))

        var image = base
        for x in stride(from: 0, through: width, by: spacing)
        {
            image = verticalLine.transformed(by: .init(translationX: CGFloat(x), y: 0)).composited(over: image)
        }
        for y in stride(from: 0, through: height, by: spacing)
        {
            image = horizontalLine.transformed(by: .init(translationX: 0, y: CGFloat(y))).composited(over: image)
        }
        return image
    }

    private func makeText(_ text: String, fontSize: Float, x: CGFloat, y: CGFloat) -> CIImage?
    {
        textGenerator.text = text
        textGenerator.fontName = "Helvetica-Bold"
        textGenerator.fontSize = fontSize
        textGenerator.scaleFactor = 2.0

        guard let alphaMask = textGenerator.outputImage
        else
        {
            return nil
        }

        let colorImage = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
            .cropped(to: alphaMask.extent)

        let mask = CIFilter.blendWithAlphaMask()
        mask.inputImage = colorImage
        mask.maskImage = alphaMask

        guard let coloredText = mask.outputImage
        else
        {
            return nil
        }

        return coloredText.transformed(by: .init(translationX: x, y: y))
    }
}
