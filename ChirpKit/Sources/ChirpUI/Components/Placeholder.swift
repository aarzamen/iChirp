import SwiftUI

// One placeholder style for every text field and text editor (R7-3, plan 024 Task 11). The system placeholder grey is
// 1.72:1 on white and 2.47:1 on the dark surface (a cool grey in the warm palette), and the app had a second,
// text-safe treatment for its `TextEditor` overlays. Both now read `Tokens.Color.placeholder` (the `secondary` values:
// 4.5:1 or more on every field background in all four appearances, measured in `ContrastTests`).

extension Text {
    /// A text-field prompt in the placeholder color: `TextField(text: $x, prompt: .chirpPlaceholder("Search…"))`,
    /// or `SecureField(text:prompt:)`. iOS honours a prompt's own foreground style.
    public static func chirpPlaceholder(_ placeholder: String) -> Text {
        Text(placeholder).foregroundStyle(Tokens.Color.placeholder)
    }
}

/// A `TextField` whose placeholder is text-safe in every appearance, with `ink` text. Use it wherever the app wrote
/// `TextField("…", text: $x)`; modifiers (`.focused`, `.submitLabel`, `.lineLimit`, a font) apply as before.
///
/// ```swift
/// ChirpTextField("Search titles, text and speakers", text: $library.searchText)
/// ChirpTextField("Ask about this transcript", text: $question, axis: .vertical).lineLimit(1...4)
/// ```
public struct ChirpTextField: View {
    private let placeholder: String
    @Binding private var text: String
    private let axis: Axis

    public init(_ placeholder: String, text: Binding<String>, axis: Axis = .horizontal) {
        self.placeholder = placeholder
        _text = text
        self.axis = axis
    }

    public var body: some View {
        // The label is the placeholder: VoiceOver names the field by it, as it did with `TextField("…", text:)`.
        TextField(text: $text, prompt: .chirpPlaceholder(placeholder), axis: axis) {
            Text(placeholder)
        }
        .foregroundStyle(Tokens.Color.ink)
    }
}

/// The placeholder drawn over an empty `TextEditor` (which has no prompt of its own): the same color as
/// `ChirpTextField`'s, hidden from VoiceOver (label the editor itself) and never in the way of a tap.
///
/// ```swift
/// TextEditor(text: $notes)
///     .overlay(alignment: .topLeading) {
///         if notes.isEmpty { ChirpPlaceholder("Agenda, decisions, action items…").padding(…) }
///     }
/// ```
public struct ChirpPlaceholder: View {
    private let placeholder: String

    public init(_ placeholder: String) {
        self.placeholder = placeholder
    }

    public var body: some View {
        Text(placeholder)
            .foregroundStyle(Tokens.Color.placeholder)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

#Preview("Placeholders") {
    @Previewable @State var search = ""
    @Previewable @State var notes = ""
    VStack(spacing: Tokens.Spacing.m) {
        ChirpTextField("Search titles, text and speakers", text: $search)
            .padding(.horizontal, Tokens.Spacing.s)
            .frame(minHeight: Tokens.Metric.minTapTarget)
            .background(ChirpCardBackground(radius: Tokens.Radius.cover))
        TextEditor(text: $notes)
            .scrollContentBackground(.hidden)
            .frame(height: 120)
            .overlay(alignment: .topLeading) {
                if notes.isEmpty {
                    ChirpPlaceholder("Agenda, decisions, action items…")
                        .padding(.horizontal, 5)
                        .padding(.vertical, Tokens.Spacing.xs)
                }
            }
            .padding(Tokens.Spacing.xs)
            .background(ChirpCardBackground(radius: Tokens.Radius.s))
    }
    .padding(Tokens.Spacing.xl)
    .background(Tokens.Color.ground)
}
