import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// Settings → Meetings (M3): how long meeting audio is kept, and the optional voice-activity model for live text.
struct MeetingSettingsGroup: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var meetings = environment.meetingSettings
        SettingsGroup(
            title: "Meetings",
            footer:
                "Deleting meeting audio keeps the transcript and notes; a meeting still recording or not yet "
                + "transcribed is never touched. The voice-activity model lets live text break at pauses; without it, "
                + "live text updates every few seconds."
        ) {
            SettingsRow(title: "Keep meeting audio", caption: "Old audio is removed the next time Parakeet opens") {
                Picker("Keep meeting audio", selection: $meetings.retention) {
                    ForEach(MeetingAudioRetention.choices, id: \.self) { choice in
                        Text(Self.title(for: choice)).tag(choice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(AppColor.accentText)
            }
            if meetings.isVoiceActivityAvailable {
                ModelAssetRow(
                    title: "Voice activity model",
                    value: "Silero",
                    status: meetings.voiceActivityStatus,
                    approximateDownloadBytes: meetings.voiceActivityDownloadBytes,
                    runsOn: "CPU",
                    onDownload: { environment.downloadVoiceActivityModel() },
                    onDelete: { Task { await meetings.deleteVoiceActivityModel() } }
                )
            }
        }
        .task { await meetings.refresh() }
    }

    static func title(for retention: MeetingAudioRetention) -> String {
        switch retention {
        case .keepForever: "Forever"
        case .deleteAfterDays(let days): "\(days) days"
        }
    }
}
