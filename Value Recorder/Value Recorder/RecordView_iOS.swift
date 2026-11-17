#if os(iOS)
import Observation
import ReplayKit
import SwiftUI

/// iPhone/iPad: the recording itself happens in the Value Recorder Broadcast
/// extension (whole screen, every app). This just tracks whether it's running.
@Observable final class RecorderModel {
    private(set) var isRecording = false
    var isPaused: Bool { false }

    /// Checks the shared inbox; when a recording finishes, the library pulls it in.
    func poll(library: Library) {
        let running = library.broadcastInProgress
        if isRecording != running || !running { library.refresh() }
        isRecording = running
    }
}

/// Apple's screen-recording button, set to start Value Recorder.
final class BroadcastButton {
    let view: RPSystemBroadcastPickerView = {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = Prefs.broadcastExtension
        picker.showsMicrophoneButton = true
        return picker
    }()

    /// Opens the system "Screen Recording" sheet.
    func show() {
        for case let button as UIButton in view.subviews {
            button.sendActions(for: .touchUpInside)
            button.sendActions(for: .touchDown)
        }
    }
}

private struct BroadcastButtonHost: UIViewRepresentable {
    let button: BroadcastButton
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView { button.view }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

struct RecordView: View {
    @Binding var selection: SidebarItem?
    @Environment(Library.self) private var library
    @Environment(RecorderModel.self) private var recorder

    @AppStorage(Prefs.quality, store: Prefs.store) private var quality = VideoQuality.p240.rawValue
    @AppStorage(Prefs.codec, store: Prefs.store) private var codec = VideoCodec.hevc.rawValue
    @AppStorage(Prefs.frameRate, store: Prefs.store) private var frameRate = FrameRate.fps15.rawValue
    @AppStorage(Prefs.autoMP3, store: Prefs.store) private var autoMP3 = false
    @AppStorage(Prefs.autoText, store: Prefs.store) private var autoText = false

    @State private var broadcast = BroadcastButton()

    private var chosenQuality: VideoQuality { VideoQuality(rawValue: quality) ?? .p240 }
    private var chosenCodec: VideoCodec { VideoCodec(rawValue: codec) ?? .hevc }

    var body: some View {
        Form {
            Section("Quality — smaller is the point") {
                Picker("Size", selection: $quality) {
                    ForEach(VideoQuality.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .disabled(recorder.isRecording)
                Text(chosenQuality.note).font(.callout).foregroundStyle(.secondary)
                Picker("Frames per second", selection: $frameRate) {
                    ForEach(FrameRate.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .disabled(recorder.isRecording)
                LabeledContent("Disk space") {
                    Text("about \(SizeText.megabytes(chosenQuality.megabytesPerMinute(codec: chosenCodec))) per minute")
                        .monospacedDigit()
                }
            }

            Section {
                Button {
                    broadcast.show()
                } label: {
                    Label(recorder.isRecording ? "Stop Recording" : "Start Recording",
                          systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                .overlay(alignment: .trailing) {
                    // The real system button has to be on screen; it stays tiny and invisible.
                    BroadcastButtonHost(button: broadcast)
                        .frame(width: 1, height: 1)
                        .opacity(0.02)
                        .allowsHitTesting(false)
                }

                if recorder.isRecording {
                    Label("Recording the whole screen at \(chosenQuality.label). Stop here, from the red bar at the top of the screen, or in Control Center.",
                          systemImage: "record.circle.fill")
                        .foregroundStyle(.red)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. Tap Start Recording.")
                        Text("2. Make sure **Value Recorder** is picked. Turn the **Microphone** on if you want your voice.")
                        Text("3. Tap **Start Broadcast**, then go to any app. Everything on screen is recorded.")
                        Text("When you stop, the recording shows up here under Recordings.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }

            SaveLocationSection(disabled: recorder.isRecording)

            Section("When the recording stops") {
                Toggle("Also make an MP3 of the sound", isOn: $autoMP3)
                Toggle("Also turn the audio into text", isOn: $autoText)
                Text("These run the next time you open Value Recorder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Record")
    }
}
#endif
