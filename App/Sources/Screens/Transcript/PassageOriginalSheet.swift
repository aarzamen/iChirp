import ChirpCore
import ChirpFeatures
import ChirpText
import ChirpUI
import SwiftUI

/// Show Original on a corrected line (plan 025 D5): the line as Parakeet heard it, with the corrected words shaded;
/// one row per correction ("Heard: met for men" / "Now: metformin") with Play and Revert; and Revert This Passage.
/// A revert is immediate, with Undo in this sheet's own bar (fix round 1, I1). The line is looked up by id in the
/// transcript as it is now (I2), so a partial revert never leaves a stale line; when the line has no corrections left
/// the sheet closes and hands its Undo to the screen.
struct PassageOriginalSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: TranscriptViewModel
    let lineID: Int
    let player: AudioPlayerModel
    /// Takes the Undo when the sheet closes because nothing is left to show.
    let handOff: (CorrectionUndoOffer) -> Void

    @State private var undo = CorrectionUndoController()

    /// One corrected line and its corrections, as the transcript is now.
    struct Passage {
        let line: TranscriptTextLine
        let corrections: [TranscriptCorrection]
    }

    /// Line `lineID` of `heard` with its corrections; nil when the line is gone or has none.
    static func passage(lineID: Int, in heard: TranscriptText?) -> Passage? {
        guard let heard, let line = heard.lines.first(where: { $0.id == lineID }) else { return nil }
        let ids = Set(heard.tokens[line.tokenRange].compactMap(\.editID))
        let corrections = heard.edits.filter { ids.contains($0.id) }
        return corrections.isEmpty ? nil : Passage(line: line, corrections: corrections)
    }

    var body: some View {
        let passage = Self.passage(lineID: lineID, in: model.heard)
        let tokens = model.heard?.tokens ?? []
        NavigationStack {
            ScrollView {
                if let passage {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                        SectionLabel("As heard")
                        Text(Self.heardLine(passage.line, tokens: tokens, corrections: passage.corrections))
                            .chirpFont(16)
                            .lineSpacing(6)
                            .foregroundStyle(Tokens.Color.ink)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .chirpCard(radius: Tokens.Radius.m, padding: Tokens.Spacing.m)
                        SectionLabel(passage.corrections.count == 1 ? "Your correction" : "Your corrections")
                            .padding(.top, Tokens.Spacing.xs)
                        ForEach(passage.corrections) { correction in
                            row(correction, tokens: tokens)
                        }
                    }
                    .padding(.horizontal, Tokens.Spacing.sheetGutter)
                    .padding(.vertical, Tokens.Spacing.s)
                }
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
                VStack(spacing: 0) {
                    CorrectionUndoBar(controller: undo, model: model)
                    if let passage {
                        ChirpBottomBar {
                            Button("Revert This Passage") {
                                let ids = Set(passage.corrections.map(\.id))
                                Task { await undo.revert(ids, model: model) }
                            }
                            .buttonStyle(.chirp(.destructive))
                            .accessibilityHint("Puts back the words Parakeet heard for this passage; you can undo it")
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onChange(of: passage == nil, initial: true) { _, isGone in
            guard isGone else { return }
            if let offer = undo.offer { handOff(offer) }
            dismiss()
        }
    }

    private func row(_ correction: TranscriptCorrection, tokens: [TranscriptToken]) -> some View {
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
                    Task { await undo.revert([correction.id], model: model) }
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
