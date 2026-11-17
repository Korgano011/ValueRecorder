import AVFoundation
import Foundation
import Observation

/// One recording: a folder holding the MP4 and, when made, its MP3 and
/// text, all named after the folder.
struct Recording: Identifiable, Hashable {
    let folder: URL
    let videoURL: URL
    let created: Date

    var id: URL { folder }
    var title: String { folder.lastPathComponent }
    var mp3URL: URL { file("mp3") }
    var transcriptURL: URL { file("txt") }
    var hasMP3: Bool { FileManager.default.fileExists(atPath: mp3URL.path) }
    var hasTranscript: Bool { FileManager.default.fileExists(atPath: transcriptURL.path) }

    func file(_ ext: String) -> URL {
        folder.appendingPathComponent(title).appendingPathExtension(ext)
    }

    /// Every file in the folder, with its size.
    var files: [(url: URL, size: Int64)] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        return items.map { ($0, Library.size(of: $0)) }
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }

    var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
}

/// A folder (picked by the user or the default) remembered with a
/// security-scoped bookmark so the sandboxed app can keep using it.
@Observable final class ChosenFolder {
    private(set) var url: URL
    private(set) var isCustom = false
    private let bookmarkKey: String
    private let defaultURL: URL
    private var scopedURL: URL?

    #if os(macOS)
    private static let createOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let resolveOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let createOptions: URL.BookmarkCreationOptions = []
    private static let resolveOptions: URL.BookmarkResolutionOptions = []
    #endif

    init(bookmarkKey: String, defaultURL: URL) {
        self.bookmarkKey = bookmarkKey
        self.defaultURL = defaultURL
        url = defaultURL
        if let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            var stale = false
            if let saved = try? URL(resolvingBookmarkData: data, options: Self.resolveOptions,
                                    relativeTo: nil, bookmarkDataIsStale: &stale),
               saved.startAccessingSecurityScopedResource() {
                scopedURL = saved
                url = saved
                isCustom = true
                if stale, let fresh = try? saved.bookmarkData(options: Self.createOptions) {
                    UserDefaults.standard.set(fresh, forKey: bookmarkKey)
                }
            }
        }
        ensure()
    }

    /// Starts using a folder the person picked (from a folder picker).
    func use(_ picked: URL) throws {
        let access = picked.startAccessingSecurityScopedResource()
        do {
            let data = try picked.bookmarkData(options: Self.createOptions)
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        } catch {
            if access { picked.stopAccessingSecurityScopedResource() }
            throw error
        }
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = access ? picked : nil
        url = picked
        isCustom = true
    }

    func useDefault() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        url = defaultURL
        isCustom = false
        ensure()
    }

    func ensure() {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

/// Where recordings are saved (~/Movies/Value Recorder by default).
@Observable final class Library {
    static let convertedFolderName = "Converted"
    static let textFolderName = "Text"

    let folder: ChosenFolder
    private(set) var recordings: [Recording] = []
    private(set) var converted: [URL] = []
    private(set) var texts: [URL] = []
    var lastError: String?
    /// Called for each recording the iOS extension just finished.
    @ObservationIgnored var onNewBroadcast: ((Recording) -> Void)?
    @ObservationIgnored private var newlyCollected: [String] = []

    var folderURL: URL { folder.url }

    /// Mac: ~/Movies. iPhone/iPad: the app's Documents (shown in the Files app).
    static var baseFolder: URL {
        #if os(macOS)
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        #else
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
    }

    init() {
        folder = ChosenFolder(bookmarkKey: "libraryFolderBookmark",
                              defaultURL: Self.baseFolder.appendingPathComponent(
                                Platform.isMac ? "Value Recorder" : "Recordings", isDirectory: true))
        refresh()
    }

    func useFolder(_ url: URL) {
        do {
            try folder.use(url)
            refresh()
        } catch {
            lastError = "Couldn’t use that folder: \(error.localizedDescription)"
        }
    }

    /// iPhone/iPad: moves recordings the screen-recording extension has
    /// finished from the shared inbox into Recordings.
    private func collectFinishedBroadcasts() {
        #if os(iOS)
        guard let inbox = BroadcastInbox.folder else { return }
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil,
                                                 options: [.skipsHiddenFiles])) ?? []
        for item in items where Self.isFolder(item) {
            guard !fm.fileExists(atPath: item.appendingPathComponent(BroadcastInbox.inProgressMarker).path) else { continue }
            let video = item.appendingPathComponent(item.lastPathComponent).appendingPathExtension("mp4")
            guard fm.fileExists(atPath: video.path) else {
                try? fm.removeItem(at: item)
                continue
            }
            let target = Self.uniqueURL(in: folderURL, name: item.lastPathComponent, ext: nil)
            do {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                try fm.moveItem(at: video, to: target.appendingPathComponent(target.lastPathComponent).appendingPathExtension("mp4"))
                try? fm.removeItem(at: item)
                newlyCollected.append(target.lastPathComponent)
            } catch {
                lastError = "Couldn’t bring in a new recording: \(error.localizedDescription)"
            }
        }
        #endif
    }

    /// iPhone/iPad: true while the extension is still writing a recording.
    var broadcastInProgress: Bool {
        #if os(iOS)
        guard let inbox = BroadcastInbox.folder else { return false }
        let items = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
        return items.contains {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(BroadcastInbox.inProgressMarker).path)
        }
        #else
        return false
        #endif
    }

    func useDefaultFolder() {
        folder.useDefault()
        refresh()
    }

    var convertedFolder: URL { folderURL.appendingPathComponent(Self.convertedFolderName, isDirectory: true) }
    var textFolder: URL { folderURL.appendingPathComponent(Self.textFolderName, isDirectory: true) }

    // MARK: Contents

    func refresh() {
        folder.ensure()
        collectFinishedBroadcasts()
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        var found: [Recording] = []
        for item in items {
            guard Self.isFolder(item),
                  item.lastPathComponent != Self.convertedFolderName,
                  item.lastPathComponent != Self.textFolderName else { continue }
            let video = item.appendingPathComponent(item.lastPathComponent).appendingPathExtension("mp4")
            guard fm.fileExists(atPath: video.path) else { continue }
            found.append(Recording(folder: item, videoURL: video, created: Self.created(video)))
        }
        recordings = found.sorted { $0.created > $1.created }
        converted = Self.files(in: convertedFolder, extensions: ["mp4", "mp3"])
        texts = Self.files(in: textFolder, extensions: ["txt"])
        if !newlyCollected.isEmpty {
            let names = newlyCollected
            newlyCollected = []
            for recording in recordings where names.contains(recording.title) { onNewBroadcast?(recording) }
        }
    }

    var totalSize: Int64 {
        recordings.reduce(0) { $0 + $1.totalSize } + (converted + texts).reduce(0) { $0 + Self.size(of: $1) }
    }

    /// Makes a new, uniquely named recording folder and returns where the MP4 goes.
    func newRecordingVideoURL(title: String) throws -> URL {
        folder.ensure()
        let newFolder = Self.uniqueURL(in: folderURL, name: Self.sanitized(title), ext: nil)
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        return newFolder.appendingPathComponent(newFolder.lastPathComponent).appendingPathExtension("mp4")
    }

    func newConvertedURL(for source: URL, ext: String, suffix: String = "") -> URL {
        try? FileManager.default.createDirectory(at: convertedFolder, withIntermediateDirectories: true)
        let name = Self.sanitized(source.deletingPathExtension().lastPathComponent) + suffix
        return Self.uniqueURL(in: convertedFolder, name: name, ext: ext)
    }

    func newTextURL(for source: URL) -> URL {
        try? FileManager.default.createDirectory(at: textFolder, withIntermediateDirectories: true)
        return Self.uniqueURL(in: textFolder, name: Self.sanitized(source.deletingPathExtension().lastPathComponent), ext: "txt")
    }

    func trash(_ recording: Recording) {
        trashFile(recording.folder, name: recording.title)
    }

    func trashFile(_ url: URL, name: String? = nil) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            lastError = "Couldn’t move “\(name ?? url.lastPathComponent)” to the Trash: \(error.localizedDescription)"
        }
        refresh()
    }

    /// Renames the recording's folder and every file inside that carries its name.
    func rename(_ recording: Recording, to newTitle: String) -> Recording? {
        let clean = Self.sanitized(newTitle)
        guard !clean.isEmpty, clean != recording.title else { return nil }
        let fm = FileManager.default
        let newFolder = Self.uniqueURL(in: folderURL, name: clean, ext: nil)
        let newName = newFolder.lastPathComponent
        do {
            for item in recording.files where item.url.deletingPathExtension().lastPathComponent == recording.title {
                let target = recording.folder.appendingPathComponent(newName).appendingPathExtension(item.url.pathExtension)
                try fm.moveItem(at: item.url, to: target)
            }
            try fm.moveItem(at: recording.folder, to: newFolder)
        } catch {
            lastError = "Couldn’t rename: \(error.localizedDescription)"
        }
        refresh()
        return recordings.first { $0.folder.lastPathComponent == newName }
    }

    func showInFinder(_ url: URL? = nil) {
        Platform.reveal(url ?? folderURL)
    }

    // MARK: Helpers

    nonisolated static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    nonisolated static func created(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
    }

    nonisolated static func size(of url: URL) -> Int64 {
        if isFolder(url) {
            let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
            var total: Int64 = 0
            while let item = items?.nextObject() as? URL {
                total += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
            return total
        }
        return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    nonisolated static func files(in folder: URL, extensions: Set<String>) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { created($0) > created($1) }
    }

    nonisolated static func duration(of url: URL) async -> TimeInterval {
        let seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        return seconds.isFinite ? seconds : 0
    }

    nonisolated static func sanitized(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func uniqueURL(in folder: URL, name: String, ext: String?) -> URL {
        let base = name.isEmpty ? "Recording" : name
        func make(_ n: String) -> URL {
            let url = folder.appendingPathComponent(n)
            return ext.map { url.appendingPathExtension($0) } ?? url
        }
        var candidate = make(base)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = make("\(base) (\(number))")
            number += 1
        }
        return candidate
    }

    /// The real path with the home folder shown as "~".
    nonisolated static func displayPath(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().path
        guard let home = getpwuid(getuid())?.pointee.pw_dir.map({ String(cString: $0) }),
              path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    static func defaultTitle(for date: Date = .now) -> String {
        BroadcastInbox.defaultTitle(for: date)
    }
}
