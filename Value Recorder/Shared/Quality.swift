import AVFoundation
import Foundation

/// The four recording sizes. Everything is tuned to use as little disk
/// space as possible, not to look its best.
nonisolated enum VideoQuality: Int, CaseIterable, Identifiable, Codable, Sendable {
    case p120 = 120
    case p240 = 240
    case p480 = 480
    case p720 = 720

    var id: Int { rawValue }
    var lines: Int { rawValue }
    var label: String { "\(rawValue)p" }

    var note: String {
        switch self {
        case .p120: "Tiniest files. Shapes and big text only."
        case .p240: "Very small. Good for slides and big text."
        case .p480: "Small. Most text is readable."
        case .p720: "Clear. Still far smaller than a normal recording."
        }
    }

    /// Video bit rate in bits per second, for HEVC. H.264 uses 40% more.
    func videoBitRate(codec: VideoCodec) -> Int {
        let hevc: Int = switch self {
        case .p120: 90_000
        case .p240: 220_000
        case .p480: 550_000
        case .p720: 1_100_000
        }
        return codec == .hevc ? hevc : hevc * 14 / 10
    }

    /// Mono AAC audio bit rate.
    var audioBitRate: Int {
        switch self {
        case .p120, .p240: 48_000
        case .p480: 64_000
        case .p720: 96_000
        }
    }

    /// Rough disk use in megabytes per minute of recording.
    func megabytesPerMinute(codec: VideoCodec, withAudio: Bool = true) -> Double {
        let bits = Double(videoBitRate(codec: codec) + (withAudio ? audioBitRate : 0))
        return bits * 60 / 8 / 1_000_000
    }

    /// Output size for a source of `size`: the shorter side becomes `lines`
    /// (never larger than the source), both sides even.
    func outputSize(for size: CGSize) -> CGSize {
        let w = max(2, abs(size.width)), h = max(2, abs(size.height))
        let short = min(w, h)
        let scale = min(1, Double(lines) / short)
        func even(_ v: Double) -> CGFloat { CGFloat(max(2, Int((v * scale / 2).rounded()) * 2)) }
        return CGSize(width: even(w), height: even(h))
    }

    static var current: VideoQuality {
        VideoQuality(rawValue: Prefs.store.integer(forKey: Prefs.quality)) ?? .p240
    }
}

nonisolated enum VideoCodec: String, CaseIterable, Identifiable, Sendable {
    case hevc
    case h264

    var id: String { rawValue }
    var label: String { self == .hevc ? "Smallest (HEVC)" : "Plays anywhere (H.264)" }
    var avCodec: AVVideoCodecType { self == .hevc ? .hevc : .h264 }

    static var current: VideoCodec {
        VideoCodec(rawValue: Prefs.store.string(forKey: Prefs.codec) ?? "") ?? .hevc
    }
}

nonisolated enum FrameRate: Int, CaseIterable, Identifiable, Sendable {
    case fps5 = 5
    case fps10 = 10
    case fps15 = 15
    case fps30 = 30

    var id: Int { rawValue }
    var label: String { "\(rawValue) fps" }

    static var current: FrameRate {
        FrameRate(rawValue: Prefs.store.integer(forKey: Prefs.frameRate)) ?? .fps15
    }
}

/// Settings. On iPhone and iPad they live in the App Group so the screen
/// recording extension can read them; on the Mac, in normal preferences.
nonisolated enum Prefs {
    static let appGroup = "group.com.thomasdaly.ValueRecorder"
    /// Bundle id of the iOS Broadcast Upload Extension.
    static let broadcastExtension = "com.thomasdaly.ValueRecorder.Broadcast"

    nonisolated(unsafe) static let store: UserDefaults = {
        #if os(iOS)
        UserDefaults(suiteName: appGroup) ?? .standard
        #else
        .standard
        #endif
    }()

    static let quality = "quality"
    static let codec = "codec"
    static let frameRate = "frameRate"
    static let microphone = "microphone"
    static let systemAudio = "systemAudio"
    static let showsCursor = "showsCursor"
    static let autoMP3 = "autoMP3"
    static let autoText = "autoText"
    static let mp3Bitrate = "mp3Bitrate"
    static let timestamps = "timestamps"

    static func registerDefaults() {
        store.register(defaults: [
            quality: VideoQuality.p240.rawValue,
            codec: VideoCodec.hevc.rawValue,
            frameRate: FrameRate.fps15.rawValue,
            microphone: false,
            systemAudio: true,
            showsCursor: true,
            autoMP3: false,
            autoText: false,
            mp3Bitrate: 64,
            timestamps: false,
        ])
    }
}

nonisolated enum TimeText {
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

nonisolated enum SizeText {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func megabytes(_ value: Double) -> String {
        value < 1 ? String(format: "%.1f MB", value) : String(format: "%.0f MB", value.rounded())
    }
}

/// Where the iOS extension drops finished recordings for the app to pick up.
nonisolated enum BroadcastInbox {
    /// Present inside a recording folder while it is still being written.
    static let inProgressMarker = ".recording"

    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Prefs.appGroup)?
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    static func defaultTitle(for date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        return "Recording \(formatter.string(from: date))"
    }
}
