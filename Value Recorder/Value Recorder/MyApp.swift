import SwiftUI

@main struct MyApp: App {
    @State private var library = Library()
    @State private var repository = Repository()
    @State private var jobs = Jobs()
    @State private var recorder = RecorderModel()

    init() {
        Prefs.registerDefaults()
    }

    var body: some Scene {
        WindowGroup("Value Recorder") {
            ContentView()
                .environment(library)
                .environment(repository)
                .environment(jobs)
                .environment(recorder)
                #if os(macOS)
                .frame(minWidth: 860, minHeight: 560)
                #endif
        }
        #if os(macOS)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        #endif

        #if os(macOS)
        MenuBarExtra(isInserted: .constant(recorder.isRecording)) {
            Button(recorder.isPaused ? "Resume" : "Pause") { recorder.togglePause() }
            Button("Stop Recording") {
                Task {
                    let recording = await recorder.stop(library: library)
                    if let recording { finished(recording) }
                }
            }
        } label: {
            Image(systemName: recorder.isPaused ? "pause.circle.fill" : "record.circle.fill")
        }

        Settings {
            SettingsView()
                .environment(library)
                .environment(repository)
        }
        #endif
    }

    #if os(macOS)

    private func finished(_ recording: Recording) {
        let defaults = Prefs.store
        let hasAudio = defaults.bool(forKey: Prefs.systemAudio) || defaults.bool(forKey: Prefs.microphone)
        if hasAudio && defaults.bool(forKey: Prefs.autoMP3) { jobs.makeMP3(recording, library: library) }
        if hasAudio && defaults.bool(forKey: Prefs.autoText) { jobs.transcribe(recording, library: library) }
        NSApp.activate()
    }
    #endif
}
