import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// The Transcript's Notes tab (M3), shown as a sheet: the person's notes (typed during a meeting or later) and the
/// speaker names ("Speaker 1" → a name). Renaming changes every paragraph label in the transcript.
struct TranscriptNotesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: TranscriptNotesViewModel
    @State private var renaming: SpeakerInfo?
    @State private var newName = ""

    init(id: UUID, store: any TranscriptionStoring) {
        _model = State(initialValue: TranscriptNotesViewModel(id: id, store: store))
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
                    Button("Done") {
                        Task {
                            if model.hasUnsavedNotes { await model.save() }
                            if model.lastError == nil { dismiss() }
                        }
                    }
                    .disabled(model.isSaving)
                }
            }
            .task { await model.load() }
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
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Your notes", size: 12.5)
            TextEditor(text: $model.notes)
                .chirpFont(15)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 200)
                .padding(10)
                .background(CardBackground(radius: Tokens.Radius.s))
                .overlay(alignment: .topLeading) {
                    if model.notes.isEmpty && model.hasLoaded {
                        Text("Agenda, decisions, action items…")
                            .chirpFont(15)
                            .foregroundStyle(Tokens.Color.mutedText)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 18)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Notes")
            Text("Stored with this transcript on this iPhone. Done saves them.")
                .chirpFont(12)
                .foregroundStyle(Tokens.Color.secondary)
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
                VStack(spacing: 0) {
                    ForEach(Array(model.speakers.enumerated()), id: \.element.id) { index, speaker in
                        Button {
                            newName = speaker.label
                            renaming = speaker
                        } label: {
                            HStack(spacing: 10) {
                                SpeakerDot(label: speaker.label, speakerIndex: index)
                                Spacer(minLength: 8)
                                Text("Rename")
                                    .chirpFont(13.5, .semibold)
                                    .foregroundStyle(AppColor.accentText)
                            }
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
                .background(CardBackground(radius: Tokens.Radius.s))
            }
        }
    }
}
