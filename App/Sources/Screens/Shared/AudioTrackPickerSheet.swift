import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// "Which audio track?" for a file with two or more audio tracks (M1.5 Step 4). Nothing is imported until the person
/// taps a track; Cancel drops the whole import. Swipe-to-dismiss is off so the choice is always explicit.
/// Contract: `spec/contracts/file-transcription-audio-tracks-v1.md`.
struct AudioTrackPickerSheet: View {
    let request: TranscriptionJobCenter.AudioTrackSelectionRequest
    let onChoose: (Int) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose an audio track")
                    .chirpTitleFont(22)
                    .foregroundStyle(Tokens.Color.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(Self.message(for: request))
                    .chirpFont(14.5)
                    .foregroundStyle(Tokens.Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            ScrollView {
                VStack(spacing: 9) {
                    ForEach(request.tracks) { track in
                        Button {
                            onChoose(track.ordinal)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "waveform")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(AppColor.accentText)
                                    .accessibilityHidden(true)
                                Text(track.displayName)
                                    .chirpFont(15.5, .semibold)
                                    .foregroundStyle(Tokens.Color.ink)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Tokens.Color.secondary)
                                    .accessibilityHidden(true)
                            }
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                            .background(CardBackground(radius: Tokens.Radius.s))
                            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.s, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Transcribes this track")
                    }
                }
                .padding(.horizontal, 24)
            }

            Button(action: onCancel) {
                Text("Cancel import")
                    .chirpFont(16, .semibold)
                    .foregroundStyle(AppColor.accentText)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(
                        RoundedRectangle(cornerRadius: Tokens.Radius.s, style: .continuous)
                            .fill(AppColor.tintFill))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Tokens.Color.ground)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(true)
    }

    /// Why the person is being asked, in one or two sentences.
    static func message(for request: TranscriptionJobCenter.AudioTrackSelectionRequest) -> String {
        let count = request.tracks.count
        let file = "“\(request.fileName)” has \(count) audio tracks. Parakeet transcribes one."
        guard request.isBatch else { return file }
        return file + " Your choice applies to every file in this import that has more than one track; the others "
            + "use their only track."
    }
}
