import ChirpCore
import ChirpFeatures
import ChirpText
import ChirpUI
import SwiftUI

/// Show Original on a corrected line (plan 025 D5): the line as Parakeet heard it, with the corrected words shaded;
/// one row per correction ("Heard: met for men" / "Now: metformin") with Play and Revert; and Revert This Passage.
/// A revert is immediate; the screen offers Undo.
struct PassageOriginalSheet: View {
    @Environment(\.dismiss) private var dismiss
    let line: TranscriptTextLine
    let tokens: [TranscriptToken]
    let corrections: [TranscriptCorrection]
    let player: AudioPlayerModel
    let revert: (Set<UUID>) async -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    SectionLabel("As heard")
                    Text(Self.heardLine(line, tokens: tokens, corrections: corrections))
                        .chirpFont(16)
                        .lineSpacing(6)
                        .foregroundStyle(Tokens.Color.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .chirpCard(radius: Tokens.Radius.m, padding: Tokens.Spacing.m)
                    SectionLabel(corrections.count == 1 ? "Your correction" : "Your corrections")
                        .padding(.top, Tokens.Spacing.xs)
                    ForEach(corrections) { correction in
                        row(correction)
                    }
                }
                .padding(.horizontal, Tokens.Spacing.sheetGutter)
                .padding(.vertical, Tokens.Spacing.s)
            }
            .background(Tokens.Color.ground)
            .navigationTitle("Original")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ChirpBottomBar {
                    Button("Revert This Passage") {
                        let ids = Set(corrections.map(\.id))
                        Task {
                            await revert(ids)
                            dismiss()
                        }
                    }
                    .buttonStyle(.chirp(.destructive))
                    .accessibilityHint("Puts back the words Parakeet heard for this passage; you can undo it")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ correction: TranscriptCorrection) -> some View {
        let token = tokens.first { $0.editID == correction.id }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Heard: \(correction.heard)")
                .chirpFont(14.5)
                .foregroundStyle(Tokens.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Now: \(correction.text)")
                .chirpFont(14.5, .semibold)
                .foregroundStyle(Tokens.Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            ChirpButtonRow {
                if player.isAvailable, let token {
                    Button {
                        player.seek(to: TimeInterval(token.startMs) / 1000)
                        player.play()
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.chirp(.tinted, size: .compact))
                    .accessibilityLabel("Play \(Formatting.clock(ms: token.startMs))")
                }
                Button("Revert") {
                    Task {
                        await revert([correction.id])
                        if corrections.count == 1 { dismiss() }
                    }
                }
                .buttonStyle(.chirp(.quiet, size: .compact))
                .accessibilityLabel("Revert to \(correction.heard)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chirpCard(radius: Tokens.Radius.m, padding: Tokens.Spacing.m)
        .accessibilityElement(children: .contain)
    }

    /// The line as heard: each corrected passage shows its heard words, shaded; everything else is the engine's words.
    static func heardLine(
        _ line: TranscriptTextLine, tokens: [TranscriptToken], corrections: [TranscriptCorrection]
    ) -> AttributedString {
        var result = AttributedString()
        for index in line.tokenRange where tokens.indices.contains(index) {
            let token = tokens[index]
            if !result.characters.isEmpty { result += AttributedString(" ") }
            if let editID = token.editID, let correction = corrections.first(where: { $0.id == editID }) {
                var heard = AttributedString(correction.heard)
                heard.backgroundColor = AppColor.tintFill
                result += heard
            } else {
                result += AttributedString(token.text)
            }
        }
        return result
    }
}
