import ChirpCore
import ChirpFeatures
import ChirpText
import ChirpUI
import SwiftUI

/// More → Corrections (plan 025 D5): every correction in time order with where it came from, Revert per row (a Replace
/// all or one dictation's voice commands as one group), Revert All… with a question, and the corrections kept from an
/// earlier transcript of this audio (never applied) with Copy Text and Delete…. A revert's Undo and any error show in
/// this sheet's own bottom bar (fix round 1, I1).
struct CorrectionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: TranscriptViewModel

    @State private var undo = CorrectionUndoController()

    @State private var isConfirmingRevertAll = false
    @State private var detachedToDelete: TranscriptCorrection?
    @State private var copiedID: UUID?

    /// A row: one correction, or a group made together (Replace all, one dictation's voice commands).
    struct Group: Identifiable {
        let items: [TranscriptCorrection]
        var id: UUID { items[0].id }
    }

    /// Corrections in time order, consecutive ones that share a batch with more than one item grouped.
    static func groups(_ corrections: [TranscriptCorrection]) -> [Group] {
        var counts: [UUID: Int] = [:]
        for item in corrections { if let batch = item.batchID { counts[batch, default: 0] += 1 } }
        var result: [Group] = []
        var seen = Set<UUID>()
        for item in corrections {
            if let batch = item.batchID, (counts[batch] ?? 0) > 1 {
                guard seen.insert(batch).inserted else { continue }
                result.append(Group(items: corrections.filter { $0.batchID == batch }))
            } else {
                result.append(Group(items: [item]))
            }
        }
        return result
    }

    var body: some View {
        let corrections = model.corrections
        let detached = model.detachedCorrections
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    if corrections.isEmpty {
                        Text("No corrections. The transcript shows the words Parakeet heard.")
                            .chirpFont(14)
                            .foregroundStyle(Tokens.Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Self.groups(corrections)) { group in
                        row(group)
                    }
                    if !corrections.isEmpty {
                        Text(TranscriptCorrectionsCopy.documentsFooter)
                            .chirpFont(12.5)
                            .foregroundStyle(Tokens.Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !detached.isEmpty {
                        SectionLabel("From an earlier transcript of this audio")
                            .padding(.top, Tokens.Spacing.s)
                        Text(
                            "The words changed when this audio was transcribed again, so these are kept but not applied."
                        )
                        .chirpFont(12.5)
                        .foregroundStyle(Tokens.Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        ForEach(detached) { item in detachedRow(item) }
                    }
                }
                .padding(.horizontal, Tokens.Spacing.sheetGutter)
                .padding(.vertical, Tokens.Spacing.s)
            }
            .background(Tokens.Color.ground)
            .navigationTitle("Corrections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    CorrectionUndoBar(controller: undo, model: model)
                    if !corrections.isEmpty {
                        ChirpBottomBar {
                            Button("Revert All…") { isConfirmingRevertAll = true }
                                .buttonStyle(.chirp(.destructive))
                                .accessibilityHint("Asks first; puts back every word Parakeet heard")
                        }
                    }
                }
            }
            .confirmationDialog(
                TranscriptCorrectionsCopy.revertAllTitle(count: corrections.count),
                isPresented: $isConfirmingRevertAll, titleVisibility: .visible
            ) {
                Button(TranscriptCorrectionsCopy.revertAllButton(count: corrections.count), role: .destructive) {
                    Task { await undo.revertAll(model: model) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(TranscriptCorrectionsCopy.revertAllMessage)
            }
            .confirmationDialog(
                "Delete this earlier correction?",
                isPresented: Binding(
                    get: { detachedToDelete != nil }, set: { if !$0 { detachedToDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    guard let item = detachedToDelete else { return }
                    Task { await undo.deleteDetached([item.id], model: model) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It is not applied to this transcript. This can’t be undone.")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ group: Group) -> some View {
        let first = group.items[0]
        let start = model.heard?.tokens.first { $0.editID == first.id }?.startMs
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Tokens.Spacing.xs) {
                if let start {
                    Text(Formatting.clock(ms: start))
                        .chirpFont(12, .semibold)
                        .monospacedDigit()
                        .foregroundStyle(Tokens.Color.secondary)
                }
                Text(TranscriptCorrectionsCopy.originTitle(first.origin, batchCount: group.items.count))
                    .chirpFont(12, .semibold)
                    .foregroundStyle(Tokens.Color.secondary)
            }
            ForEach(group.items.prefix(3)) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Heard: \(item.heard)")
                        .chirpFont(14)
                        .foregroundStyle(Tokens.Color.secondary)
                        .lineLimit(3)
                    Text("Now: \(item.text)")
                        .chirpFont(14, .semibold)
                        .foregroundStyle(Tokens.Color.ink)
                        .lineLimit(3)
                }
            }
            if group.items.count > 3 {
                Text("and \(group.items.count - 3) more")
                    .chirpFont(12.5)
                    .foregroundStyle(Tokens.Color.secondary)
            }
            Button(group.items.count == 1 ? "Revert" : "Revert these \(group.items.count)") {
                Task { await undo.revert(Set(group.items.map(\.id)), model: model) }
            }
            .buttonStyle(.chirp(.quiet, size: .compact))
            .accessibilityLabel(
                group.items.count == 1 ? "Revert to \(first.heard)" : "Revert these \(group.items.count) corrections")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chirpCard(radius: Tokens.Radius.m, padding: Tokens.Spacing.m)
        .accessibilityElement(children: .contain)
    }

    private func detachedRow(_ item: TranscriptCorrection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Heard then: \(item.heard)")
                .chirpFont(14)
                .foregroundStyle(Tokens.Color.secondary)
                .lineLimit(3)
            Text("Your text: \(item.text)")
                .chirpFont(14, .semibold)
                .foregroundStyle(Tokens.Color.ink)
                .lineLimit(4)
            ChirpButtonRow {
                Button(copiedID == item.id ? "Copied" : "Copy Text") {
                    ItemCopy.copy(item.text)
                    copiedID = item.id
                }
                .buttonStyle(.chirp(.tinted, size: .compact))
                Button("Delete…") { detachedToDelete = item }
                    .buttonStyle(.chirp(.destructive, size: .compact))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chirpCard(radius: Tokens.Radius.m, padding: Tokens.Spacing.m)
        .accessibilityElement(children: .contain)
    }
}
