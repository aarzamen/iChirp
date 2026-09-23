import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// A document → Versions (plan 022 Step 4): every text the document has had, newest first, with what made it (the
/// original, your edit, an instruction by voice or typed, a restore) and when. Restore brings an earlier text back as a
/// new version; nothing is ever overwritten or removed.
struct DocumentVersionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
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
        // At accessibility sizes the heading, the Current badge and the time stack instead of squeezing into one line.
        let stacked = typeSize.isAccessibilitySize
        let header =
            stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return VStack(alignment: .leading, spacing: 8) {
            header {
                Text("Version \(version.versionNumber)")
                    .chirpFont(15, .semibold)
                    .foregroundStyle(Tokens.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if isCurrent {
                    Text("Current")
                        .chirpFont(11, .bold)
                        .foregroundStyle(Tokens.Color.privacyBadgeInk)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .frame(minHeight: 20)
                        .background(Capsule().fill(Tokens.Color.privacyBadgeFill))
                }
                if !stacked { Spacer(minLength: 8) }
                Text(Formatting.day(version.createdAt) + " " + Formatting.timeOfDay(version.createdAt))
                    .chirpFont(12)
                    .foregroundStyle(Tokens.Color.secondary)
            }
            Label(Self.origin(version), systemImage: Self.symbol(version.origin))
                .chirpFont(12.5, .semibold)
                .foregroundStyle(AppColor.accentText)
            if let change = Self.changeSummary(version.text, previous: previousText(of: version)) {
                Text(change)
                    .chirpFont(12.5)
                    .foregroundStyle(Tokens.Color.secondary)
                    .accessibilityLabel("Changes from the version before: \(change)")
            }
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
            (stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 10)))
            {
                Button {
                    if isExpanded {
                        expanded.remove(version.versionNumber)
                    } else {
                        expanded.insert(version.versionNumber)
                    }
                } label: {
                    Text(isExpanded ? "Show less" : "Show all")
                        .chirpFont(13, .semibold)
                        .foregroundStyle(AppColor.accentText)
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)  // the hit area (UX audit F29)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    isExpanded
                        ? "Show less of version \(version.versionNumber)"
                        : "Show all of version \(version.versionNumber)")
                if !stacked { Spacer(minLength: 0) }
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

    private func previousText(of version: DeliverableVersion) -> String? {
        model.versions.first { $0.versionNumber == version.versionNumber - 1 }?.text
    }

    /// What changed from the version before, in lines (UX audit F30): "2 lines changed, 1 added", "1 line removed",
    /// "No text changes"; nil for the first version.
    static func changeSummary(_ text: String, previous: String?) -> String? {
        guard let previous else { return nil }
        let difference = text.components(separatedBy: "\n").difference(from: previous.components(separatedBy: "\n"))
        let added = difference.insertions.count
        let removed = difference.removals.count
        let changed = min(added, removed)
        let counts = [(changed, "changed"), (added - changed, "added"), (removed - changed, "removed")]
            .filter { $0.0 > 0 }
        guard let first = counts.first else { return "No text changes" }
        // The first count names the unit ("2 lines changed"); the rest follow it (", 1 added").
        let head = "\(first.0) \(first.0 == 1 ? "line" : "lines") \(first.1)"
        return ([head] + counts.dropFirst().map { "\($0.0) \($0.1)" }).joined(separator: ", ")
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
