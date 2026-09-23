import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// A document → Versions (plan 022 Step 4): every text the document has had, newest first, with what made it (the
/// original, your edit, an instruction by voice or typed, a restore) and when. Restore brings an earlier text back as a
/// new version; nothing is ever overwritten or removed.
struct DocumentVersionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onRestored: () -> Void

    @State private var model: DocumentVersionsViewModel
    @State private var expanded: Set<Int> = []

    init(model: DocumentVersionsViewModel, onRestored: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.onRestored = onRestored
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Every text this document has had. Restoring adds the old text as the newest version.")
                        .chirpFont(13)
                        .foregroundStyle(Tokens.Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.versions.isEmpty {
                        EmptyStateView(
                            title: "No versions yet",
                            message: "Edit by voice keeps the current text as version 1 before its first change."
                        )
                        .background(CardBackground(radius: Tokens.Radius.s))
                    } else if model.currentVersionNumber == nil {
                        CreateNote(
                            text: "The document has edits you typed since the newest version. They become a version "
                                + "at the next change.",
                            systemImage: "pencil")
                    }
                    ForEach(model.newestFirst) { version in
                        row(version)
                    }
                    if let error = model.error {
                        Text(error)
                            .chirpFont(13)
                            .foregroundStyle(AppColor.error)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Tokens.Color.ground)
            .navigationTitle("Versions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task { await model.load() }
    }

    private func row(_ version: DeliverableVersion) -> some View {
        let isCurrent = model.currentVersionNumber == version.versionNumber
        let isExpanded = expanded.contains(version.versionNumber)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Version \(version.versionNumber)")
                    .chirpFont(15, .semibold)
                    .foregroundStyle(Tokens.Color.ink)
                if isCurrent {
                    Text("Current")
                        .chirpFont(11, .bold)
                        .foregroundStyle(Tokens.Color.privacyBadgeInk)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 20)
                        .background(Capsule().fill(Tokens.Color.privacyBadgeFill))
                }
                Spacer(minLength: 8)
                Text(Formatting.day(version.createdAt) + " " + Formatting.timeOfDay(version.createdAt))
                    .chirpFont(12)
                    .foregroundStyle(Tokens.Color.secondary)
            }
            Label(Self.origin(version), systemImage: Self.symbol(version.origin))
                .chirpFont(12.5, .semibold)
                .foregroundStyle(AppColor.accentText)
            if let instruction = version.instruction {
                Text("“\(instruction)”")
                    .chirpFont(13.5)
                    .italic()
                    .foregroundStyle(Tokens.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(version.text)
                .chirpFont(13.5)
                .foregroundStyle(Tokens.Color.secondary)
                .lineLimit(isExpanded ? nil : 3)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                Button(isExpanded ? "Show less" : "Show all") {
                    if isExpanded {
                        expanded.remove(version.versionNumber)
                    } else {
                        expanded.insert(version.versionNumber)
                    }
                }
                .chirpFont(13, .semibold)
                .foregroundStyle(AppColor.accentText)
                .frame(minHeight: 32)
                Spacer(minLength: 0)
                if !isCurrent {
                    Button {
                        Task {
                            if await model.restore(version) != nil { onRestored() }
                        }
                    } label: {
                        CapsuleButtonLabel(title: "Restore", kind: .tinted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Restore version \(version.versionNumber)")
                }
            }
        }
        .padding(14)
        .background(
            CardBackground(
                radius: Tokens.Radius.m, fill: Tokens.Color.surface,
                stroke: isCurrent ? AppColor.tintStrokeSelected : Tokens.Color.border))
    }

    /// "Original", "Your edit", "By voice · on this iPhone", "Typed instruction · Claude", "Restored version 1".
    static func origin(_ version: DeliverableVersion) -> String {
        let place = version.locality.map { ModelPlace.phrase(locality: $0, name: version.provider ?? "") }
        switch version.origin {
        case .original: return "Original"
        case .handEdit: return "Your edit"
        case .spokenEdit: return ["Edited by voice", place].compactMap { $0 }.joined(separator: " · ")
        case .typedEdit: return ["Edited from a typed instruction", place].compactMap { $0 }.joined(separator: " · ")
        case .restore: return version.restoredFrom.map { "Restored version \($0)" } ?? "Restored"
        }
    }

    static func symbol(_ origin: DeliverableVersion.Origin) -> String {
        switch origin {
        case .original: "doc"
        case .handEdit: "pencil"
        case .spokenEdit: "mic.fill"
        case .typedEdit: "keyboard"
        case .restore: "arrow.uturn.backward"
        }
    }
}
