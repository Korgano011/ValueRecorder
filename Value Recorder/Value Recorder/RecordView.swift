#if os(macOS)
import SwiftUI

struct RecordView: View {
    @Binding var selection: SidebarItem?
    @Environment(Library.self) private var library
    @Environment(Jobs.self) private var jobs
    @Environment(RecorderModel.self) private var recorder

    @AppStorage(Prefs.quality, store: Prefs.store) private var quality = VideoQuality.p240.rawValue
    @AppStorage(Prefs.codec, store: Prefs.store) private var codec = VideoCodec.hevc.rawValue
    @AppStorage(Prefs.frameRate, store: Prefs.store) private var frameRate = FrameRate.fps15.rawValue
    @AppStorage(Prefs.systemAudio, store: Prefs.store) private var systemAudio = true
    @AppStorage(Prefs.microphone, store: Prefs.store) private var microphone = false
    @AppStorage(Prefs.showsCursor, store: Prefs.store) private var showsCursor = true
    @AppStorage(Prefs.autoMP3, store: Prefs.store) private var autoMP3 = false
    @AppStorage(Prefs.autoText, store: Prefs.store) private var autoText = false

    private var chosenQuality: VideoQuality { VideoQuality(rawValue: quality) ?? .p240 }
    private var chosenCodec: VideoCodec { VideoCodec(rawValue: codec) ?? .hevc }

    var body: some View {
        @Bindable var recorder = recorder
        Form {
            if recorder.needsPermission {
                Section {
                    Label("Value Recorder needs permission to record the screen.", systemImage: "lock.shield")
                        .font(.headline)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. Click **Allow Screen Recording**. If macOS asks, choose Open System Settings.")
                        Text("2. In **Screen & System Audio Recording**, turn on **Value Recorder**. (If it isn’t listed, click **+** and pick Value Recorder.)")
                        Text("3. Quit and reopen Value Recorder — macOS only applies the change after a restart.")
                    }
                    .foregroundStyle(.secondary)
                    HStack {
                        Button("Allow Screen Recording") { recorder.requestPermission() }
                            .buttonStyle(.borderedProminent)
                        Button("Open System Settings") { RecorderModel.openPrivacySettings() }
                        Button("Quit Value Recorder") { NSApp.terminate(nil) }
                    }
                }
            }

            Section("Quality — smaller is the point") {
                Picker("Size", selection: $quality) {
                    ForEach(VideoQuality.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .disabled(recorder.isRecording)
                Text(chosenQuality.note).foregroundStyle(.secondary)
                LabeledContent("Disk space") {
                    Text("about \(SizeText.megabytes(chosenQuality.megabytesPerMinute(codec: chosenCodec, withAudio: systemAudio || microphone))) per minute")
                        .monospacedDigit()
                }
            }

            Section("What to record") {
                Picker("Record", selection: $recorder.selectedSourceID) {
                    ForEach(recorder.displays) { Text($0.name).tag(Optional($0.id)) }
                    if !recorder.windows.isEmpty {
                        Divider()
                        ForEach(recorder.windows) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                .disabled(recorder.isRecording)
                Toggle("Sound from this Mac", isOn: $systemAudio).disabled(recorder.isRecording)
                Toggle("My microphone", isOn: $microphone).disabled(recorder.isRecording)
                Toggle("Show the pointer", isOn: $showsCursor).disabled(recorder.isRecording)
                TextField("Name (optional)", text: $recorder.title, prompt: Text(Library.defaultTitle()))
                    .disabled(recorder.isRecording)
            }

            SaveLocationSection(disabled: recorder.isRecording)

            Section("When the recording stops") {
                Toggle("Also make an MP3 of the sound", isOn: $autoMP3)
                Toggle("Also turn the audio into text", isOn: $autoText)
            }

            Section {
                controls
                if let message = recorder.errorMessage {
                    Text(message).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Record")
        .task { await recorder.loadSources() }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 14) {
            switch recorder.phase {
            case .idle:
                Button {
                    Task { await recorder.start(library: library) }
                } label: {
                    Label("Start Recording", systemImage: "record.circle").frame(minWidth: 160)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Refresh List") { Task { await recorder.loadSources() } }
            case .starting:
                ProgressView().controlSize(.small)
                Text("Starting…")
            case .recording, .stopping:
                Button {
                    Task { await stop() }
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill").frame(minWidth: 100)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(recorder.phase == .stopping)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button(recorder.isPaused ? "Resume" : "Pause") { recorder.togglePause() }
                    .controlSize(.large)
                    .disabled(recorder.phase == .stopping)
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let seconds = recorder.elapsed(at: context.date)
                    HStack(spacing: 10) {
                        Text(TimeText.clock(seconds)).font(.title2.monospacedDigit())
                        Text("≈ \(SizeText.megabytes(seconds / 60 * chosenQuality.megabytesPerMinute(codec: chosenCodec, withAudio: systemAudio || microphone)))")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if recorder.isPaused {
                    Text("Paused").foregroundStyle(.orange)
                } else if systemAudio || microphone {
                    Gauge(value: Double(recorder.level)) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .frame(width: 90)
                        .tint(.green)
                }
            }
        }
    }

    private func stop() async {
        guard let recording = await recorder.stop(library: library) else { return }
        if autoMP3 && (systemAudio || microphone) { jobs.makeMP3(recording, library: library) }
        if autoText && (systemAudio || microphone) { jobs.transcribe(recording, library: library) }
        selection = .recording(recording.folder)
    }
}
#endif
