import SwiftUI
import UniformTypeIdentifiers

/// Turns the speech in any audio or video file into text for note taking.
struct AudioToTextView: View {
    @Environment(Library.self) private var library
    @Environment(Jobs.self) private var jobs
    @AppStorage(Prefs.timestamps, store: Prefs.store) private var timestamps = false

    @State private var source: URL?
    @State private var text = ""
    @State private var savedURL: URL?
    @State private var dropTargeted = false
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button(source == nil ? "Choose Audio or Video…" : "Choose Another…") { picking = true }
                if let source { Text(source.lastPathComponent).lineLimit(1).truncationMode(.middle) }
                Spacer()
            }
            HStack(spacing: 12) {
                Toggle("Times like [1:05]", isOn: $timestamps)
                    .fixedSize()
                Spacer()
                Button("Turn into Text") { run() }
                    .buttonStyle(.borderedProminent)
                    .disabled(source == nil || source.map { jobs.fraction(.text, for: $0) != nil } == true)
            }
            if let source, let value = jobs.fraction(.text, for: source) {
                ProgressView(value: value) { Text("Listening… (on this Mac)") }
            }
            if let source, let error = jobs.errors[source] {
                Text(error).foregroundStyle(.red)
            }

            ZStack {
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                if text.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "text.bubble").font(.system(size: 34))
                        Text("Drop an audio or video file here, or choose one above.")
                        Text("For your recordings, use “Turn Audio into Text” on the recording itself.")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(dropTargeted ? Color.accentColor : .clear, lineWidth: 2))
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                pick(url)
                return true
            } isTargeted: { dropTargeted = $0 }

            HStack {
                Button("Copy") {
                    Platform.copy(text)
                }
                Button(savedURL == nil ? "Save as Text File" : "Save Changes") { save() }
                if let savedURL {
                    #if os(macOS)
                    Text("Saved in \(Library.displayPath(savedURL))").font(.caption).foregroundStyle(.secondary)
                    Button("Show in Finder") { library.showInFinder(savedURL) }.buttonStyle(.link)
                    #else
                    ShareLink(item: savedURL) { Image(systemName: "square.and.arrow.up") }
                    #endif
                }
                Spacer()
                if !library.texts.isEmpty {
                    Menu("Saved Notes (\(library.texts.count))") {
                        ForEach(library.texts, id: \.self) { url in
                            Button(url.deletingPathExtension().lastPathComponent) { open(url) }
                        }
                    }
                    .fixedSize()
                }
            }
            .disabled(text.isEmpty && library.texts.isEmpty)
        }
        .padding(20)
        .navigationTitle("Audio to Text")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.audiovisualContent]) { result in
            if case .success(let url) = result { pick(url) }
        }
    }

    private func pick(_ picked: URL) {
        guard let url = PickedFile.localCopy(of: picked) else { return }
        source = url
        savedURL = nil
        run()
    }

    private func run() {
        guard let source else { return }
        jobs.text(source: source, destination: nil, key: source, library: library) { result in
            text = result
            savedURL = nil
        }
    }

    private func save() {
        let url = savedURL ?? library.newTextURL(for: source ?? URL(fileURLWithPath: "Notes"))
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            savedURL = url
            library.refresh()
        } catch {
            library.lastError = "Couldn’t save the text: \(error.localizedDescription)"
        }
    }

    private func open(_ url: URL) {
        text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        savedURL = url
        source = nil
    }
}
