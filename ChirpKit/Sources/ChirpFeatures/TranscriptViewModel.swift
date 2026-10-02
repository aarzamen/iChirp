import ChirpCore
import ChirpExport
import ChirpText
import Foundation
import Observation

/// The Transcript screen: one row's paragraphs, speakers, media and export, and (plan 025) the person's corrections:
/// the lines with their correction marks, Correct, Show Original, revert and undo, all through
/// `TranscriptCorrectionService`.
@MainActor @Observable public final class TranscriptViewModel {
    public enum TranscriptError: Error, Equatable, LocalizedError {
        case notLoaded

        public var errorDescription: String? {
            switch self {
            case .notLoaded: "This transcript is not available."
            }
        }
    }

    public let id: UUID
    public private(set) var transcription: Transcription?
    /// Reading paragraphs, rebuilt whenever `transcription` changes: the `.heard` view's lines (from the words with
    /// the person's corrections; one paragraph of the text when there are no words).
    public private(set) var paragraphs: [TranscriptParagraph] = []
    /// Plan 025: the screen's view of the transcript (`Transcription.text(.heard)`): lines with stable ids and where
    /// each token sits, tokens (a correction is one token with its `editID`), the corrections applied.
    public private(set) var heard: TranscriptText?
    /// Set when `load()` could not read the row.
    public private(set) var loadError: String?

    @ObservationIgnored private let store: any TranscriptionStoring
    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private let settings: any SettingsStoring
    /// The generated documents, for the effective class a PDF or Word file is marked with (plan 022 review M5).
    @ObservationIgnored private let deliverables: (any DeliverableStoring)?
    /// Plan 025: nil means this screen offers no corrections.
    @ObservationIgnored private let correctionService: TranscriptCorrectionService?
    @ObservationIgnored private let textContextProvider: @Sendable () async -> TranscriptTextContext
    /// The person's clean-up rules as last read (`load()`), for Copy and the exports of a corrected transcript.
    @ObservationIgnored private var textContext = TranscriptTextContext.none

    /// - Parameters:
    ///   - corrections: the correction writer (plan 025); nil keeps the screen read-only.
    ///   - textContext: the person's clean-up rules (`TranscriptTextContext.current(textRules:settings:)`), read on
    ///     every load: Copy and the exports of a corrected transcript in Clean use them.
    public init(
        id: UUID, store: any TranscriptionStoring, paths: AppPaths, settings: any SettingsStoring,
        deliverables: (any DeliverableStoring)? = nil, corrections: TranscriptCorrectionService? = nil,
        textContext: @escaping @Sendable () async -> TranscriptTextContext = { .none }
    ) {
        self.id = id
        self.store = store
        self.paths = paths
        self.settings = settings
        self.deliverables = deliverables
        correctionService = corrections
        textContextProvider = textContext
    }

    public func load() async {
        do {
            textContext = await textContextProvider()
            apply(try await store.fetch(id: id))
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Corrections (plan 025)

    /// The lines the screen shows (the `.heard` view): stable ids, times, speaker, text and each token's place.
    public var lines: [TranscriptTextLine] { heard?.lines ?? [] }
    /// The row has word timings: seeking, the playhead paragraph and corrections need them.
    public var hasWordTimings: Bool { heard?.hasWordTimings ?? false }
    /// The words the screen loaded (`Transcription.wordsFingerprint`); every correction write is bound to it.
    public var baseline: String { transcription?.wordsFingerprint ?? "" }
    /// Correct… is offered: a correction writer, a finished transcript with word timings, corrections this build can
    /// change.
    public var canCorrect: Bool {
        guard correctionService != nil, let transcription, transcription.status == .completed, hasWordTimings else {
            return false
        }
        return transcription.textCorrections?.isFromNewerBuild != true
    }

    /// The corrections applied, in transcript order.
    public var corrections: [TranscriptCorrection] { heard?.edits ?? [] }
    /// Corrections kept from an earlier transcript of this audio (never applied).
    public var detachedCorrections: [TranscriptCorrection] { transcription?.textCorrections?.detached ?? [] }
    /// When the corrections last changed ("Made before your corrections", Extract fields' stale rule); nil before the
    /// first one.
    public var correctionsChangedAt: Date? {
        guard let changedAt = transcription?.textCorrections?.changedAt, changedAt != .distantPast else { return nil }
        return changedAt
    }

    /// The corrections on line `lineID`, in order.
    public func corrections(inLine lineID: Int) -> [TranscriptCorrection] {
        guard let heard, let line = heard.lines.first(where: { $0.id == lineID }) else { return [] }
        let ids = Set(heard.tokens[line.tokenRange].compactMap(\.editID))
        return heard.edits.filter { ids.contains($0.id) }
    }

    /// Line `lineID` as heard (Show Original): the engine's words, without corrections.
    public func heardText(line lineID: Int) -> String {
        guard let transcription, let line = heard?.lines.first(where: { $0.id == lineID }) else { return "" }
        let tokens = heard?.tokens[line.tokenRange] ?? []
        guard let first = tokens.first, let last = tokens.last else { return "" }
        return transcription.heardText(first.wordRange.lowerBound..<last.wordRange.upperBound)
    }

    /// Saves the person's text for line `lineID` as corrections. Throws `TranscriptCorrectionError` (the sheet keeps
    /// the draft); returns the outcome, whose `undo` reverses it.
    @discardableResult
    public func correct(line lineID: Int, text: String) async throws -> CorrectionOutcome {
        let (service, heard) = try correctionInputs()
        let outcome = try await service.correct(id, line: lineID, in: heard, baseline: baseline, text: text)
        apply(outcome.row)
        return outcome
    }

    /// Reverts the given corrections; the outcome's `undo` puts them back (the snackbar's Undo).
    @discardableResult
    public func revert(_ corrections: Set<UUID>) async throws -> CorrectionOutcome {
        let (service, _) = try correctionInputs()
        let outcome = try await service.revert(id, corrections: corrections)
        apply(outcome.row)
        return outcome
    }

    /// Reverts every correction on line `lineID` ("Revert This Passage").
    @discardableResult
    public func revertLine(_ lineID: Int) async throws -> CorrectionOutcome {
        try await revert(Set(corrections(inLine: lineID).map(\.id)))
    }

    /// Applies an undo plan from an earlier outcome, strictly: words corrected again since throw `correctedAgain` and
    /// nothing is written (`TranscriptCorrectionService.undo`).
    @discardableResult
    public func undo(_ plan: TranscriptCorrectionPlan) async throws -> CorrectionOutcome {
        let (service, _) = try correctionInputs()
        let outcome = try await service.undo(id, plan: plan, baseline: baseline)
        apply(outcome.row)
        return outcome
    }

    /// Reverts every correction ("Revert All…"); the transcript reads as heard again.
    @discardableResult
    public func revertAll() async throws -> CorrectionOutcome {
        let (service, _) = try correctionInputs()
        let outcome = try await service.revertAll(id)
        apply(outcome.row)
        return outcome
    }

    /// Deletes detached corrections, on the person's request.
    public func deleteDetached(_ corrections: Set<UUID>) async throws {
        let (service, _) = try correctionInputs()
        apply(try await service.deleteDetached(id, corrections: corrections))
    }

    // MARK: - Find (plan 025 Part B)

    /// The find bar's blocks: the screen's line texts, in order. A `TranscriptFindMatch.blockIndex` indexes `lines`.
    public var findBlocks: [String] { lines.map(\.text) }

    /// When `match` was said: the start of the token the match starts in (an engine word's own start, a correction's
    /// envelope start); nil without word timings or for a match outside the lines.
    public func timeMs(of match: TranscriptFindMatch) -> Int? {
        guard hasWordTimings, let heard, heard.lines.indices.contains(match.blockIndex) else { return nil }
        let line = heard.lines[match.blockIndex]
        guard let offset = line.tokenUTF16Ranges.firstIndex(where: { $0.upperBound > match.range.location }) else {
            return line.startMs
        }
        let tokenIndex = line.tokenRange.lowerBound + offset
        return heard.tokens.indices.contains(tokenIndex) ? heard.tokens[tokenIndex].startMs : line.startMs
    }

    /// Replace and Replace All are offered: the same conditions as Correct… (a correction writer, a finished, timed
    /// transcript whose corrections this build can change).
    public var canReplace: Bool { canCorrect }

    /// Why Replace is not offered, for the find bar; nil when it is.
    public var replaceUnavailableReason: String? {
        guard !canReplace else { return nil }
        if transcription != nil, !hasWordTimings { return "Replace needs word timings; this transcript has none." }
        if transcription?.textCorrections?.isFromNewerBuild == true {
            return TranscriptCorrectionError.newerVersion.errorDescription
        }
        if transcription != nil, transcription?.status != .completed {
            return TranscriptCorrectionError.notCompleted.errorDescription
        }
        return "Replace isn’t available for this transcript."
    }

    /// Replaces one find match with `replacement`, as a `replace` correction of the smallest span of words (plan 025
    /// B3). `query` is the find query the match came from: a match whose text no longer matches it is skipped (count 0).
    /// Throws `TranscriptCorrectionError` when the write is refused.
    @discardableResult
    public func replace(_ match: TranscriptFindMatch, query: String, with replacement: String) async throws
        -> ReplaceOutcome
    {
        try await replace([match], query: query, with: replacement, origin: .replace, batchID: nil)
    }

    /// Replaces every given match with `replacement` in one write: every line with matches (its matches applied last
    /// first), one plan, `replaceAll` corrections sharing one `batchID`, so the outcome's `undo` reverts them together.
    @discardableResult
    public func replaceAll(_ matches: [TranscriptFindMatch], query: String, with replacement: String) async throws
        -> ReplaceOutcome
    {
        try await replace(matches, query: query, with: replacement, origin: .replaceAll, batchID: UUID())
    }

    private func replace(
        _ matches: [TranscriptFindMatch], query: String, with replacement: String,
        origin: TranscriptCorrection.Origin, batchID: UUID?
    ) async throws -> ReplaceOutcome {
        let (service, heard) = try correctionInputs()
        var texts: [Int: String] = [:]
        var replaced: [(text: String, range: NSRange)] = []
        var changed = 0
        var skipped = 0
        var inCorrections = 0
        let byBlock = Dictionary(grouping: matches, by: \.blockIndex)
        for (blockIndex, blockMatches) in byBlock {
            guard heard.lines.indices.contains(blockIndex) else {
                skipped += blockMatches.count
                continue
            }
            let line = heard.lines[blockIndex]
            // The places the query matches in the line now; a stale match is skipped.
            let current = Set(TranscriptSearchIndex(blocks: [line.text]).matches(for: query).map(\.range))
            let fresh = blockMatches.filter { current.contains($0.range) }
            skipped += blockMatches.count - fresh.count
            // Fix round 1, I2: a match in a passage corrected earlier (another batch) is left alone, so reverting
            // this replace never takes that correction with it.
            let valid = fresh.filter {
                !LearnedRuleMatcher.touchesCorrection($0.range, line: line, tokens: heard.tokens)
            }
            inCorrections += fresh.count - valid.count
            guard !valid.isEmpty else { continue }
            let text = NSMutableString(string: line.text)
            let original = line.text as NSString
            for match in valid.sorted(by: { $0.range.location > $1.range.location }) {
                let matched = original.substring(with: match.range)
                let newText = Self.keepingEdgeSpacing(of: matched, in: replacement)
                replaced.append((line.text, match.range))
                if matched != newText { changed += 1 }
                text.replaceCharacters(in: match.range, with: newText)
            }
            texts[line.id] = text as String
        }
        skipped += inCorrections
        guard !texts.isEmpty, changed > 0 else {
            return ReplaceOutcome(undo: .init(), count: 0, skipped: skipped, skippedInCorrections: inCorrections)
        }
        let outcome = try await service.correct(
            id, lines: texts, in: heard, baseline: baseline, origin: origin, batchID: batchID)
        apply(outcome.row)
        // Fix round 1, M2: the changes the write made; a replace that created nothing changed nothing.
        guard !outcome.created.isEmpty else {
            return ReplaceOutcome(undo: .init(), count: 0, skipped: skipped, skippedInCorrections: inCorrections)
        }
        return ReplaceOutcome(
            undo: outcome.undo, count: changed, skipped: skipped, skippedInCorrections: inCorrections,
            ruleSuggestion: LearnedRuleSuggestion.make(query: query, replacement: replacement, replaced: replaced),
            ruleWithheld: LearnedRuleSuggestion.withheldReason(query: query, replacement: replacement))
    }

    /// Fix round 1, M6: an untrimmed query (" the ") replaced by a word without spaces keeps the match's edge spacing,
    /// so the words around it never run together.
    static func keepingEdgeSpacing(of matched: String, in replacement: String) -> String {
        let leading = matched.prefix(while: \.isWhitespace)
        let trailing = matched.reversed().prefix(while: \.isWhitespace).reversed()
        let startsWithSpace = replacement.first?.isWhitespace ?? false
        let endsWithSpace = replacement.last?.isWhitespace ?? false
        return (startsWithSpace ? "" : String(leading)) + replacement + (endsWithSpace ? "" : String(trailing))
    }

    /// The class the privacy rules use for this item now (its documents' raise it): the find bar's rule offer adds
    /// the clinical note when it is clinical (plan 025 D6).
    public func effectivePrivacyClassNow() async -> PrivacyClass {
        guard let transcription else { return .personal }
        return await effectivePrivacyClass(of: transcription)
    }

    private func correctionInputs() throws -> (TranscriptCorrectionService, TranscriptText) {
        guard let correctionService, let heard else { throw TranscriptError.notLoaded }
        return (correctionService, heard)
    }

    /// The speaker's label from the row's roster, else the raw id, else "Speaker".
    public func speakerLabel(for speakerId: String?) -> String {
        guard let speakerId else { return "Speaker" }
        return transcription?.speakers?.first { $0.id == speakerId }?.label ?? speakerId
    }

    /// The imported source file, when it is on disk.
    public var mediaURL: URL? {
        guard let relativePath = transcription?.mediaRelativePath else { return nil }
        let url = paths.absoluteURL(forRelativePath: relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The whole transcript for Copy: the text the person sees in the current clean-up mode
    /// (`Transcription.plainText(.shown(_:))`, plan 024 Task 8), the same text the exports and model input use.
    public var plainText: String {
        guard let transcription else { return "" }
        return transcription.plainText(.shown(settings.load().cleanupMode), context: textContext)
    }

    /// Writes the transcript as `format` into `<tmp>/export-<id>/` and returns the file, for the share sheet. The folder
    /// is `ExportTempFiles.directory(for:)`, the one the Library's delete and the launch sweep remove, and the text is
    /// rendered and written off the main actor, like `exportDocument` (review R4-20: a long transcript's JSON with
    /// every word timing is large).
    public func exportFile(_ format: ExportFormat) async throws -> URL {
        guard let transcription else { throw TranscriptError.notLoaded }
        let cleanupMode = settings.load().cleanupMode
        // The class the privacy rules use (its documents' raise it), so a clinical item's TXT, Markdown and VTT carry the
        // clinical line and its JSON says clinical (review R1-13; the JSON contract's `privacyClass` is the effective one).
        let effectiveClass = await effectivePrivacyClass(of: transcription)
        let directory = ExportTempFiles.directory(for: transcription.id)
        let context = textContext
        return try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return try TranscriptExporter(
                cleanupMode: cleanupMode, effectivePrivacyClass: effectiveClass, context: context
            )
            .write(transcription, as: format, to: directory)
        }.value
    }

    /// Plan 022 Step 6: a PDF or Word copy of the item (title, facts, speakers and timestamps, every paragraph) in the
    /// same `<tmp>/export-<id>/` folder as the text exports. Rendered off the main actor.
    public func exportDocument(_ format: DocumentExportFormat) async throws -> URL {
        guard let transcription else { throw TranscriptError.notLoaded }
        let document = ExportDocument.transcript(
            transcription, cleanupMode: settings.load().cleanupMode,
            effectivePrivacyClass: await effectivePrivacyClass(of: transcription), context: textContext)
        let directory = ExportTempFiles.directory(for: transcription.id)
        return try await Task.detached(priority: .userInitiated) {
            try DocumentExporter().write(document, as: format, to: directory)
        }.value
    }

    /// Sets the user's title; a blank title removes the override (the derived title or file name shows again).
    /// A field-level store write, so it never overwrites a job's output that lands meanwhile.
    public func rename(_ title: String) async throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let updated = try await store.updateTitleOverride(id: id, titleOverride: trimmed.isEmpty ? nil : trimmed)
        else { throw TranscriptError.notLoaded }
        apply(updated)
    }

    public func toggleFavorite() async throws {
        guard let current = try await store.fetch(id: id),
            let updated = try await store.updateFavorite(id: id, isFavorite: !current.isFavorite)
        else { throw TranscriptError.notLoaded }
        apply(updated)
    }

    // MARK: - Helpers

    /// The class the privacy rules use now (`EffectivePrivacyClass`: the row as stored, raised by its documents'); an
    /// unreadable store counts as clinical, the safe side for a label. Without a document store, the row's own class.
    private func effectivePrivacyClass(of transcription: Transcription) async -> PrivacyClass {
        guard let deliverables else { return transcription.privacyClass }
        do {
            let current =
                try await EffectivePrivacyClass.current(
                    transcriptionID: transcription.id, transcripts: store, deliverables: deliverables)
            return (current ?? transcription.privacyClass).stricter(transcription.privacyClass)
        } catch {
            return .clinical
        }
    }

    private func apply(_ row: Transcription?) {
        transcription = row
        guard let row else {
            paragraphs = []
            heard = nil
            return
        }
        // The words as heard (ADR-009: the timed screen always shows the engine's words), with the person's
        // corrections (plan 025); one paragraph of the text without timings.
        let heard = row.text(.heard, context: textContext)
        self.heard = heard
        paragraphs = heard.lines.map { line in
            TranscriptParagraph(
                startMs: line.startMs ?? 0, endMs: line.endMs ?? row.durationMs ?? 0, text: line.text,
                speakerId: line.speakerId)
        }
    }
}
