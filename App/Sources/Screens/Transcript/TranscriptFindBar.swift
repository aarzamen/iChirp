// Semantics from MacParakeet (GPL-3.0): Sources/MacParakeet/Views/Transcription/TranscriptFindBar.swift @ bbae9e0e.
// iPhone bottom bar with Replace; fresh SwiftUI.

import ChirpCore
import ChirpFeatures
import ChirpText
import ChirpUI
import SwiftUI

/// Find in transcript (plan 025 Part B, D4/D5): a bottom bar that takes the place of Copy / Share / Listen / Transform
/// while it is open, above the keyboard. The field ("Find in transcript", Return goes to the next match, Esc clears the
/// query and then closes), the counter ("3 of 12", "No matches"), Previous / Next and Done; then Play from the current
/// match's time (when the transcript has audio and timings) and Show Replace; then the Replace row ("Replace with",
/// Replace, Replace All), or why Replace cannot run. One row per group when it fits, more rows at accessibility sizes
/// (`ViewThatFits`); every button keeps a 44 pt target. It owns no search: the screen feeds `TranscriptFindModel`.
struct TranscriptFindBar: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var query: String
    @Binding var replacement: String
    @Binding var showsReplace: Bool
    var isFocused: FocusState<Bool>.Binding
    /// The Replace field's focus, so a finished replace can put the keyboard away (fix round 1, I3).
    var isReplaceFocused: FocusState<Bool>.Binding
    let counter: String
    let canNavigate: Bool
    /// "Play from 12:04" for the current match, or nil when there is nothing to play.
    let playTitle: String?
    /// Why Replace cannot run on this transcript (no word timings…); nil when it can.
    let replaceUnavailable: String?
    let canReplaceCurrent: Bool
    let canReplaceAll: Bool
    let isReplacing: Bool
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onDone: () -> Void
    let onPlay: () -> Void
    let onReplace: () -> Void
    let onReplaceAll: () -> Void

    var body: some View {
        ChirpBottomBar(horizontalPadding: Tokens.Spacing.m) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Tokens.Spacing.xs) {
                        field
                        navigation
                    }
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                        field
                        navigation
                    }
                }
                secondRow
                if showsReplace {
                    replaceRow
                }
            }
        }
    }

    // MARK: - Find

    private var field: some View {
        // The counter goes under the field at accessibility sizes, so the row never runs past the screen's edge.
        // `AnyLayout` keeps the field's identity (and focus) whichever layout applies.
        let layout =
            dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 0))
            : AnyLayout(HStackLayout(spacing: Tokens.Spacing.xs))
        return layout {
            HStack(spacing: Tokens.Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .chirpGlyph(14, .medium)
                    .foregroundStyle(Tokens.Color.mutedText)
                    .accessibilityHidden(true)
                ChirpTextField("Find in transcript", text: $query)
                    .chirpFont(16)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused(isFocused)
                    .onSubmit {
                        onNext()
                        // Fix round 1, M5: Return steps and keeps the keyboard, so the next Return steps again.
                        isFocused.wrappedValue = true
                    }
                    .onKeyPress(.escape) {
                        if !query.isEmpty {
                            query = ""
                        } else {
                            onDone()
                        }
                        return .handled
                    }
                    .accessibilityIdentifier("find-field")
                    .frame(minWidth: 96, maxWidth: .infinity, minHeight: Tokens.Metric.minTapTarget)
            }
            // The counter's width is reserved (upstream's pattern), so the bar's layout never changes while typing: a
            // layout change would rebuild the field and drop its focus mid-word.
            ZStack(alignment: .trailing) {
                Text("No matches").hidden()
                Text("000 of 000").hidden()
                Text(counter)
                    .accessibilityLabel(TranscriptFindCopy.counterAccessibility(counter))
                    .accessibilityIdentifier("find-counter")
            }
            .chirpFont(13)
            .monospacedDigit()
            .foregroundStyle(Tokens.Color.secondary)
            .lineLimit(1)
            .fixedSize()
        }
        .padding(.horizontal, Tokens.Spacing.s)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.input, style: .continuous).fill(Tokens.Color.quietFill))
    }

    private var navigation: some View {
        HStack(spacing: 0) {
            iconButton("chevron.up", label: "Previous match", hint: "Shift Command G", action: onPrevious)
            iconButton("chevron.down", label: "Next match", hint: "Command G", action: onNext)
        }
    }

    private func iconButton(_ systemImage: String, label: String, hint: String, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Image(systemName: systemImage)
                .chirpGlyph(16, .semibold)
                .foregroundStyle(canNavigate ? Tokens.Color.ink : Tokens.Color.mutedText)
                .frame(minWidth: Tokens.Metric.minTapTarget, minHeight: Tokens.Metric.minTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canNavigate)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }

    private var doneButton: some View {
        Button("Done", action: onDone)
            .buttonStyle(.chirp(.quiet, size: .compact))
            .fixedSize()
            .accessibilityHint("Closes Find")
    }

    // MARK: - Play and Show Replace

    private var secondRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Tokens.Spacing.xs) {
                playButton
                Spacer(minLength: 0)
                replaceToggle
                doneButton
            }
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                playButton
                HStack(spacing: Tokens.Spacing.xs) {
                    replaceToggle
                    Spacer(minLength: 0)
                    doneButton
                }
            }
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                playButton
                replaceToggle
                doneButton
            }
        }
    }

    @ViewBuilder private var playButton: some View {
        if let playTitle {
            Button(action: onPlay) {
                Label(playTitle, systemImage: "play.fill")
                    .monospacedDigit()
            }
            .buttonStyle(.chirp(.tinted, size: .compact))
            .fixedSize()
        }
    }

    private var replaceToggle: some View {
        Button(showsReplace ? "Hide Replace" : "Show Replace") {
            showsReplace.toggle()
        }
        .buttonStyle(.chirp(.quiet, size: .compact))
        .fixedSize()
    }

    // MARK: - Replace

    @ViewBuilder private var replaceRow: some View {
        if let replaceUnavailable {
            Text(replaceUnavailable)
                .chirpFont(13.5)
                .foregroundStyle(Tokens.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Tokens.Spacing.xs) {
                    replaceField
                    replaceButtons
                }
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    replaceField
                    replaceButtons
                }
            }
        }
    }

    private var replaceField: some View {
        ChirpTextField("Replace with", text: $replacement)
            .focused(isReplaceFocused)
            .chirpFont(16)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("replace-field")
            .padding(.horizontal, Tokens.Spacing.s)
            .frame(minWidth: 120, maxWidth: .infinity, minHeight: Tokens.Metric.minTapTarget)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.input, style: .continuous).fill(Tokens.Color.quietFill))
    }

    private var replaceButtons: some View {
        // Side by side, or stacked at accessibility sizes (two wide buttons would run past the screen's edge).
        let layout =
            dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Tokens.Spacing.xs))
            : AnyLayout(HStackLayout(spacing: Tokens.Spacing.xs))
        return layout {
            Button("Replace", action: onReplace)
                .buttonStyle(.chirp(.tinted, size: .compact))
                .disabled(!canReplaceCurrent || isReplacing)
                .fixedSize()
            Button("Replace All", action: onReplaceAll)
                .buttonStyle(.chirp(.filled, size: .compact))
                .disabled(!canReplaceAll || isReplacing)
                .fixedSize()
        }
    }
}

/// What a Replace did, above the find bar: "Replaced 12." with Undo, and when D8 allows it, "Also fix “met for men" in
/// future transcripts?" with Add Rule (and the clinical note on a clinical item). It stays until the next replace,
/// Undo, or Find closes.
struct ReplaceResult: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var undo: TranscriptCorrectionPlan
    var suggestion: LearnedRuleSuggestion?
    var note: String?
    /// Why there is no rule offer, when that is worth saying (fix round 1, C1: a number).
    var withheld: String?
    /// What Add Rule did ("Rule added…", or why not).
    var ruleStatus: String?

    /// Undo is offered only when the replace changed something (fix round 1, M2).
    var canUndo: Bool { !undo.isEmpty }

    /// The banner for `outcome`: "Replaced 3." (or "Nothing changed."), what was left alone and why, the rule offer
    /// with the clinical note on a clinical item, or why there is none.
    static func make(_ outcome: ReplaceOutcome, privacyClass: PrivacyClass) -> ReplaceResult {
        guard outcome.count > 0 else {
            return ReplaceResult(message: TranscriptFindCopy.nothingChanged, undo: .init())
        }
        var message = TranscriptFindCopy.replaced(count: outcome.count)
        let stale = outcome.skipped - outcome.skippedInCorrections
        if outcome.skippedInCorrections > 0 {
            message += " " + TranscriptFindCopy.skippedInCorrections(outcome.skippedInCorrections)
        }
        if stale > 0 { message += " " + TranscriptFindCopy.skipped(stale) }
        let note = outcome.ruleSuggestion.flatMap { TranscriptFindCopy.rulePrompt($0, privacyClass: privacyClass).note }
        return ReplaceResult(
            message: message, undo: outcome.undo, suggestion: outcome.ruleSuggestion, note: note,
            withheld: outcome.ruleSuggestion == nil ? outcome.ruleWithheld : nil)
    }

    /// What VoiceOver says when the result arrives (fix round 1, I3): counts and what can be done, no content.
    func announcement(matchesLeft: Int) -> String {
        guard canUndo else { return TranscriptFindCopy.nothingChanged }
        var text = TranscriptFindCopy.replacedAnnouncement(left: matchesLeft) + " Undo available."
        if suggestion != nil { text += " Rule offer available." }
        return text
    }
}

struct ReplaceResultBanner: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let result: ReplaceResult
    let onUndo: () -> Void
    let onAddRule: () -> Void

    var body: some View {
        ChirpBottomBar(horizontalPadding: Tokens.Spacing.m) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Tokens.Spacing.s) {
                        message
                        Spacer(minLength: 0)
                        if result.canUndo { undoButton }
                    }
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                        message
                        if result.canUndo { undoButton }
                    }
                }
                if let withheld = result.withheld {
                    Text(withheld)
                        .chirpFont(13)
                        .foregroundStyle(Tokens.Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let suggestion = result.suggestion {
                    // Beside the question at ordinary sizes; under it at accessibility sizes.
                    let layout =
                        dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: Tokens.Spacing.xs))
                        : AnyLayout(HStackLayout(alignment: .center, spacing: Tokens.Spacing.s))
                    layout {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.question)
                                .chirpFont(14, .semibold)
                                .foregroundStyle(Tokens.Color.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            if let note = result.note {
                                Text(note)
                                    .chirpFont(12.5)
                                    .foregroundStyle(Tokens.Color.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Add Rule", action: onAddRule)
                            .buttonStyle(.chirp(.tinted, size: .compact))
                            .fixedSize()
                            .accessibilityHint("New transcripts get this fix as a correction you can undo")
                    }
                }
                if let status = result.ruleStatus {
                    Text(status)
                        .chirpFont(13)
                        .foregroundStyle(Tokens.Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var message: some View {
        Text(result.message)
            .chirpFont(14.5, .semibold)
            .foregroundStyle(Tokens.Color.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var undoButton: some View {
        Button("Undo", action: onUndo)
            .buttonStyle(.chirp(.tinted, size: .compact))
            .fixedSize()
            .accessibilityHint("Puts the words back as they were before this replace")
    }
}

/// The words of Find and Replace (plan 025 D5). Announcements carry counts and times only, never transcript text.
enum TranscriptFindCopy {
    static func playFrom(ms: Int) -> String { "Play from \(Formatting.clock(ms: ms))" }

    /// VoiceOver reads the counter as shown.
    static func counterAccessibility(_ counter: String) -> String { counter }

    static func replaceAllTitle(count: Int) -> String {
        count == 1 ? "Replace 1 match?" : "Replace \(count) matches?"
    }

    static func replaceAllMessage(query: String, replacement: String, count: Int) -> String {
        "“\(query)” becomes “\(replacement)” in \(count == 1 ? "1 place" : "\(count) places"). "
            + "They are corrections you can undo together."
    }

    static func replaced(count: Int) -> String { count == 1 ? "Replaced." : "Replaced \(count)." }

    static func replacedAnnouncement(left: Int) -> String {
        switch left {
        case 0: "Replaced. No matches left."
        case 1: "Replaced. 1 match left."
        default: "Replaced. \(left) matches left."
        }
    }

    /// Matches whose text changed before the replace ran (another correction meanwhile).
    static func skipped(_ count: Int) -> String {
        count == 1
            ? "1 place had changed, so it was left as it is."
            : "\(count) places had changed, so they were left as they are."
    }

    /// A replace that changed nothing (the places already read as the replacement, or their text changed).
    static let nothingChanged = "Nothing changed."

    /// Fix round 1, I2: matches in a passage corrected earlier are left alone (reverting this replace never takes that
    /// correction with it).
    static func skippedInCorrections(_ count: Int) -> String {
        count == 1
            ? "1 in a corrected passage was left as it is."
            : "\(count) in a corrected passage were left as they are."
    }

    /// What VoiceOver says after Add Rule (fix round 1, M3): never the rule's words.
    static func ruleStatusAnnouncement(_ outcome: TextRulesViewModel.LearnedRuleOutcome) -> String {
        switch outcome {
        case .added: ruleAdded
        case .alreadyExists: "That rule already exists."
        case .refused(let reason): reason
        case .failed: "The rule wasn’t saved."
        }
    }

    /// "Also fix “met for men” in future transcripts?", plus the clinical note on a clinical item (D6: learned rules
    /// are global, outside any item's class).
    static func rulePrompt(_ suggestion: LearnedRuleSuggestion, privacyClass: PrivacyClass) -> (
        question: String, note: String?
    ) {
        (suggestion.question, privacyClass == .clinical ? LearnedRuleSuggestion.clinicalNote : nil)
    }

    static let ruleAdded = "Rule added. New transcripts get this fix as a correction."
}
