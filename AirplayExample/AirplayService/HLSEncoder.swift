import AVFoundation
import CoreVideo

class HLSEncoder: NSObject, AVAssetWriterDelegate
{
    private var assetWriter: AVAssetWriter!
    private var writerInput: AVAssetWriterInput!
    private var isStarted = false
    var onSegmentData: ((Data) -> Void)?

    func setup(outputSize: CGSize, fps: Double)
    {
        print("📦 [HLSEncoder] Setting up with size: \(outputSize), fps: \(fps)")

        do
        {
            assetWriter = AVAssetWriter(contentType: .mpeg4Movie)
            assetWriter.shouldOptimizeForNetworkUse = true
            assetWriter.outputFileTypeProfile = .mpeg4AppleHLS
            assetWriter.preferredOutputSegmentInterval = CMTime(seconds: 1, preferredTimescale: 1)
            assetWriter.delegate = self

            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(outputSize.width),
                AVVideoHeightKey: Int(outputSize.height),
            ]

            writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            writerInput.expectsMediaDataInRealTime = true

            if assetWriter.canAdd(writerInput)
            {
                assetWriter.add(writerInput)
            }
            else
            {
                throw NSError(domain: "HLSEncoder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot add writer input"])
            }

            assetWriter.initialSegmentStartTime = .zero
            assetWriter.startWriting()
            assetWriter.startSession(atSourceTime: .zero)

            isStarted = true
            print("✅ [HLSEncoder] HLS writer started successfully")
        }
        catch
        {
            print("❌ [HLSEncoder] Failed to start HLS writer: \(error)")
        }
    }

    func addPixelBuffer(_ pixelBuffer: CVPixelBuffer)
    {
        guard isStarted
        else
        {
            print("⚠️ [HLSEncoder] Tried to add pixel buffer before start")
            return
        }

        var sampleBufferOut: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var formatDesc: CMVideoFormatDescription?

        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )

        if status == kCMBlockBufferNoErr, let formatDesc = formatDesc
        {
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescription: formatDesc,
                sampleTiming: &timingInfo,
                sampleBufferOut: &sampleBufferOut
            )

            if let sampleBuffer = sampleBufferOut
            {
                writerInput.append(sampleBuffer)
            }
            else
            {
                print("⚠️ [HLSEncoder] Failed to create CMSampleBuffer")
            }
        }
        else
        {
            print("❌ [HLSEncoder] Failed to create CMVideoFormatDescription")
        }
    }

    // MARK: - AVAssetWriterDelegate

    func assetWriter(_ writer: AVAssetWriter,
                     didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType,
                     segmentReport: AVAssetSegmentReport?)
    {
        print("🧩 HLS segment output – \(segmentData.count) bytes")

        onSegmentData?(segmentData)
    }
}
