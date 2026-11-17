import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(Library.self) private var library
    @Environment(Repository.self) private var repository

    @AppStorage(Prefs.quality, store: Prefs.store) private var quality = VideoQuality.p240.rawValue
    @AppStorage(Prefs.codec, store: Prefs.store) private var codec = VideoCodec.hevc.rawValue
    @AppStorage(Prefs.frameRate, store: Prefs.store) private var frameRate = FrameRate.fps15.rawValue
    @AppStorage(Prefs.mp3Bitrate, store: Prefs.store) private var mp3Bitrate = 64
    @AppStorage(Prefs.timestamps, store: Prefs.store) private var timestamps = false
    @State private var choosing: Chooser = .recordings
    @State private var pickerShown = false

    enum Chooser: Identifiable { case recordings, repository; var id: Self { self } }

    var body: some View {
        Form {
            Section("Recording") {
                Picker("Size", selection: $quality) {
                    ForEach(VideoQuality.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Frames per second", selection: $frameRate) {
                    ForEach(FrameRate.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Text("Fewer frames means smaller files. 10–15 is plenty for slides, documents and apps.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Video type", selection: $codec) {
                    ForEach(VideoCodec.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Text("HEVC files are about 30% smaller. H.264 plays on very old devices too.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("MP3 and text") {
                Picker("MP3 quality", selection: $mp3Bitrate) {
                    ForEach([32, 48, 64, 96, 128, 192], id: \.self) { Text("\($0) kbps").tag($0) }
                }
                Toggle("Start each line of text with its time, like [1:05]", isOn: $timestamps)
            }

            Section("Recordings folder") {
                folderRow(Library.displayPath(library.folderURL), custom: library.folder.isCustom,
                          change: { choosing = .recordings; pickerShown = true }, reset: library.useDefaultFolder)
            }

            Section("Repository folder") {
                folderRow(Library.displayPath(repository.folderURL), custom: repository.folder.isCustom,
                          change: { choosing = .repository; pickerShown = true }, reset: repository.useDefaultFolder)
                Text("Tip: choose a folder in iCloud Drive or on an external drive so saved recordings don’t use space on this device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        #else
        .navigationTitle("Settings")
        #endif
        .fileImporter(isPresented: $pickerShown, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            if choosing == .repository { repository.useFolder(url) } else { library.useFolder(url) }
        }
    }

    private func folderRow(_ path: String, custom: Bool, change: @escaping () -> Void, reset: @escaping () -> Void) -> some View {
        HStack {
            Text(path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer()
            Button("Change…", action: change)
            if custom { Button("Use Default", action: reset) }
        }
    }
}
