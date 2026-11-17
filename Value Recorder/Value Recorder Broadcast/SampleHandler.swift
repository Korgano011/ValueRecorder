import AVFoundation
import ImageIO
import ReplayKit
import VideoToolbox

/// The iPhone/iPad screen recorder. iOS starts this extension when you pick
/// Value Recorder in the screen-recording sheet; it shrinks every frame to
/// the chosen size (120p–720p), drops frames above the chosen frame rate and
/// writes a small MP4 into the shared App Group "Inbox". The app moves it
/// into Recordings the next time it opens.
///
/// Extensions get very little memory (about 50 MB), so frames are scaled
/// into a small reusable pool and never kept around.
final class SampleHandler: RPBroadcastSampleHandler {
    private let lock = NSRecursiveLock()
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var appAudioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var transfer: VTPixelTransferSession?
    private var sessionStarted = false
    private var lastVideoTime = CMTime.invalid
    private var latestTime = CMTime.invalid
    private var lastPixelBuffer: CVPixelBuffer?
    private var folder: URL?
    private var outputURL: URL?
    private var setupFailed = false

    private var quality = VideoQuality.p240
    private var codec = VideoCodec.hevc
    private var frameRate = FrameRate.fps15
    private var paused = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        Prefs.registerDefaults()
        quality = .current
        codec = .current
        frameRate = .current

        guard let inbox = BroadcastInbox.folder else {
            fail("Value Recorder couldn’t open its shared folder.")
            return
        }
        let title = BroadcastInbox.defaultTitle()
        let folder = inbox.appendingPathComponent(title, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: folder.appendingPathComponent(BroadcastInbox.inProgressMarker).path,
                                           contents: nil)
        } catch {
            fail("Couldn’t start: \(error.localizedDescription)")
            return
        }
        self.folder = folder
        outputURL = folder.appendingPathComponent(title).appendingPathExtension("mp4")
    }

    override func broadcastPaused() {
        lock.withLock { paused = true }
    }

    override func broadcastResumed() {
        lock.withLock { paused = false }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        lock.lock()
        defer { lock.unlock() }
        guard !paused, !setupFailed, sampleBuffer.isValid else { return }
        switch sampleBufferType {
        case .video:
            handleVideo(sampleBuffer)
        case .audioApp:
            append(sampleBuffer, to: appAudioInput)
        case .audioMic:
            append(sampleBuffer, to: micInput)
        @unknown default:
            break
        }
    }

    override func broadcastFinished() {
        lock.lock()
        defer { lock.unlock() }
        guard let writer, sessionStarted else {
            writer?.cancelWriting()
            if let folder { try? FileManager.default.removeItem(at: folder) }
            return
        }
        // iOS only sends frames when the screen changes; repeat the last one
        // at the end so the video lasts as long as the sound.
        if let lastPixelBuffer, let adaptor, let videoInput, videoInput.isReadyForMoreMediaData,
           latestTime.isValid, lastVideoTime.isValid, latestTime > lastVideoTime {
            adaptor.append(lastPixelBuffer, withPresentationTime: latestTime)
        }
        videoInput?.markAsFinished()
        appAudioInput?.markAsFinished()
        micInput?.markAsFinished()

        // This method must not return until the file is finished.
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        _ = done.wait(timeout: .now() + 20)
        if let folder {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(BroadcastInbox.inProgressMarker))
        }
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
    }

    // MARK: Video

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = sampleBuffer.presentationTimeStamp
        note(time)

        // Keep only as many frames per second as chosen.
        if lastVideoTime.isValid,
           (time - lastVideoTime).seconds < 1.0 / Double(frameRate.rawValue) * 0.9 { return }

        if writer == nil {
            let orientation = Self.orientation(of: sampleBuffer)
            let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
            do {
                try setUpWriter(sourceSize: size, orientation: orientation)
            } catch {
                fail("Couldn’t start recording: \(error.localizedDescription)")
                return
            }
        }
        guard let writer, let videoInput, let adaptor, let transfer else { return }
        if !sessionStarted {
            guard writer.startWriting() else {
                fail("Couldn’t save the recording: \(writer.error?.localizedDescription ?? "unknown error")")
                return
            }
            writer.startSession(atSourceTime: time)
            sessionStarted = true
        }
        guard videoInput.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        var scaled: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &scaled)
        guard let scaled,
              VTPixelTransferSessionTransferImage(transfer, from: pixelBuffer, to: scaled) == noErr else { return }
        if adaptor.append(scaled, withPresentationTime: time) {
            lastVideoTime = time
            lastPixelBuffer = scaled
        }
    }

    private func setUpWriter(sourceSize: CGSize, orientation: CGImagePropertyOrientation) throws {
        guard let outputURL else { throw NSError(domain: "ValueRecorder", code: 1) }
        let size = quality.outputSize(for: sourceSize)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: quality.videoBitRate(codec: codec),
            AVVideoExpectedSourceFrameRateKey: frameRate.rawValue,
            AVVideoMaxKeyFrameIntervalKey: frameRate.rawValue * 5,
            AVVideoAllowFrameReorderingKey: false,
        ]
        if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264MainAutoLevel }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compression,
        ])
        video.expectsMediaDataInRealTime = true
        video.transform = Self.transform(for: orientation)
        guard writer.canAdd(video) else { throw NSError(domain: "ValueRecorder", code: 2) }
        writer.add(video)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])

        // Separate tracks for the phone's sound and the microphone; an unused
        // one simply stays empty. Players and the converters mix them.
        appAudioInput = Self.audioInput(for: writer, bitRate: quality.audioBitRate)
        micInput = Self.audioInput(for: writer, bitRate: quality.audioBitRate)

        var session: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
        if let session {
            VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
        }
        self.writer = writer
        self.videoInput = video
        self.adaptor = adaptor
        self.transfer = session
    }

    private static func audioInput(for writer: AVAssetWriter, bitRate: Int) -> AVAssetWriterInput? {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        return input
    }

    // MARK: Audio

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        note(sampleBuffer.presentationTimeStamp)
        guard sessionStarted, let input, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    // MARK: Helpers

    private func note(_ time: CMTime) {
        guard time.isValid else { return }
        if !latestTime.isValid || time > latestTime { latestTime = time }
    }

    private func fail(_ message: String) {
        setupFailed = true
        writer?.cancelWriting()
        if let folder { try? FileManager.default.removeItem(at: folder) }
        finishBroadcastWithError(NSError(domain: "ValueRecorder", code: 0,
                                         userInfo: [NSLocalizedDescriptionKey: message]))
    }

    private static func orientation(of sampleBuffer: CMSampleBuffer) -> CGImagePropertyOrientation {
        guard let value = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                          attachmentModeOut: nil) as? NSNumber,
              let orientation = CGImagePropertyOrientation(rawValue: value.uint32Value) else { return .up }
        return orientation
    }

    /// Turns the (always portrait) screen frames the right way up when the
    /// recording starts with the phone sideways.
    private static func transform(for orientation: CGImagePropertyOrientation) -> CGAffineTransform {
        switch orientation {
        case .left, .leftMirrored: CGAffineTransform(rotationAngle: .pi / 2)
        case .right, .rightMirrored: CGAffineTransform(rotationAngle: -.pi / 2)
        case .down, .downMirrored: CGAffineTransform(rotationAngle: .pi)
        default: .identity
        }
    }
}
