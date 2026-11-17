import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The few things that differ between the Mac and iPhone/iPad.
enum Platform {
    static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// Mac: opens the file in its usual app. (iPhone uses a Share button.)
    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    /// Mac: shows the file selected in Finder; a folder is opened.
    static func reveal(_ url: URL) {
        #if os(macOS)
        if Library.isFolder(url) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        #endif
    }

    /// Where files can be found, in words.
    static var filesHint: String {
        isMac ? "Finder" : "the Files app › On My iPhone › Value Recorder"
    }
}

/// Mac: Open + Show in Finder buttons. iPhone/iPad: a Share button
/// (save to Files, AirDrop, Mail…).
struct FileButtons: View {
    let url: URL

    var body: some View {
        #if os(macOS)
        Button { Platform.open(url) } label: { Image(systemName: "arrow.up.forward.app") }
            .buttonStyle(.borderless).help("Open")
        Button { Platform.reveal(url) } label: { Image(systemName: "magnifyingglass") }
            .buttonStyle(.borderless).help("Show in Finder")
        #else
        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
            .buttonStyle(.borderless)
        #endif
    }
}

/// Copies a picked file somewhere the app can always read it (iPhone/iPad
/// files from the Files app are only lent while being picked). On the Mac
/// the original is used directly.
enum PickedFile {
    static func localCopy(of url: URL) -> URL? {
        #if os(macOS)
        return url
        #else
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Picked", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.copyItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
        #endif
    }
}
