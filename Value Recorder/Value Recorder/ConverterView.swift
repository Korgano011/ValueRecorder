import SwiftUI
import UniformTypeIdentifiers

/// The built-in MP3 and MP4 converter for any audio or video file.
struct ConverterView: View {
    @Environment(Library.self) private var library
    @Environment(Jobs.self) private var jobs
    @AppStorage(Prefs.mp3Bitrate, store: Prefs.store) private var mp3Bitrate = 64
    @AppStorage(Prefs.codec, store: Prefs.store) private var codec = VideoCodec.hevc.rawValue

    @State private var source: URL?
    @State private var sourceSize: Int64 = 0
    @State private var quality = VideoQuality.p240
    @State private var lastOutput: URL?
    @State private var dropTargeted = false
    @State private var picking = false

    var body: some View {
        Form {
            Section("1. Choose a file") {
                VStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 34)).foregroundStyle(.secondary)
                    if let source {
                        Text(source.lastPathComponent).font(.headline)
                        Text(SizeText.bytes(sourceSize)).foregroundStyle(.secondary)
                    } else {
                        Text("Drop a video or audio file here").font(.headline)
                    }
                    Button(source == nil ? "Choose File…" : "Choose Another…") { picking = true }
                }
                .frame(maxWidth: .infinity, minHeight: 130)
                .background(dropTargeted ? Color.accentColor.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    pick(url)
                    return true
                } isTargeted: { dropTargeted = $0 }
            }

            Section("2. Convert") {
                HStack {
                    Picker("MP4 size", selection: $quality) {
                        ForEach(VideoQuality.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                    Spacer()
                    Button("Convert to MP4") { convertMP4() }
                        .buttonStyle(.borderedProminent)
                        .disabled(source == nil || busy(.mp4))
                }
                Picker("Video type", selection: $codec) {
                    ForEach(VideoCodec.allCases) { Text($0.label).tag($0.rawValue) }
                }
                HStack {
                    Picker("MP3 quality", selection: $mp3Bitrate) {
                        ForEach([32, 48, 64, 96, 128, 192], id: \.self) { Text("\($0) kbps").tag($0) }
                    }
                    .frame(maxWidth: 320)
                    Spacer()
                    Button("Convert to MP3") { convertMP3() }
                        .buttonStyle(.borderedProminent)
                        .disabled(source == nil || busy(.mp3))
                }
                if let source {
                    if let value = jobs.fraction(.mp4, for: source) {
                        ProgressView(value: value) { Text("Making MP4…") }
                    }
                    if let value = jobs.fraction(.mp3, for: source) {
                        ProgressView(value: value) { Text("Making MP3…") }
                    }
                    if let error = jobs.errors[source] {
                        Text(error).foregroundStyle(.red)
                    }
                }
                if let lastOutput {
                    HStack {
                        Label("Saved \(lastOutput.lastPathComponent) — \(SizeText.bytes(Library.size(of: lastOutput)))",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        FileButtons(url: lastOutput)
                    }
                }
            }

            Section("Converted files") {
                if library.converted.isEmpty {
                    Text("Nothing converted yet. Files are saved in \(Platform.isMac ? Library.displayPath(library.convertedFolder) : Platform.filesHint + " › Recordings › Converted").")
                        .foregroundStyle(.secondary)
                }
                ForEach(library.converted, id: \.self) { url in
                    HStack {
                        Image(systemName: url.pathExtension.lowercased() == "mp3" ? "music.note" : "film")
                            .foregroundStyle(.secondary).frame(width: 18)
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(SizeText.bytes(Library.size(of: url))).foregroundStyle(.secondary).monospacedDigit()
                        FileButtons(url: url)
                        Button { library.trashFile(url) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Move to Trash")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("MP3 & MP4 Converter")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.audiovisualContent]) { result in
            if case .success(let url) = result { pick(url) }
        }
    }

    private func busy(_ kind: Jobs.Kind) -> Bool {
        source.map { jobs.fraction(kind, for: $0) != nil } ?? false
    }

    private func pick(_ picked: URL) {
        guard let url = PickedFile.localCopy(of: picked) else { return }
        source = url
        sourceSize = Library.size(of: url)
        lastOutput = nil
    }

    private func convertMP4() {
        guard let source else { return }
        let destination = library.newConvertedURL(for: source, ext: "mp4", suffix: " \(quality.label)")
        jobs.mp4(source: source, destination: destination, quality: quality, key: source, library: library) {
            lastOutput = $0
        }
    }

    private func convertMP3() {
        guard let source else { return }
        let destination = library.newConvertedURL(for: source, ext: "mp3")
        jobs.mp3(source: source, destination: destination, title: source.deletingPathExtension().lastPathComponent,
                 key: source, library: library) {
            lastOutput = $0
        }
    }
}
