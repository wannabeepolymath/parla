import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

struct ParlaEntry: TimelineEntry {
    var date = Date()
    var session: DictationSession?
}
struct ParlaTimeline: TimelineProvider {
    func placeholder(in context: Context) -> ParlaEntry { ParlaEntry() }
    func getSnapshot(in context: Context, completion: @escaping (ParlaEntry) -> Void) { completion(ParlaEntry(session: try? SessionStore().read())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ParlaEntry>) -> Void) {
        // Timeline refresh is advisory; the Live Activity is the timely recording surface.
        completion(Timeline(entries: [ParlaEntry(session: try? SessionStore().read())], policy: .after(Date().addingTimeInterval(60))))
    }
}
struct ParlaWidget: Widget {
    let kind = "dev.parla.ios.status"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ParlaTimeline()) { entry in
            VStack(alignment: .leading, spacing: 12) {
                HStack { Image(systemName: "waveform"); Text("Parla").font(.headline); Spacer() }
                Text(entry.session?.phase == .recording ? "Recording may be active" : "Think it. Speak it.").font(.custom("EBGaramond-Regular", size: 25))
                if let session = entry.session, session.phase == .recording, session.expires > Date() {
                    Button(intent: StopRecordingIntent(session: session.id, generation: session.generation)) { Label("Stop & transcribe", systemImage: "stop.fill") }.buttonStyle(.bordered)
                } else {
                    Link(destination: URL(string: "parla://home")!) { Label("Open to dictate", systemImage: "mic") }
                }
                if entry.session?.phase == .recording { Text("Open Parla for current status").font(.caption2) }
            }.containerBackground(Color("hexF8F6FF"), for: .widget).widgetURL(URL(string: "parla://home"))
        }.configurationDisplayName("Parla").description("Open Parla or stop the recording session shown here. Widget status may be delayed.").supportedFamilies([.systemSmall, .systemMedium])
    }
}
struct ParlaLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivity.self) { context in
            HStack(spacing: 16) {
                Image(systemName: "waveform").font(.title)
                VStack(alignment: .leading) { Text("Parla · \(context.state.phase)").font(.headline); Text(context.state.started, style: .timer).monospacedDigit() }
                Spacer()
                if context.state.phase == "Listening" {
                    Button(intent: StopRecordingIntent(session: context.attributes.sessionID, generation: context.attributes.generation)) { Image(systemName: "stop.fill") }.buttonStyle(.borderedProminent).tint(.black).accessibilityLabel("Stop and transcribe")
                }
                Button(intent: CancelRecordingIntent(session: context.attributes.sessionID, generation: context.attributes.generation)) { Image(systemName: "xmark") }.buttonStyle(.bordered).accessibilityLabel("Cancel dictation")
            }.padding(20).activityBackgroundTint(Color("buttonPurple")).activitySystemActionForegroundColor(.black).widgetURL(URL(string: "parla://home"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Label("Parla", systemImage: "waveform") }
                DynamicIslandExpandedRegion(.trailing) { Text(context.state.started, style: .timer).monospacedDigit() }
                DynamicIslandExpandedRegion(.center) { Text(context.state.phase) }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        if context.state.phase == "Listening" { Button(intent: StopRecordingIntent(session: context.attributes.sessionID, generation: context.attributes.generation)) { Label("Stop", systemImage: "stop.fill") }.buttonStyle(.bordered) }
                        Button(intent: CancelRecordingIntent(session: context.attributes.sessionID, generation: context.attributes.generation)) { Label("Cancel", systemImage: "xmark") }.buttonStyle(.bordered)
                    }
                }
            } compactLeading: { Image(systemName: "waveform") }
              compactTrailing: { Image(systemName: context.state.phase == "Listening" ? "mic.fill" : "ellipsis") }
              minimal: { Image(systemName: "waveform") }
                .widgetURL(URL(string: "parla://home"))
        }
    }
}
struct ParlaRecordingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.parla.ios.recording-control") {
            ControlWidgetButton(action: StartRecordingIntent()) { Label("Record with Parla", systemImage: "mic") }
        }.displayName("Start Parla").description("Opens Parla and starts a recording with an active Live Activity.")
    }
}
@main struct ParlaWidgetBundle: WidgetBundle {
    var body: some Widget { ParlaWidget(); ParlaLiveActivity(); ParlaRecordingControl() }
}
