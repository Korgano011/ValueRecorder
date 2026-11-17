import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// Recordings kept for future use. Search covers names, notes and the text
/// made from each recording's audio.
struct RepositoryView: View {
    @Binding var selection: SidebarItem?
    @Environment(Library.self) private var library
    @Environment(Repository.self) private var repository

    @State private var search = ""
    @State private var editing: RepositoryItem?
    @State private var noteDraft = ""
    @State private var removing: RepositoryItem?
    @State private var playing: URL?
    @State private var choosingFolder = false

    private var shown: [RepositoryItem] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return repository.items }
        return repository.items.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.note.localizedCaseInsensitiveContains(query)
                || $0.transcript.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(repository.items.count) saved · \(SizeText.bytes(repository.totalSize))")
                        .font(.headline)
                    Text(Library.displayPath(repository.folderURL))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button("Change Folder…") { choosingFolder = true }
                #if os(macOS)
                Button("Show in Finder") { Platform.reveal(repository.folderURL) }
                #endif
            }
            .padding(16)
            Divider()

            if repository.items.isEmpty {
                ContentUnavailableView {
                    Label("Your repository is empty", systemImage: "archivebox")
                } description: {
                    Text("Open a recording and choose Save to Repository to keep it here for future use. You can point the repository at an external drive or iCloud Drive in Settings.")
                }
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                List(shown) { item in row(item) }
            }
        }
        .navigationTitle("Repository")
        .searchable(text: $search, prompt: "Search names, notes and text")
        .sheet(item: $editing) { item in
            VStack(alignment: .leading, spacing: 12) {
                Text("Note for “\(item.title)”").font(.headline)
                TextEditor(text: $noteDraft).frame(minWidth: 300, idealWidth: 400, minHeight: 140)
                HStack {
                    Spacer()
                    Button("Cancel") { editing = nil }.keyboardShortcut(.cancelAction)
                    Button("Save") {
                        repository.setNote(noteDraft, for: item)
                        editing = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .confirmationDialog("Remove “\(removing?.title ?? "")” from the repository?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let removing { repository.remove(removing) }
                removing = nil
            }
        }
        .onAppear { repository.refresh() }
        .sheet(item: Binding(get: { playing.map(PlayItem.init) }, set: { playing = $0?.url })) { item in
            PlayerSheet(url: item.url)
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { repository.useFolder(url) }
        }
    }

    private func row(_ item: RepositoryItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "film.stack").font(.title2).foregroundStyle(.secondary).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline)
                Text("\(item.savedOn.formatted(date: .abbreviated, time: .shortened)) · \(SizeText.bytes(item.size)) · \(item.files.map { $0.pathExtension.uppercased() }.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
                if !item.note.isEmpty {
                    Text(item.note).font(.callout).lineLimit(3)
                }
                if !search.isEmpty, let snippet = snippet(item.transcript) {
                    Text(snippet).font(.caption).foregroundStyle(.secondary).italic().lineLimit(2)
                }
            }
            Spacer()
            if let video = item.video {
                Button("Play") { playing = video }
                    .buttonStyle(.bordered)
            }
            Menu {
                Button("Edit Note…") { noteDraft = item.note; editing = item }
                Button("Copy Back to Recordings") {
                    repository.restore(item, to: library)
                    if let restored = library.recordings.first(where: { $0.title.hasPrefix(item.title) }) {
                        selection = .recording(restored.folder)
                    }
                }
                #if os(macOS)
                Button("Show in Finder") { Platform.reveal(item.folder) }
                #endif
                Divider()
                Button("Remove from Repository…", role: .destructive) { removing = item }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }

    private func snippet(_ text: String) -> String? {
        guard let range = text.range(of: search, options: .caseInsensitive) else { return nil }
        let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
        return "…" + text[start..<end].replacingOccurrences(of: "\n", with: " ") + "…"
    }
}

private struct PlayItem: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Plays a saved recording inside the app.
struct PlayerSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(url.deletingPathExtension().lastPathComponent).font(.headline).lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            PlayerView(player: player)
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 440)
        #endif
        .onAppear {
            let player = AVPlayer(url: url)
            self.player = player
            player.play()
        }
        .onDisappear { player?.pause() }
    }
}
