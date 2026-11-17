import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case record
    case recording(URL)
    case converter
    case audioToText
    case repository
    case settings
}

struct ContentView: View {
    @Environment(Library.self) private var library
    @Environment(Repository.self) private var repository
    @Environment(RecorderModel.self) private var recorder
    @Environment(Jobs.self) private var jobs
    @State private var selection: SidebarItem? = Platform.isMac ? .record : nil
    @State private var choosingFolder = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Record", systemImage: recorder.isRecording ? "record.circle.fill" : "record.circle")
                    .foregroundStyle(recorder.isRecording ? .red : .primary)
                    .tag(SidebarItem.record)
                Label("MP3 & MP4 Converter", systemImage: "arrow.triangle.2.circlepath")
                    .tag(SidebarItem.converter)
                Label("Audio to Text", systemImage: "text.bubble")
                    .tag(SidebarItem.audioToText)
                Label("Repository", systemImage: "archivebox")
                    .badge(repository.items.count)
                    .tag(SidebarItem.repository)
                #if os(iOS)
                Label("Settings", systemImage: "gear")
                    .tag(SidebarItem.settings)
                #endif

                Section("Recordings") {
                    if library.recordings.isEmpty {
                        Text("No recordings yet").foregroundStyle(.secondary)
                    }
                    ForEach(library.recordings) { recording in
                        RecordingRow(recording: recording)
                            .tag(SidebarItem.recording(recording.folder))
                            .contextMenu {
                                #if os(macOS)
                                Button("Show in Finder") { library.showInFinder(recording.videoURL) }
                                Divider()
                                #endif
                                Button("Move to Trash", role: .destructive) {
                                    if selection == .recording(recording.folder) { selection = .record }
                                    library.trash(recording)
                                }
                            }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
            .safeAreaInset(edge: .bottom) { footer }
        } detail: {
            switch selection {
            case .record, nil:
                RecordView(selection: $selection)
            case .settings:
                SettingsView()
            case .converter:
                ConverterView()
            case .audioToText:
                AudioToTextView()
            case .repository:
                RepositoryView(selection: $selection)
            case .recording(let folder):
                if let recording = library.recordings.first(where: { $0.folder == folder }) {
                    RecordingDetailView(recording: recording, selection: $selection)
                        .id(recording.folder)
                } else {
                    ContentUnavailableView("Recording not found", systemImage: "questionmark.folder")
                }
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { library.lastError != nil || repository.lastError != nil },
            set: { if !$0 { library.lastError = nil; repository.lastError = nil } })) {
            Button("OK") {}
        } message: {
            Text(library.lastError ?? repository.lastError ?? "")
        }
        #if os(iOS)
        .task {
            library.onNewBroadcast = { [library, jobs] recording in
                if Prefs.store.bool(forKey: Prefs.autoMP3) { jobs.makeMP3(recording, library: library) }
                if Prefs.store.bool(forKey: Prefs.autoText) { jobs.transcribe(recording, library: library) }
            }
            while !Task.isCancelled {
                recorder.poll(library: library)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        #endif
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                library.refresh()
                repository.refresh()
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recordings use \(SizeText.bytes(library.totalSize))")
                .font(.caption.weight(.medium))
            HStack(spacing: 6) {
                Text("Saving to \(Library.displayPath(library.folderURL))")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Button("Change…") { choosingFolder = true }
                    .font(.caption2)
                    .buttonStyle(.borderless)
                    .disabled(recorder.isRecording)
            }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { library.useFolder(url) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .help("Recordings are saved in \(Library.displayPath(library.folderURL)). Change it in Settings.")
        #if os(iOS)
        .background(.bar)
        #endif
    }
}

struct RecordingRow: View {
    let recording: Recording
    @Environment(Jobs.self) private var jobs

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(recording.title).lineLimit(1)
            HStack(spacing: 6) {
                Text(SizeText.bytes(recording.totalSize))
                if recording.hasMP3 { Image(systemName: "music.note") }
                if recording.hasTranscript { Image(systemName: "text.alignleft") }
                if jobs.isBusy(recording.folder) { ProgressView().controlSize(.mini) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}
