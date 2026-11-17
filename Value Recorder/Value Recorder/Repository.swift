import Foundation
import Observation

/// A recording kept in the repository for later.
struct RepositoryItem: Identifiable, Hashable {
    let folder: URL
    let savedOn: Date
    let size: Int64
    let note: String
    /// The text made from the audio, if there is one (used for searching).
    let transcript: String

    var id: URL { folder }
    var title: String { folder.lastPathComponent }
    var files: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.lastPathComponent != Repository.noteFileName }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    var video: URL? { files.first { $0.pathExtension.lowercased() == "mp4" } }
}

/// The repository: a long-term folder (an external drive, iCloud Drive, or
/// the default ~/Movies/Value Recorder Repository on the Mac, or
/// Value Recorder › Repository in the Files app) where finished recordings
/// are kept for future use, with a note and searchable text.
@Observable final class Repository {
    static let noteFileName = "Note.txt"

    let folder: ChosenFolder
    private(set) var items: [RepositoryItem] = []
    var lastError: String?

    var folderURL: URL { folder.url }

    init() {
        folder = ChosenFolder(bookmarkKey: "repositoryFolderBookmark",
                              defaultURL: Library.baseFolder.appendingPathComponent(
                                Platform.isMac ? "Value Recorder Repository" : "Repository", isDirectory: true))
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

    func useDefaultFolder() {
        folder.useDefault()
        refresh()
    }

    func refresh() {
        folder.ensure()
        let children = (try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        items = children.filter(Library.isFolder).map { folder in
            let note = (try? String(contentsOf: folder.appendingPathComponent(Self.noteFileName), encoding: .utf8)) ?? ""
            let text = folder.appendingPathComponent(folder.lastPathComponent).appendingPathExtension("txt")
            return RepositoryItem(folder: folder, savedOn: Library.created(folder), size: Library.size(of: folder),
                                  note: note, transcript: (try? String(contentsOf: text, encoding: .utf8)) ?? "")
        }
        .sorted { $0.savedOn > $1.savedOn }
    }

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    func contains(_ recording: Recording) -> Bool {
        items.contains { $0.title == recording.title }
    }

    /// Copies a recording (MP4 plus any MP3 and text) into the repository.
    @discardableResult
    func save(_ recording: Recording, note: String) -> Bool {
        folder.ensure()
        let target = Library.uniqueURL(in: folderURL, name: recording.title, ext: nil)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let newName = target.lastPathComponent
            for item in recording.files {
                let sameName = item.url.deletingPathExtension().lastPathComponent == recording.title
                let name = sameName ? "\(newName).\(item.url.pathExtension)" : item.url.lastPathComponent
                try FileManager.default.copyItem(at: item.url, to: target.appendingPathComponent(name))
            }
            if !note.isEmpty {
                try note.write(to: target.appendingPathComponent(Self.noteFileName), atomically: true, encoding: .utf8)
            }
            refresh()
            return true
        } catch {
            try? FileManager.default.removeItem(at: target)
            lastError = "Couldn’t save to the repository: \(error.localizedDescription)"
            refresh()
            return false
        }
    }

    /// Copies an item back into the recordings library.
    func restore(_ item: RepositoryItem, to library: Library) {
        let target = Library.uniqueURL(in: library.folderURL, name: item.title, ext: nil)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let newName = target.lastPathComponent
            for file in item.files {
                let sameName = file.deletingPathExtension().lastPathComponent == item.title
                let name = sameName ? "\(newName).\(file.pathExtension)" : file.lastPathComponent
                try FileManager.default.copyItem(at: file, to: target.appendingPathComponent(name))
            }
        } catch {
            try? FileManager.default.removeItem(at: target)
            lastError = "Couldn’t copy back to Recordings: \(error.localizedDescription)"
        }
        library.refresh()
    }

    func setNote(_ note: String, for item: RepositoryItem) {
        let url = item.folder.appendingPathComponent(Self.noteFileName)
        if note.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try? note.write(to: url, atomically: true, encoding: .utf8)
        }
        refresh()
    }

    func remove(_ item: RepositoryItem) {
        do {
            try FileManager.default.trashItem(at: item.folder, resultingItemURL: nil)
        } catch {
            lastError = "Couldn’t remove “\(item.title)”: \(error.localizedDescription)"
        }
        refresh()
    }
}
