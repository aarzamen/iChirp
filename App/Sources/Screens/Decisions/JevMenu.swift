import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// When the Transcript shows the Jev menu and whether its items run (M6a, plan 021).
enum JevMenuPolicy {
    /// Hidden while Jev is off in Settings, and until the transcript has text.
    static func isVisible(jevEnabled: Bool, status: Transcription.Status?) -> Bool {
        jevEnabled && status == .completed
    }

    /// Clinical items never go to Jev: the items stay visible but disabled, with this caption.
    static func blockedCaption(for privacyClass: PrivacyClass) -> String? {
        privacyClass == .clinical ? DecisionRunViewModel.clinicalBlockedMessage : nil
    }

    static func itemsEnabled(for privacyClass: PrivacyClass) -> Bool {
        blockedCaption(for: privacyClass) == nil
    }
}

/// The Transcript toolbar's "Jev" menu: Classify recording, Suggest a template, Tag paragraphs.
struct JevMenu: View {
    let privacyClass: PrivacyClass
    let run: (DecisionRecipe) -> Void

    var body: some View {
        Menu {
            if let caption = JevMenuPolicy.blockedCaption(for: privacyClass) {
                Section(caption) { items(enabled: false) }
            } else {
                Section("Asks Jev, on TypeSafe's servers") { items(enabled: true) }
            }
        } label: {
            Text("Jev")
                .chirpFont(15, .semibold)
                .foregroundStyle(Tokens.Color.ink)
        }
        .accessibilityLabel("Jev")
        .accessibilityHint(
            JevMenuPolicy.blockedCaption(for: privacyClass) ?? "Classify, suggest a template or tag paragraphs")
    }

    @ViewBuilder private func items(enabled: Bool) -> some View {
        ForEach(DecisionRecipe.allCases) { recipe in
            Button {
                run(recipe)
            } label: {
                Label(recipe.title, systemImage: Self.systemImage(recipe))
            }
            .disabled(!enabled)
        }
    }

    static func systemImage(_ recipe: DecisionRecipe) -> String {
        switch recipe {
        case .recordingKind: "tag"
        case .templateSuggestion: "doc.text.magnifyingglass"
        case .paragraphTags: "text.badge.checkmark"
        }
    }
}

/// A paragraph's Jev tag on the Transcript (this session only; never saved).
struct ParagraphTagChip: View {
    let title: String

    var body: some View {
        Text(title)
            .chirpFont(11.5, .bold)
            .foregroundStyle(AppColor.accentText)
            .padding(.horizontal, 8)
            .frame(minHeight: 22)
            .background(Capsule().fill(AppColor.tintFill))
            .accessibilityLabel("Jev tag: \(title)")
    }
}
