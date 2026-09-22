import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// "Recover meeting": meetings an earlier launch left behind (the app was closed, killed or crashed while recording
/// or transcribing). Recover transcribes what was saved; Discard deletes it after a confirmation; Later keeps
/// everything (the Library shows a banner to come back).
struct MeetingRecoverySheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDiscard: PendingMeetingRecovery?
    @State private var actionError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(
                        "Parakeet closed before these meetings were transcribed. Their audio is saved on this iPhone, "
                            + "up to the moment it closed."
                    )
                    .chirpFont(14.5)
                    .foregroundStyle(Tokens.Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    ForEach(environment.pendingMeetingRecoveries) { item in
                        row(item)
                    }
                    ForEach(Array(recoveringOnly), id: \.self) { id in
                        recoveringRow(id)
                    }
                    ForEach(outcomeIDs, id: \.self) { id in
                        outcomeRow(id)
                    }
                    if environment.pendingMeetingRecoveries.isEmpty && environment.recoveringMeetings.isEmpty
                        && environment.meetingRecoveryOutcomes.isEmpty
                    {
                        EmptyStateView(
                            title: "Nothing left to recover", message: "Recovered meetings are in the Library."
                        )
                        .background(CardBackground(radius: Tokens.Radius.s))
                    }
                }
                .padding(20)
            }
            .background(Tokens.Color.ground)
            .navigationTitle("Recover meetings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss() }
                }
            }
        }
        .confirmationDialog(
            "Discard this meeting?",
            isPresented: Binding(
                get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } }),
            titleVisibility: .visible, presenting: pendingDiscard
        ) { item in
            Button("Discard audio and notes", role: .destructive) {
                Task {
                    do {
                        try await environment.discardMeeting(item.id)
                    } catch {
                        actionError = Formatting.message(for: error)
                    }
                }
            }
            Button("Keep", role: .cancel) {}
        } message: { _ in
            Text("The recording and its notes are deleted from this iPhone. This cannot be undone.")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    /// Recoveries that ended this launch (not pending, not running).
    private var outcomeIDs: [UUID] {
        environment.meetingRecoveryOutcomes.keys
            .filter { !environment.recoveringMeetings.contains($0) }
            .sorted { $0.uuidString < $1.uuidString }
    }

    private func outcomeRow(_ id: UUID) -> some View {
        let outcome = environment.meetingRecoveryOutcomes[id]
        return VStack(alignment: .leading, spacing: 6) {
            Label(
                outcome?.title ?? "Meeting",
                systemImage: outcome?.succeeded == true ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
            )
            .chirpFont(15, .semibold)
            .foregroundStyle(outcome?.succeeded == true ? Tokens.Color.success : AppColor.error)
            Text(outcome?.message ?? "")
                .chirpFont(13)
                .foregroundStyle(Tokens.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground(radius: Tokens.Radius.s))
        .accessibilityElement(children: .combine)
    }

    /// Ids being recovered that are no longer in the pending list.
    private var recoveringOnly: Set<UUID> {
        environment.recoveringMeetings.subtracting(environment.pendingMeetingRecoveries.map(\.id))
    }

    private func row(_ item: PendingMeetingRecovery) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(item.displayName)
                    .chirpFont(15.5, .semibold)
                    .foregroundStyle(Tokens.Color.ink)
                    .lineLimit(1)
                if item.isPartialAudio {
                    StatusChip.partialAudio()
                }
            }
            Text(detail(item))
                .chirpFont(12.5)
                .monospacedDigit()
                .foregroundStyle(Tokens.Color.secondary)
            HStack(spacing: 10) {
                Button {
                    environment.recoverMeeting(item.id)
                } label: {
                    CapsuleButtonLabel(title: "Recover", kind: .filled)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityHint("Transcribes the saved audio. It appears in the Library.")
                Button {
                    pendingDiscard = item
                } label: {
                    CapsuleButtonLabel(title: "Discard…", kind: .destructive)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground(radius: Tokens.Radius.s))
    }

    private func recoveringRow(_ id: UUID) -> some View {
        let progress = environment.jobCenter.progress[id]
        return VStack(alignment: .leading, spacing: 8) {
            Text("Recovering…")
                .chirpFont(15, .semibold)
                .foregroundStyle(Tokens.Color.ink)
            ProgressView(value: progress?.fraction ?? 0)
                .tint(Tokens.Color.accent)
            Text(progress.map(Formatting.progress) ?? "Waiting to start")
                .chirpFont(12.5)
                .monospacedDigit()
                .foregroundStyle(Tokens.Color.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground(radius: Tokens.Radius.s))
    }

    private func detail(_ item: PendingMeetingRecovery) -> String {
        var parts = ["Started " + item.startedAt.formatted(date: .abbreviated, time: .shortened)]
        if let ms = item.audioDurationMs {
            parts.append("\(Formatting.duration(ms: ms)) saved")
        } else {
            parts.append("no readable audio")
        }
        if item.state == .awaitingTranscription { parts.append("stopped, not transcribed") }
        if item.hasNotes { parts.append("notes") }
        return parts.joined(separator: " · ")
    }
}

/// The Library's reminder while meetings wait to be recovered ("Later" in the sheet); Review reopens the sheet.
struct MeetingRecoveryBanner: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let count = environment.pendingMeetingRecoveries.count
        HStack(spacing: 12) {
            Image(systemName: "waveform.badge.exclamationmark")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppColor.accentText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(count == 1 ? "1 meeting to recover" : "\(count) meetings to recover")
                    .chirpFont(14.5, .semibold)
                    .foregroundStyle(Tokens.Color.ink)
                Text("Saved audio from when Parakeet closed")
                    .chirpFont(12)
                    .foregroundStyle(Tokens.Color.secondary)
            }
            Spacer(minLength: 8)
            Button {
                environment.isMeetingRecoveryPresented = true
            } label: {
                CapsuleButtonLabel(title: "Review", kind: .filled)
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(CardBackground(radius: Tokens.Radius.s, fill: Tokens.Color.surface, stroke: AppColor.tintStroke))
        .accessibilityElement(children: .combine)
    }
}
