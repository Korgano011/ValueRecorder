import SwiftUI
import UniformTypeIdentifiers

/// "Save recordings in" — shows the folder and lets the person pick another
/// one (any folder, an external drive, or iCloud Drive).
struct SaveLocationSection: View {
    @Environment(Library.self) private var library
    var disabled = false
    @State private var picking = false

    var body: some View {
        Section("Save recordings in") {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(library.folderURL.lastPathComponent).fontWeight(.medium)
                    Text(Platform.isMac ? Library.displayPath(library.folderURL)
                                        : (library.folder.isCustom ? Library.displayPath(library.folderURL)
                                                                   : Platform.filesHint + " › Recordings"))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer()
            }
            HStack {
                Button("Change…") { picking = true }
                    .disabled(disabled)
                #if os(macOS)
                Button("Show in Finder") { library.showInFinder() }
                #endif
                if library.folder.isCustom {
                    Button("Use Default") { library.useDefaultFolder() }
                        .disabled(disabled)
                }
                Spacer()
            }
            .buttonStyle(.bordered)
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { library.useFolder(url) }
        }
    }
}
