import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation

final class CounterFrameRenderer
{
    private let ciContext = CIContext()
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let textGenerator = CIFilter.textImageGenerator()

    func render(counter: Int, fps: Double, size: CGSize, into pixelBuffer: CVPixelBuffer)
    {
        let image = makeCounterImage(counter: counter, fps: fps, size: size)
        ciContext.render(image, to: pixelBuffer, bounds: image.extent, colorSpace: colorSpace)
    }

    private func makeCounterImage(counter: Int, fps: Double, size: CGSize) -> CIImage
    {
        let bounds = CGRect(origin: .zero, size: size)

        let phase = Double(counter) * 0.04
        let r = CGFloat(0.08 + 0.06 * (sin(phase) * 0.5 + 0.5))
        let g = CGFloat(0.10 + 0.08 * (sin(phase + 2.1) * 0.5 + 0.5))
        let b = CGFloat(0.12 + 0.10 * (sin(phase + 4.2) * 0.5 + 0.5))
        let bg = CIImage(color: CIColor(red: r, green: g, blue: b, alpha: 1.0))
            .cropped(to: bounds)

        let grid = makeGrid(size: size)
        let fpsInt = max(1, Int(fps.rounded()))
        let timecode = makeTimecodeString(frame: counter, fps: fpsInt)
        let timecodeText = makeText(timecode, fontSize: 52, x: 40, y: size.height - 130)
        let infoText = makeText("FRAME \(counter)  FPS \(fpsInt)", fontSize: 22, x: 42, y: 46)

        return [grid, timecodeText, infoText]
            .compactMap { $0 }
            .reduce(bg) { current, overlay in
                overlay.composited(over: current)
            }
    }

    private func makeTimecodeString(frame: Int, fps: Int) -> String
    {
        let totalFrames = max(0, frame)
        let framesPerSecond = max(1, fps)
        let totalSeconds = totalFrames / framesPerSecond

        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        let frames = totalFrames % framesPerSecond

        return String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, frames)
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
