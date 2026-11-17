import Foundation
import Observation

/// Background work: making MP3s, smaller MP4s and text. Progress is keyed by
/// the recording folder (or the source file, for the converter screens).
@Observable final class Jobs {
    enum Kind: Hashable { case mp3, mp4, text }

    private(set) var progress: [URL: [Kind: Double]] = [:]
    /// Bumped when a transcript is rewritten, so open views reload it.
    private(set) var transcriptRevision: [URL: Int] = [:]
    var errors: [URL: String] = [:]

    func fraction(_ kind: Kind, for key: URL) -> Double? { progress[key]?[kind] }
    func isBusy(_ key: URL) -> Bool { !(progress[key]?.isEmpty ?? true) }

    private func begin(_ kind: Kind, _ key: URL) -> Bool {
        guard progress[key]?[kind] == nil else { return false }
        progress[key, default: [:]][kind] = 0
        errors[key] = nil
        return true
    }

    private func update(_ kind: Kind, _ key: URL, _ value: Double) {
        if progress[key]?[kind] != nil { progress[key]?[kind] = value }
    }

    private func end(_ kind: Kind, _ key: URL) {
        progress[key]?[kind] = nil
        if progress[key]?.isEmpty == true { progress[key] = nil }
    }

    // MARK: Recordings

    func makeMP3(_ recording: Recording, library: Library) {
        mp3(source: recording.videoURL, destination: recording.mp3URL, title: recording.title,
            key: recording.folder, library: library)
    }

    func transcribe(_ recording: Recording, library: Library) {
        text(source: recording.videoURL, destination: recording.transcriptURL, key: recording.folder, library: library)
    }

    /// Makes a smaller copy inside the recording's folder, e.g. "Talk 120p.mp4".
    func makeSmallerMP4(_ recording: Recording, quality: VideoQuality, library: Library) {
        let destination = recording.folder.appendingPathComponent("\(recording.title) \(quality.label)")
            .appendingPathExtension("mp4")
        mp4(source: recording.videoURL, destination: destination, quality: quality,
            key: recording.folder, library: library)
    }

    // MARK: Any file

    func mp3(source: URL, destination: URL, title: String?, key: URL, library: Library, done: (@MainActor (URL) -> Void)? = nil) {
        guard begin(.mp3, key) else { return }
        let bitrate = Prefs.store.integer(forKey: Prefs.mp3Bitrate)
        Task {
            do {
                try await Task.detached {
                    try await MP3Encoder.convert(source: source, to: destination, bitrate: bitrate, title: title) { value in
                        Task { @MainActor in self.update(.mp3, key, value) }
                    }
                }.value
                done?(destination)
            } catch {
                errors[key] = error.localizedDescription
            }
            end(.mp3, key)
            library.refresh()
        }
    }

    func mp4(source: URL, destination: URL, quality: VideoQuality, key: URL, library: Library,
             done: (@MainActor (URL) -> Void)? = nil) {
        guard begin(.mp4, key) else { return }
        let codec = VideoCodec.current
        Task {
            do {
                try await Task.detached {
                    try await MP4Converter.convert(source: source, to: destination, quality: quality, codec: codec) { value in
                        Task { @MainActor in self.update(.mp4, key, value) }
                    }
                }.value
                done?(destination)
            } catch {
                errors[key] = error.localizedDescription
            }
            end(.mp4, key)
            library.refresh()
        }
    }

    func text(source: URL, destination: URL?, key: URL, library: Library, done: (@MainActor (String) -> Void)? = nil) {
        guard begin(.text, key) else { return }
        let timestamps = Prefs.store.bool(forKey: Prefs.timestamps)
        Task {
            do {
                let text = try await Task.detached {
                    try await Transcriber.transcribe(url: source, timestamps: timestamps) { value in
                        Task { @MainActor in self.update(.text, key, value) }
                    }
                }.value
                let saved = text.isEmpty ? "(No speech was heard.)" : text
                if let destination {
                    try saved.write(to: destination, atomically: true, encoding: .utf8)
                    transcriptRevision[key, default: 0] += 1
                }
                done?(saved)
            } catch {
                errors[key] = error.localizedDescription
            }
            end(.text, key)
            library.refresh()
        }
    }
}
