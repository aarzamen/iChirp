import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// One generated document from the Transforms tab: the editable text, where it came from (template and version,
/// provider, model, where it ran, privacy class), Copy, Share and Delete (with confirmation).
struct DeliverableDetailScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let id: UUID

    @State private var document: DeliverableDocumentViewModel
    @State private var shareText: ShareText?
    @State private var confirmingDelete = false
    @State private var copied = false
    @State private var deleteError: String?
    /// Plan 022: More → Save as voice message.
    @State private var voiceMessage: VoiceMessageJob?

    init(id: UUID, environment: AppEnvironment) {
        self.id = id
        _document = State(initialValue: environment.makeDocumentViewModel(id: id))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let deliverable = document.deliverable {
                    Text(deliverable.title)
                        .chirpTitleFont(24, .heavy)
                        .foregroundStyle(Tokens.Color.ink)
                        .accessibilityAddTraits(.isHeader)
                    DeliverableMetadataCard(
                        rows: Self.metadata(
                            deliverable, versionNumber: document.templateVersionNumber,
                            sourceTitle: sourceTitle(deliverable)))
                    if deliverable.privacyClass == .clinical {
                        ClinicalDraftNote()
                    }
                    DocumentEditor(document: document)
                        .frame(minHeight: 360)
                    if let error = document.saveError {
                        Text("Couldn’t save your edit: \(error)")
                            .chirpFont(12)
                            .foregroundStyle(AppColor.error)
                    }
                } else if let error = document.loadError {
                    EmptyStateView(title: "Couldn’t open this document", message: error)
                } else if document.isDeleted {
                    EmptyStateView(title: "This document is gone", message: "It may have been deleted.")
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Tokens.Color.ground)
        .voiceReading(environment.voicePlayer, confirmationEnabled: voiceMessage == nil) {
            $0 == .deliverable(id: id)  // plan 020
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // Plan 020: reads the text as edited now.
                ListenToolbarButton(
                    source: .deliverable(id: id), privacyClass: document.deliverable?.privacyClass ?? .clinical
                ) { document.draft }
                Button {
                    LocalPasteboard.copy(document.draft)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Button {
                    shareText = ShareText(text: document.draft)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Menu {
                    Button {
                        voiceMessage = document.deliverable.flatMap {
                            VoiceMessageJob.deliverable($0, text: document.draft)
                        }
                    } label: {
                        Label("Save as voice message", systemImage: "waveform.badge.plus")
                    }
                    Divider()
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("Delete Document", systemImage: "trash")
                    }
                } label: {
                    Label("More options", systemImage: "ellipsis")
                }
            }
        }
        .disabled(document.deliverable == nil && !document.isDeleted && document.loadError == nil)
        .task { await document.load() }
        .sheet(item: $voiceMessage) { job in VoiceMessageSheet(job: job, environment: environment) }
        .sheet(item: $shareText) { item in
            ActivityView(items: [item.text])
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .confirmationDialog("Delete this document?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Document", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The transcript it came from stays.")
        }
        .alert(
            "Couldn’t delete the document",
            isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
    }

    private func sourceTitle(_ deliverable: Deliverable) -> String {
        environment.library.items.first { $0.id == deliverable.transcriptionID }?.displayTitle ?? "A transcript"
    }

    private func delete() async {
        do {
            try await document.delete()
            await environment.deliverableLibrary.load()
            dismiss()
        } catch {
            deleteError = Formatting.message(for: error)
        }
    }

    /// The provenance rows, in reading order.
    static func metadata(_ deliverable: Deliverable, versionNumber: Int?, sourceTitle: String) -> [(String, String)] {
        var rows: [(String, String)] = [("From", sourceTitle)]
        rows.append(("Template", versionNumber.map { "\(deliverable.title) · version \($0)" } ?? deliverable.title))
        rows.append(("Provider", deliverable.provider))
        rows.append(("Model", deliverable.model ?? "Not reported"))
        rows.append(
            ("Ran", ModelPlace.phrase(locality: deliverable.locality, name: deliverable.provider).capitalizedFirst))
        rows.append(("Privacy", deliverable.privacyClass.title))
        rows.append(("Made", Formatting.day(deliverable.createdAt) + " " + Formatting.timeOfDay(deliverable.createdAt)))
        if let edited = deliverable.editedAt {
            rows.append(("Edited", Formatting.day(edited) + " " + Formatting.timeOfDay(edited)))
        }
        return rows
    }
}

/// Label/value rows in a card.
struct DeliverableMetadataCard: View {
    let rows: [(String, String)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Rectangle().fill(AppColor.quietFill).frame(height: 1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(row.0)
                        .chirpFont(13)
                        .foregroundStyle(Tokens.Color.secondary)
                        .frame(width: 76, alignment: .leading)
                    Text(row.1)
                        .chirpFont(13.5, .medium)
                        .foregroundStyle(Tokens.Color.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(CardBackground(radius: Tokens.Radius.m))
    }
}

extension String {
    /// "on this iPhone" → "On this iPhone".
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
