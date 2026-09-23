import ChirpCore
import ChirpFeatures
import ChirpIngest
import ChirpUI
import SwiftUI
import UniformTypeIdentifiers

/// The Create sheet's answers while it is open (plan 022 Step 3). Starts from the remembered `CreateChoices`; only
/// the choices are remembered, never the text, link or file.
struct CreateDraft: Equatable {
    var input: CreateInputKind
    var output: CreateChoices.OutputKind
    var templateID: UUID?
    var voiceSummarizeFirst: Bool
    var isClinical: Bool
    var text = ""
    var link = ""
    var file: URL?

    init(choices: CreateChoices) {
        input = choices.input
        output = choices.output
        templateID = choices.templateID
        voiceSummarizeFirst = choices.voiceSummarizeFirst
        isClinical = choices.isClinical
    }

    var choices: CreateChoices {
        CreateChoices(
            input: input, output: output, templateID: templateID, voiceSummarizeFirst: voiceSummarizeFirst,
            isClinical: isClinical)
    }

    /// The chain's input, or nil while it is incomplete.
    var createInput: CreateInput? {
        switch input {
        case .speak: return .speak
        case .text:
            return TextItemService.normalized(text).isEmpty ? nil : .text(text)
        case .link:
            return LinkClassifier.classify(link).isActionable
                ? .link(link.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
        case .file:
            return file.map { .file($0) }
        }
    }

    var request: CreateRequest? {
        guard let input = createInput, let output = choices.createOutput else { return nil }
        return CreateRequest(input: input, output: output, privacyClass: choices.privacyClass)
    }

    /// Typed text or a pasted link that closing the sheet would lose (UX audit F19), whichever input is selected.
    var hasUnsavedInput: Bool {
        DiscardDecision.holdsInput(text) || DiscardDecision.holdsInput(link)
    }
}

/// Whether the sheet can start, and if not, the one sentence that says why (honest states: no model, no voice, no
/// speech model, nothing typed).
enum CreateReadiness {
    static func problem(
        _ draft: CreateDraft,
        speechModelReady: Bool,
        modelProblem: String?,
        voiceProblem: String?
    ) -> String? {
        switch draft.input {
        case .speak where !speechModelReady:
            return "Download the speech model in Settings → Speech to speak."
        case .text where TextItemService.normalized(draft.text).isEmpty:
            return "Type or paste some text."
        case .link:
            let kind = LinkClassifier.classify(draft.link)
            if !kind.isActionable {
                return draft.link.isEmpty ? "Paste a podcast, YouTube or web link." : kind.detail
            }
        case .file where draft.file == nil:
            return "Choose a file."
        default:
            break
        }
        guard let output = draft.choices.createOutput else { return "Choose a template for the document." }
        if output.needsLanguageModel, let modelProblem { return modelProblem }
        if output.needsVoice, let voiceProblem { return voiceProblem }
        return nil
    }

    /// What the run header and the Dictating screen's chip call a chain's output: "Summary", the template's name,
    /// "Voice message of a summary". Create and Capture's recipes use the same words.
    static func outputTitle(for output: CreateOutput, templates: [PromptTemplate]) -> String {
        switch output {
        case .transcript: "Transcript"
        case .summary: "Summary"
        case .document(let id): templates.first { $0.id == id }?.name ?? "Document"
        case .voiceMessage(let summarizeFirst): summarizeFirst ? "Voice message of a summary" : "Voice message"
        }
    }

    /// "Summary", the template's name, "Voice message": what the Dictating screen's chip and the run header call the
    /// output.
    static func outputTitle(_ output: CreateChoices.OutputKind, templateName: String?) -> String {
        switch output {
        case .transcript: "Transcript"
        case .summary: "Summary"
        case .document: templateName ?? "Document"
        case .voiceMessage: "Voice message"
        }
    }
}

/// What the file picker offers: audio, video and every document type Parakeet reads.
@MainActor enum CreateFileTypes {
    static let all: [UTType] = CaptureScreen.importTypes + PasteLinkSheet.documentTypes
}

extension CreateInputKind {
    var title: String {
        switch self {
        case .speak: "Speak"
        case .text: "Type or paste"
        case .link: "Link"
        case .file: "File"
        }
    }

    var subtitle: String {
        switch self {
        case .speak: "Record your voice"
        case .text: "Notes, any text"
        case .link: "Podcast, YouTube, web link"
        case .file: "Audio, video, PDF, Word"
        }
    }

    var systemImage: String {
        switch self {
        case .speak: "waveform"
        case .text: "text.cursor"
        case .link: "link"
        case .file: "doc"
        }
    }
}

extension CreateChoices.OutputKind {
    var title: String {
        switch self {
        case .transcript: "Transcript"
        case .summary: "Summary"
        case .document: "Document"
        case .voiceMessage: "Voice message"
        }
    }

    var subtitle: String {
        switch self {
        case .transcript: "The text itself"
        case .summary: "The key points"
        case .document: "Notes, SOAP, more"
        case .voiceMessage: "An audio file you can send"
        }
    }

    var systemImage: String {
        switch self {
        case .transcript: "text.alignleft"
        case .summary: "list.bullet.rectangle"
        case .document: "doc.richtext"
        case .voiceMessage: "waveform.badge.plus"
        }
    }
}

/// One answer tile in the Create sheet: an icon tile, a title and a short line; the chosen one is tinted and ticked.
/// Title and line wrap to two lines instead of shrinking or cutting off (UX audit F18); the sheet puts the tiles in one
/// column at large text sizes (`CreateOptionTile.columns`).
struct CreateOptionTile: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: Tokens.Radius.iconTile, style: .continuous)
                        .fill(isSelected ? Tokens.Color.accent : AppColor.tintFill)
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : Tokens.Color.accentInk)
                }
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .chirpFont(14.5, .semibold)
                        .foregroundStyle(Tokens.Color.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .chirpFont(11.5)
                        .foregroundStyle(Tokens.Color.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(
                CardBackground(
                    radius: Tokens.Radius.s, fill: isSelected ? AppColor.tintFill : Tokens.Color.surface,
                    stroke: isSelected ? AppColor.tintStrokeSelected : Tokens.Color.border)
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Tokens.Color.accent)
                        .padding(6)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.s, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// Two columns, or one from XX Large text up, so a title never has to be cut off.
    static func columns(for size: DynamicTypeSize) -> Int {
        size >= .xxLarge ? 1 : 2
    }
}

/// A one-line honest note ("Download the speech model…"), quiet by default, red for a hard stop.
struct CreateNote: View {
    let text: String
    var systemImage = "info.circle"
    var isProblem = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(isProblem ? AppColor.error : Tokens.Color.secondary)
                .accessibilityHidden(true)
            Text(text)
                .chirpFont(13)
                .foregroundStyle(Tokens.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground(radius: Tokens.Radius.s, fill: AppColor.quietFill, stroke: .clear))
    }
}

/// On the Dictating screen while a Create chain waits for this dictation: "Then: Summary".
struct CreateNextChip: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .bold))
                .accessibilityHidden(true)
            Text("Then: \(title)")
                .chirpFont(12.5, .semibold)
        }
        .foregroundStyle(Tokens.Color.dictationAccent)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(minHeight: 28)
        .background(Capsule().fill(.white.opacity(0.10)))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("After you stop, Parakeet makes: \(title)")
    }
}
