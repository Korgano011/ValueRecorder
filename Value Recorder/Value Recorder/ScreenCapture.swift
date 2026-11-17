#if os(macOS)
import AppKit
import AVFoundation
import CoreMedia
import Observation
import ScreenCaptureKit

/// Captures the screen (and optionally what you hear and your microphone)
/// with ScreenCaptureKit and writes a small MP4. Runs on its own queue.
nonisolated final class ScreenVideoCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case nothingToRecord
        case noFrames
        case writer(String)

        var errorDescription: String? {
            switch self {
            case .nothingToRecord: "That screen or window isn’t available any more."
            case .noFrames: "Nothing was recorded. Check that Screen & System Audio Recording is turned on for Value Recorder."
            case .writer(let message): "Couldn’t save the recording: \(message)"
            }
        }
    }

    struct Options: Sendable {
        var quality: VideoQuality
        var codec: VideoCodec
        var frameRate: FrameRate
        var systemAudio: Bool
        var microphone: Bool
        var showsCursor: Bool
    }

    private let outputURL: URL
    private let options: Options
    private let queue = DispatchQueue(label: "ScreenVideoCapture")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var lastFrame: CMSampleBuffer?
    private var lastLevelReport: CFTimeInterval = 0
    private var paused = false
    private var pausedAt: CMTime?
    /// Total time spent paused; later buffers are shifted back by this much.
    private var timeOffset = CMTime.zero

    var onLevel: (@Sendable (Float) -> Void)?
    var onStopped: (@Sendable (Error) -> Void)?

    init(outputURL: URL, options: Options) {
        self.outputURL = outputURL
        self.options = options
    }

    /// `sourceSize` is the screen or window size in points; the recording
    /// keeps its shape and is scaled down to the chosen quality.
    func start(filter: SCContentFilter, sourceSize: CGSize) async throws {
        let size = options.quality.outputSize(for: sourceSize)

        let config = SCStreamConfiguration()
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.scalesToFit = true
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.frameRate.rawValue))
        config.queueDepth = 5
        config.showsCursor = options.showsCursor
        config.capturesAudio = options.systemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        if options.microphone {
            config.captureMicrophone = true
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: options.quality.videoBitRate(codec: options.codec),
            AVVideoExpectedSourceFrameRateKey: options.frameRate.rawValue,
            AVVideoMaxKeyFrameIntervalKey: options.frameRate.rawValue * 5,
            AVVideoAllowFrameReorderingKey: false,
        ]
        if options.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264MainAutoLevel
        }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: options.codec.avCodec,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compression,
        ])
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw CaptureError.writer("video format not supported") }
        writer.add(video)
        videoInput = video

        if options.systemAudio {
            audioInput = try Self.addAudioInput(to: writer, bitRate: options.quality.audioBitRate)
        }
        if options.microphone {
            micInput = try Self.addAudioInput(to: writer, bitRate: options.quality.audioBitRate)
        }
        self.writer = writer

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if options.systemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        if options.microphone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        self.stream = stream
        try await stream.startCapture()
    }

    private static func addAudioInput(to writer: AVAssetWriter, bitRate: Int) throws -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw CaptureError.writer("audio format not supported") }
        writer.add(input)
        return input
    }

    /// While paused, nothing is written (the file simply skips that time).
    func setPaused(_ value: Bool) {
        queue.async {
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            if value, !self.paused {
                self.pausedAt = now
            } else if !value, self.paused, let pausedAt = self.pausedAt {
                self.timeOffset = self.timeOffset + (now - pausedAt)
                self.pausedAt = nil
            }
            self.paused = value
        }
    }

    /// Shifts a buffer earlier by the time spent paused.
    private func shifted(_ buffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard timeOffset != .zero else { return buffer }
        guard let timings = try? buffer.sampleTimingInfos() else { return nil }
        let moved = timings.map { info in
            CMSampleTimingInfo(duration: info.duration,
                               presentationTimeStamp: info.presentationTimeStamp - timeOffset,
                               decodeTimeStamp: info.decodeTimeStamp.isValid ? info.decodeTimeStamp - timeOffset : .invalid)
        }
        return try? CMSampleBuffer(copying: buffer, withNewTiming: moved)
    }

    func stop() async throws {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { done.resume() }
        }
        guard let writer else { return }
        guard sessionStarted else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw CaptureError.noFrames
        }
        // The screen only sends frames when something changes; repeat the last
        // one at the stop time so the video lasts as long as the audio.
        if let lastFrame, let videoInput, videoInput.isReadyForMoreMediaData {
            let now = (pausedAt ?? CMClockGetTime(CMClockGetHostTimeClock())) - timeOffset
            if now > lastFrame.presentationTimeStamp,
               let copy = try? CMSampleBuffer(copying: lastFrame, withNewTiming: [
                CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: now, decodeTimeStamp: .invalid),
               ]) {
                videoInput.append(copy)
            }
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        micInput?.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw CaptureError.writer(writer.error?.localizedDescription ?? "unknown error")
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer original: CMSampleBuffer, of type: SCStreamOutputType) {
        guard original.isValid, let writer, !paused,
              let sampleBuffer = shifted(original) else { return }
        switch type {
        case .screen:
            guard Self.isCompleteFrame(sampleBuffer), let videoInput else { return }
            if !sessionStarted {
                guard writer.startWriting() else { return }
                writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
                sessionStarted = true
            }
            if videoInput.isReadyForMoreMediaData, videoInput.append(sampleBuffer) {
                lastFrame = sampleBuffer
            }
        case .audio:
            guard sessionStarted, let audioInput, audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(sampleBuffer)
            reportLevel(sampleBuffer)
        case .microphone:
            guard sessionStarted, let micInput, micInput.isReadyForMoreMediaData else { return }
            micInput.append(sampleBuffer)
            if audioInput == nil { reportLevel(sampleBuffer) }
        @unknown default:
            break
        }
    }

    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    private func reportLevel(_ sampleBuffer: CMSampleBuffer) {
        guard let onLevel else { return }
        let now = CACurrentMediaTime()
        guard now - lastLevelReport > 1.0 / 15 else { return }
        lastLevelReport = now
        var peak: Float = 0
        try? sampleBuffer.withAudioBufferList { list, _ in
            for buffer in list {
                guard let data = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.assumingMemoryBound(to: Float.self)
                for i in stride(from: 0, to: count, by: 4) { peak = max(peak, abs(samples[i])) }
            }
        }
        onLevel(min(1, peak))
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?(error)
    }
}

/// Something to record: a whole screen or one window.
struct CaptureSource: Identifiable, Hashable {
    enum Kind: Hashable { case display, window }
    let id: String
    let kind: Kind
    let name: String
    let size: CGSize

    static func == (a: CaptureSource, b: CaptureSource) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Drives the Record screen.
@Observable final class RecorderModel {
    enum Phase: Equatable { case idle, starting, recording, stopping }

    private(set) var phase: Phase = .idle
    private(set) var isPaused = false
    private(set) var level: Float = 0
    private(set) var displays: [CaptureSource] = []
    private(set) var windows: [CaptureSource] = []
    private(set) var needsPermission = false
    private(set) var elapsedBeforePause: TimeInterval = 0
    private(set) var resumedAt: Date?
    var selectedSourceID: String?
    var errorMessage: String?
    var title = ""

    private var capture: ScreenVideoCapture?
    private var videoURL: URL?

    var isRecording: Bool { phase == .recording || phase == .stopping }

    func elapsed(at date: Date) -> TimeInterval {
        elapsedBeforePause + (resumedAt.map { date.timeIntervalSince($0) } ?? 0)
    }

    var selectedSource: CaptureSource? {
        (displays + windows).first { $0.id == selectedSourceID } ?? displays.first
    }

    /// True once macOS allows this app to record the screen.
    static var hasScreenPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS for screen-recording permission. The first time this shows
    /// the system prompt and adds Value Recorder to System Settings › Privacy
    /// & Security › Screen & System Audio Recording.
    func requestPermission() {
        if !CGRequestScreenCaptureAccess() {
            needsPermission = true
            Self.openPrivacySettings()
        } else {
            needsPermission = false
        }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.userDeclined.rawValue { return true }
        return ns.localizedDescription.localizedCaseInsensitiveContains("TCC")
            || ns.localizedDescription.localizedCaseInsensitiveContains("declined")
    }

    static let permissionMessage = "Value Recorder isn’t allowed to record the screen yet. Turn it on in System Settings › Privacy & Security › Screen & System Audio Recording, then quit and reopen Value Recorder."

    func loadSources() async {
        guard Self.hasScreenPermission else {
            needsPermission = true
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let mine = Bundle.main.bundleIdentifier
            displays = content.displays.enumerated().map { index, display in
                CaptureSource(id: "display-\(display.displayID)", kind: .display,
                              name: content.displays.count == 1 ? "Entire screen" : "Screen \(index + 1)",
                              size: CGSize(width: display.width, height: display.height))
            }
            windows = content.windows
                .filter { $0.windowLayer == 0 && $0.frame.width > 120 && $0.frame.height > 80 }
                .filter { $0.owningApplication?.bundleIdentifier != mine }
                .compactMap { window in
                    guard let app = window.owningApplication?.applicationName, !app.isEmpty else { return nil }
                    let title = window.title.map { $0.isEmpty ? app : "\(app) — \($0)" } ?? app
                    return CaptureSource(id: "window-\(window.windowID)", kind: .window,
                                         name: title, size: window.frame.size)
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if selectedSourceID == nil || selectedSource?.id != selectedSourceID {
                selectedSourceID = displays.first?.id
            }
            needsPermission = false
        } catch {
            needsPermission = true
        }
    }

    func start(library: Library) async {
        guard phase == .idle else { return }
        guard Self.hasScreenPermission else {
            needsPermission = true
            errorMessage = Self.permissionMessage
            requestPermission()
            return
        }
        phase = .starting
        errorMessage = nil
        var createdURL: URL?
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            needsPermission = false
            let mine = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter: SCContentFilter
            let size: CGSize
            let id = selectedSource?.id ?? ""
            if id.hasPrefix("window-"),
               let window = content.windows.first(where: { "window-\($0.windowID)" == id }) {
                filter = SCContentFilter(desktopIndependentWindow: window)
                size = window.frame.size
            } else if let display = content.displays.first(where: { "display-\($0.displayID)" == id }) ?? content.displays.first {
                filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
                size = CGSize(width: display.width, height: display.height)
            } else {
                throw ScreenVideoCapture.CaptureError.nothingToRecord
            }

            let defaults = Prefs.store
            let options = ScreenVideoCapture.Options(
                quality: .current, codec: .current, frameRate: .current,
                systemAudio: defaults.bool(forKey: Prefs.systemAudio),
                microphone: defaults.bool(forKey: Prefs.microphone),
                showsCursor: defaults.bool(forKey: Prefs.showsCursor))

            let name = title.trimmingCharacters(in: .whitespaces).isEmpty ? Library.defaultTitle() : title
            let url = try library.newRecordingVideoURL(title: name)
            createdURL = url
            let capture = ScreenVideoCapture(outputURL: url, options: options)
            capture.onLevel = { [weak self] value in
                Task { @MainActor in self?.level = value }
            }
            capture.onStopped = { [weak self] error in
                Task { @MainActor in
                    guard let self, self.phase == .recording else { return }
                    self.errorMessage = "Recording stopped: \(error.localizedDescription)"
                    _ = await self.stop(library: library)
                }
            }
            try await capture.start(filter: filter, sourceSize: size)
            self.capture = capture
            videoURL = url
            elapsedBeforePause = 0
            resumedAt = .now
            isPaused = false
            phase = .recording
            library.refresh()
        } catch {
            phase = .idle
            if let folder = createdURL?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: folder) }
            if Self.isPermissionError(error) {
                needsPermission = true
                errorMessage = Self.permissionMessage
            } else {
                errorMessage = error.localizedDescription
            }
            library.refresh()
        }
    }

    func togglePause() {
        guard phase == .recording, let capture else { return }
        if isPaused {
            resumedAt = .now
        } else {
            elapsedBeforePause = elapsed(at: .now)
            resumedAt = nil
        }
        isPaused.toggle()
        capture.setPaused(isPaused)
    }

    /// Stops and returns the finished recording (nil if nothing was saved).
    func stop(library: Library) async -> Recording? {
        guard phase == .recording, let capture, let videoURL else { return nil }
        phase = .stopping
        defer {
            self.capture = nil
            self.videoURL = nil
            phase = .idle
            isPaused = false
            resumedAt = nil
            elapsedBeforePause = 0
            level = 0
            title = ""
        }
        do {
            try await capture.stop()
        } catch {
            errorMessage = error.localizedDescription
            try? FileManager.default.removeItem(at: videoURL.deletingLastPathComponent())
            library.refresh()
            return nil
        }
        library.refresh()
        let folderName = videoURL.deletingLastPathComponent().lastPathComponent
        return library.recordings.first { $0.folder.lastPathComponent == folderName }
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
#endif
