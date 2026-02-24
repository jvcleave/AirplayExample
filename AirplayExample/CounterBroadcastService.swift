import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation

final class CounterBroadcastService: ObservableObject
{
    @Published private(set) var isRunning = false
    @Published private(set) var isReady = false
    @Published private(set) var frameCount = 0

    let port: UInt16 = 8080

    private let encoder = HLSEncoder()
    private let server = HLSServer()
    private let workQueue = DispatchQueue(label: "CounterBroadcastService.queue")
    private var timer: DispatchSourceTimer?
    private var pixelBuffer: CVPixelBuffer?
    private var ciContext = CIContext()
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let textGenerator = CIFilter.textImageGenerator()

    private let outputSize = CGSize(width: 720, height: 720)
    private let fps: Double = 15
    private var counter = 0
    private var hasStarted = false

    var playlistURLString: String { "http://127.0.0.1:\(port)/hls.m3u8" }
    var localIPAddress: String? { LocalNetworkAddress.preferredIPv4() }
    var airPlayPlaylistURLString: String
    {
        let host = localIPAddress ?? "127.0.0.1"
        return "http://\(host):\(port)/hls.m3u8"
    }

    func start()
    {
        guard !isRunning else { return }

        if !hasStarted
        {
            pixelBuffer = MetalContext.createPixelBuffer(
                width: Int(outputSize.width),
                height: Int(outputSize.height)
            )
            configureEncoder()
            encoder.setup(outputSize: outputSize, fps: fps)
            server.start(port: port)
            startTimer()
            hasStarted = true
        }

        isRunning = true
    }

    func stop()
    {
        isRunning = false
    }

    private func configureEncoder()
    {
        encoder.onSegmentData = { [weak self] data in
            guard let self else { return }
            self.server.addSegment(data: data)
            if self.server.sequences.count >= 5
            {
                Task { @MainActor in
                    self.isReady = true
                }
            }
        }
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

        let image = makeCounterImage(counter: counter, size: outputSize)
        ciContext.render(image, to: pixelBuffer, bounds: image.extent, colorSpace: colorSpace)
        encoder.addPixelBuffer(pixelBuffer)
        counter += 1

        let currentFrame = counter
        Task { @MainActor in
            self.frameCount = currentFrame
        }
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
