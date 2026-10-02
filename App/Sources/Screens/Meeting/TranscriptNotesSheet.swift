import ChirpCore
import ChirpFeatures
import ChirpText
import ChirpUI
import SwiftUI

/// The Transcript's Notes tab (M3), shown as a sheet: the person's notes (typed during a meeting or later) and the
/// speaker names ("Speaker 1" → a name). Renaming changes every paragraph label in the transcript.
///
/// The notes save as you type (UX audit F59). Done writes anything still pending; a swipe-down waits until the last
/// edit is stored, and the sheet writes once more as it goes. If a write fails, the alert offers to close without
/// saving, the only way typed notes are dropped.
struct TranscriptNotesSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Made on the first render and kept (R6a-5): the sheet's parent re-renders ten times a second while media plays.
    @State private var box = OnceBox<TranscriptNotesViewModel>()
    @State private var renaming: SpeakerInfo?
    @State private var newName = ""
    let id: UUID
    let store: any TranscriptionStoring

    init(id: UUID, store: any TranscriptionStoring) {
        self.id = id
        self.store = store
    }

    private var model: TranscriptNotesViewModel {
        box.get { TranscriptNotesViewModel(id: id, store: store) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    notesSection
                    speakersSection
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Tokens.Color.ground)
            .navigationTitle("Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // "Done": the notes are kept (F95).
                    Button("Done") {
                        Task {
                            if await model.flush() { dismiss() }
                        }
                    }
                }
            }
            .task { await model.load() }
        }
        // A swipe-down never drops an edit that is not stored yet (F59); Done always works.
        .interactiveDismissDisabled(model.hasUnsavedNotes || model.isSaving)
        .onDisappear {
            let model = model
            Task { await model.flush() }
        }
        .alert("Rename speaker", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let speaker = renaming {
                    Task { await model.rename(speakerId: speaker.id, to: newName) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The name replaces “\(renaming?.label ?? "")” everywhere in this transcript.")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.dismissError() } })
        ) {
            if model.loadFailed {
                // Review R5-8: the notes were not read, so the editor stays off until they are.
                Button("Retry") { Task { await model.load() } }
                Button("Close", role: .cancel) { dismiss() }
            } else if model.hasUnsavedNotes {
                Button("Keep editing", role: .cancel) {}
                Button("Close without saving", role: .destructive) {
                    model.discardUnsavedNotes()
                    dismiss()
                }
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    private var notesSection: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Your notes", size: 12.5)
            TextEditor(text: $model.notes)
                .chirpFont(15)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 200)
                .padding(10)
                .background(ChirpCardBackground(radius: Tokens.Radius.s))
                .overlay(alignment: .topLeading) {
                    if model.notes.isEmpty && model.hasLoaded {
                        // The shared placeholder (R7-3): text-safe, the same color as every field's.
                        ChirpPlaceholder("Agenda, decisions, action items…")
                            .chirpFont(15)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 18)
                    }
                }
                .accessibilityLabel("Notes")
                // Review R5-8: nothing can be typed (or autosaved over the stored notes) before they were read.
                .disabled(!model.hasLoaded)
            Text("Saves as you type, with this transcript on this iPhone.")
                .chirpFont(12)
                .foregroundStyle(Tokens.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var speakersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Speakers", size: 12.5)
            if model.speakers.isEmpty {
                Text(
                    model.transcription?.status == .completed
                        ? "No speakers were identified in this recording (Settings → Speech → Speaker labels)."
                        : "Speakers appear when the transcript is ready."
                )
                .chirpFont(13.5)
                .foregroundStyle(Tokens.Color.secondary)
            } else {
                // R6a-18: the transcript's colors (by first speech), not the roster's order.
                let colors = SpeakerPalette.indices(
                    roster: model.speakers.map(\.id),
                    speechOrder: SpeakerPalette.order(
                        model.transcription.map { TranscriptTokens.of($0).map(\.speakerId) } ?? []))
                VStack(spacing: 0) {
                    ForEach(Array(model.speakers.enumerated()), id: \.element.id) { index, speaker in
                        Button {
                            newName = speaker.label
                            renaming = speaker
                        } label: {
                            HStack(spacing: 10) {
                                SpeakerDot(label: speaker.label, speakerIndex: colors[speaker.id] ?? index)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Text("Rename")
                                    .chirpFont(13.5, .semibold)
                                    .foregroundStyle(AppColor.accentText)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Rename \(speaker.label)")
                        if index < model.speakers.count - 1 {
                            Rectangle().fill(Tokens.Color.border).frame(height: 1).padding(.leading, 14)
                        }
                    }
                }
                .background(ChirpCardBackground(radius: Tokens.Radius.s))
            }
        }
    }
}
