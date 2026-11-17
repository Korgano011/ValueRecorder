import AVKit
import SwiftUI

struct RecordingDetailView: View {
    let recording: Recording
    @Binding var selection: SidebarItem?
    @Environment(Library.self) private var library
    @Environment(Repository.self) private var repository
    @Environment(Jobs.self) private var jobs

    @State private var player: AVPlayer?
    @State private var duration: TimeInterval = 0
    @State private var transcript = ""
    @State private var savedTranscript = ""
    @State private var newTitle = ""
    @State private var renaming = false
    @State private var smallerQuality = VideoQuality.p120
    @State private var savingToRepository = false
    @State private var repositoryNote = ""
    @State private var removeAfterSaving = false
    @State private var confirmTrash = false

    private var key: URL { recording.folder }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let player {
                    PlayerView(player: player)
                        .frame(minHeight: 260, idealHeight: 340)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if let error = jobs.errors[key] {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                GroupBox("Convert") { convertBox }
                GroupBox("Files in this recording") { filesBox }
                GroupBox("Text from the audio") { textBox }
            }
            .padding(20)
        }
        .navigationTitle(recording.title)
        .toolbar {
            ToolbarItemGroup {
                Button { savingToRepository = true } label: {
                    Label(repository.contains(recording) ? "Saved in Repository" : "Save to Repository",
                          systemImage: repository.contains(recording) ? "archivebox.fill" : "archivebox")
                }
                .help("Copy this recording into your repository for future use")
                #if os(macOS)
                Button { library.showInFinder(recording.videoURL) } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                #else
                ShareLink(item: recording.videoURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                #endif
                Button(role: .destructive) { confirmTrash = true } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
            }
        }
        .confirmationDialog("Move “\(recording.title)” to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) {
                selection = .record
                library.trash(recording)
            }
        }
        .sheet(isPresented: $savingToRepository) { repositorySheet }
        .task(id: recording.videoURL) {
            player = AVPlayer(url: recording.videoURL)
            duration = await Library.duration(of: recording.videoURL)
            loadTranscript()
        }
        .onChange(of: jobs.transcriptRevision[key]) { loadTranscript() }
        .onDisappear { player?.pause() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            if renaming {
                TextField("Name", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .onSubmit(rename)
                Button("Rename", action: rename)
                Button("Cancel") { renaming = false }
            } else {
                Text(recording.title).font(.title2.weight(.semibold))
                Button("Rename") { newTitle = recording.title; renaming = true }
                    .buttonStyle(.borderless)
            }
            Spacer()
            Text("\(TimeText.clock(duration)) · \(SizeText.bytes(recording.totalSize)) · \(recording.created.formatted(date: .abbreviated, time: .shortened))")
                .foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private var convertBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    jobs.makeMP3(recording, library: library)
                } label: {
                    Label(recording.hasMP3 ? "Make MP3 Again" : "Make MP3", systemImage: "music.note")
                }
                .disabled(jobs.fraction(.mp3, for: key) != nil)
                progress(.mp3, "Making MP3…")
                Spacer()
            }
            HStack {
                Button {
                    jobs.makeSmallerMP4(recording, quality: smallerQuality, library: library)
                } label: {
                    Label("Make Smaller MP4", systemImage: "film")
                }
                .disabled(jobs.fraction(.mp4, for: key) != nil)
                Picker("at", selection: $smallerQuality) {
                    ForEach(VideoQuality.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                progress(.mp4, "Shrinking…")
                Spacer()
            }
            Text("A smaller copy is saved next to the original. Delete whichever you don’t need to free space.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
    }

    private var filesBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(recording.files, id: \.url) { file in
                HStack {
                    Image(systemName: icon(for: file.url))
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    Text(file.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(SizeText.bytes(file.size)).monospacedDigit().foregroundStyle(.secondary)
                    FileButtons(url: file.url)
                    if file.url != recording.videoURL {
                        Button { library.trashFile(file.url) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Move this file to the Trash")
                    }
                }
            }
            Text("Saved in \(Platform.isMac ? Library.displayPath(recording.folder) : Platform.filesHint + " › Recordings")")
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
    }

    private var textBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    jobs.transcribe(recording, library: library)
                } label: {
                    Label(recording.hasTranscript ? "Make Text Again" : "Turn Audio into Text", systemImage: "text.bubble")
                }
                .disabled(jobs.fraction(.text, for: key) != nil)
                progress(.text, "Listening…")
                Spacer()
                if recording.hasTranscript {
                    Button("Copy") {
                        Platform.copy(transcript)
                    }
                    Button("Save Changes") {
                        try? transcript.write(to: recording.transcriptURL, atomically: true, encoding: .utf8)
                        savedTranscript = transcript
                    }
                    .disabled(transcript == savedTranscript)
                }
            }
            if recording.hasTranscript {
                TextEditor(text: $transcript)
                    .font(.body)
                    .frame(minHeight: 160)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            } else {
                Text("Turn what was said into text for your notes. It all happens on this Mac.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
    }

    private var repositorySheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save to Repository").font(.title3.weight(.semibold))
            Text("A copy of “\(recording.title)” (\(SizeText.bytes(recording.totalSize))) goes to \(Library.displayPath(repository.folderURL)).")
                .foregroundStyle(.secondary)
            TextField("Note (optional) — what is this recording for?", text: $repositoryNote, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
            Toggle("Then remove it from Recordings to free up space", isOn: $removeAfterSaving)
            HStack {
                Spacer()
                Button("Cancel") { savingToRepository = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let ok = repository.save(recording, note: repositoryNote)
                    savingToRepository = false
                    repositoryNote = ""
                    if ok && removeAfterSaving {
                        selection = .repository
                        library.trash(recording)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        #if os(macOS)
        .frame(width: 440)
        #endif
    }

    @ViewBuilder private func progress(_ kind: Jobs.Kind, _ label: String) -> some View {
        if let value = jobs.fraction(kind, for: key) {
            ProgressView(value: value) { Text(label).font(.caption) }
                .frame(width: 180)
        }
    }

    private func icon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp4", "mov": "film"
        case "mp3", "m4a": "music.note"
        case "txt": "text.alignleft"
        default: "doc"
        }
    }

    private func loadTranscript() {
        transcript = (try? String(contentsOf: recording.transcriptURL, encoding: .utf8)) ?? ""
        savedTranscript = transcript
    }

    private func rename() {
        renaming = false
        player?.pause()
        if let renamed = library.rename(recording, to: newTitle) {
            selection = .recording(renamed.folder)
        }
    }
}
