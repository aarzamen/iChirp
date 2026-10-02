// Semantics from MacParakeet (GPL-3.0): Sources/MacParakeet/Views/Transcription/TranscriptResultView.swift
// (TimedTranscriptTextEditSheet, :6079-6179) @ bbae9e0e. Fresh SwiftUI for iPhone.

import ChirpCore
import ChirpFeatures
import ChirpText
import ChirpUI
import SwiftUI

/// Correct… on a transcript line (plan 025 D5): the line's text in an editor, its speaker and time, Play passage, and
/// Save, which stores the person's words as corrections of the words as heard (they stay: Show Original brings them
/// back). Save is off while the text is blank or unchanged; a failed save keeps the draft and says why; Cancel asks
/// before discarding an edit, and swipe-down is off while there is one.
struct CorrectPassageSheet: View {
    @Environment(\.dismiss) private var dismiss
    let line: TranscriptTextLine
    let speakerLabel: String?
    let player: AudioPlayerModel
    /// Saves the text; throws to keep the sheet open with the draft.
    let save: (String) async throws -> Void

    @State private var draft: CorrectionDraft
    @State private var isSaving = false
    @State private var error: String?
    @State private var isConfirmingDiscard = false
    @FocusState private var editorFocused: Bool

    init(
        line: TranscriptTextLine, speakerLabel: String?, player: AudioPlayerModel,
        save: @escaping (String) async throws -> Void
    ) {
        self.line = line
        self.speakerLabel = speakerLabel
        self.player = player
        self.save = save
        _draft = State(initialValue: CorrectionDraft(original: line.text))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    HStack(alignment: .center, spacing: Tokens.Spacing.s) {
                        Text(
                            TranscriptCorrectionsCopy.passageLine(
                                speaker: speakerLabel, startMs: line.startMs ?? 0, endMs: line.endMs ?? 0)
                        )
                        .chirpFont(13.5, .semibold)
                        .monospacedDigit()
                        .foregroundStyle(Tokens.Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if player.isAvailable {
                            playButton
                        }
                    }
                    editor
                    if let error {
                        Text(error)
                            .chirpFont(13)
                            .foregroundStyle(AppColor.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(TranscriptCorrectionsCopy.correctFooter)
                        .chirpFont(12.5)
                        .foregroundStyle(Tokens.Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Tokens.Spacing.sheetGutter)
                .padding(.top, Tokens.Spacing.xs)
                .padding(.bottom, Tokens.Spacing.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Tokens.Color.ground)
            .navigationTitle("Correct passage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        switch DiscardDecision.onCancel(hasInput: draft.hasChanges) {
                        case .close: close()
                        case .ask: isConfirmingDiscard = true
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { Task { await saveDraft() } }
                        .bold()
                        .disabled(isSaving || !draft.canSave)
                }
            }
        }
        .discardInputConfirmation(
            "Discard your changes?", message: "The passage keeps its current words.",
            hasInput: draft.hasChanges && !isSaving, isAsking: $isConfirmingDiscard
        ) { close() }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear { editorFocused = true }
    }

    private var editor: some View {
        TextEditor(text: $draft.text)
            .chirpFont(17)
            .foregroundStyle(Tokens.Color.ink)
            .scrollContentBackground(.hidden)
            .focused($editorFocused)
            .frame(minHeight: 180)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(ChirpCardBackground(radius: Tokens.Radius.m))
            .accessibilityLabel("Passage")
            .accessibilityHint("Edit the words Parakeet misheard")
    }

    /// Plays the passage from its start on the screen's player (the sheet covers the player bar); Pause stops it.
    private var playButton: some View {
        Button {
            if player.isPlaying {
                player.pause()
            } else {
                player.seek(to: TimeInterval(line.startMs ?? 0) / 1000)
                player.play()
            }
        } label: {
            Label(
                player.isPlaying ? "Pause" : "Play passage",
                systemImage: player.isPlaying ? "pause.fill" : "play.fill")
        }
        .buttonStyle(.chirp(.tinted, size: .compact))
        .accessibilityHint(player.isPlaying ? "Pauses the recording" : "Plays this passage from its start")
    }

    private func close() {
        player.pause()
        dismiss()
    }

    private func saveDraft() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await save(draft.text)
            close()
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? Formatting.message(for: error)
            self.error = "\(TranscriptCorrectionsCopy.saveFailed) \(reason)"
            AccessibilityNotification.Announcement(TranscriptCorrectionsCopy.saveFailed).post()
        }
    }
}
