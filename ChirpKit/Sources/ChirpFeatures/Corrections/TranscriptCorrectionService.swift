// New for iChirp (plan 025 Step A6). Semantics from MacParakeet (GPL-3.0): spec/adr/031-timed-transcript-corrections.md
// @ bbae9e0e (corrections bound to the transcript they were made against; the baseline is never rewritten). Fresh
// implementation for word-span corrections.

import ChirpCore
import ChirpText
import Foundation
import Synchronization

/// What a correction write did: the row as stored, the plan that undoes it, and the corrections it created.
public struct CorrectionOutcome: Sendable, Equatable {
    public var row: Transcription
    /// Applying it (`TranscriptCorrectionService.apply`) restores the previous corrections exactly.
    public var undo: TranscriptCorrectionPlan
    public var created: [UUID]

    public init(row: Transcription, undo: TranscriptCorrectionPlan, created: [UUID]) {
        self.row = row
        self.undo = undo
        self.created = created
    }
}

/// Why a correction was not saved. The screen keeps the person's draft for every one of them.
public enum TranscriptCorrectionError: Error, Equatable, LocalizedError {
    case notFound
    /// The item is still being transcribed, or failed.
    case notCompleted
    /// The transcript has no word timings (D1: Correct needs them).
    case noWordTimings
    /// The words changed since the screen loaded them, or the passage is gone.
    case transcriptChanged
    case emptyText
    /// A newer version of Parakeet wrote this transcript's corrections; this one never changes them.
    case newerVersion
    /// An undo (or another stored plan) covers words that were corrected again since, differently: it cannot be applied.
    case correctedAgain

    public var errorDescription: String? {
        switch self {
        case .notFound: "This transcript no longer exists."
        case .notCompleted: "This transcript isn't finished, so it can't be corrected yet."
        case .noWordTimings: "Correcting needs word timings; this transcript has none."
        case .transcriptChanged: "This transcript changed since it opened. Try again."
        case .emptyText: "The passage can't be empty."
        case .newerVersion: "A newer version of Parakeet made these corrections. Update Parakeet to change them."
        case .correctedAgain: "Those words were corrected again, so this can’t be undone."
        }
    }
}

/// The one writer of transcript corrections (plan 025 D3). Every write is one store transaction
/// (`TranscriptionStoring.updateTextCorrections`) that checks the row is completed, timed and still has the words the
/// screen loaded (`baseline`), applies the plan to the corrections stored at that moment (so a write that landed
/// meanwhile is never lost), and recomputes the derived title and snippet from the corrected text. The words as heard,
/// the raw and clean text and the segments are never written. Logs carry ids, counts and origin names only.
public struct TranscriptCorrectionService: Sendable {
    private let store: any TranscriptionStoring
    private let context: @Sendable () async -> TranscriptTextContext
    private let now: @Sendable () -> Date
    private static let logger = Log.logger("corrections")

    /// - Parameter context: the person's clean-up rules (`TranscriptTextContext.current(textRules:settings:)`), read at
    ///   every write for the derived title of a row with clean text.
    public init(
        store: any TranscriptionStoring, context: @escaping @Sendable () async -> TranscriptTextContext,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.context = context
        self.now = now
    }

    /// The person's text for line `line` of `loaded` (the text the screen showed: its `.heard` view), saved as the
    /// smallest spans (`CorrectionPlanner`). `baseline` is the `wordsFingerprint` the screen loaded. Text that only
    /// differs in spacing writes nothing.
    public func correct(
        _ id: UUID, line: Int, in loaded: TranscriptText, baseline: String, text: String,
        origin: TranscriptCorrection.Origin = .edit, batchID: UUID? = nil
    ) async throws -> CorrectionOutcome {
        guard let target = loaded.lines.first(where: { $0.id == line }) else {
            throw TranscriptCorrectionError.transcriptChanged
        }
        let plan: TranscriptCorrectionPlan
        do {
            plan = try CorrectionPlanner.plan(
                line: target, tokens: loaded.tokens, heard: { loaded.heardText($0) }, editedText: text,
                origin: origin, batchID: batchID, now: now())
        } catch let error as TranscriptCorrectionsError {
            throw Self.map(error)
        }
        do {
            return try await apply(id, plan: plan, baseline: baseline)
        } catch TranscriptCorrectionError.correctedAgain {
            // A new edit over words another write corrected meanwhile: the screen's text is out of date.
            throw TranscriptCorrectionError.transcriptChanged
        }
    }

    /// Applies a plan (an undo, a Replace) bound to the words the screen loaded.
    public func apply(_ id: UUID, plan: TranscriptCorrectionPlan, baseline: String?) async throws
        -> CorrectionOutcome
    {
        try await apply(id, baseline: baseline) { _ in plan }
    }

    /// SCAFFOLD (red run): applies an undo plan.
    public func undo(_ id: UUID, plan: TranscriptCorrectionPlan, baseline: String?) async throws
        -> CorrectionOutcome
    {
        try await apply(id, plan: plan, baseline: baseline)
    }

    /// Reverts the given corrections (Show Original's Revert, a passage, a Replace-all batch). Ids no longer stored
    /// are skipped; when none is left, nothing is written (`changedAt` does not move).
    public func revert(_ id: UUID, corrections: Set<UUID>) async throws -> CorrectionOutcome {
        try await apply(id, baseline: nil) { _ in TranscriptCorrectionPlan(remove: corrections) }
    }

    /// Reverts every correction stored when it writes (inside the store's transaction, so one that landed meanwhile
    /// goes too): the transcript reads as heard again (`items` empty, `changedAt` kept). Nothing to revert writes
    /// nothing.
    public func revertAll(_ id: UUID) async throws -> CorrectionOutcome {
        try await apply(id, baseline: nil) { row in
            TranscriptCorrectionPlan(remove: Set(row.textCorrections?.items.map(\.id) ?? []))
        }
    }

    /// The one write: `makePlan` sees the row as stored inside the transaction. A plan that would leave the stored
    /// items as they are writes nothing.
    private func apply(
        _ id: UUID, baseline: String?, makePlan: @escaping @Sendable (Transcription) -> TranscriptCorrectionPlan
    ) async throws -> CorrectionOutcome {
        let context = await self.context()
        let now = self.now()
        let result = Mutex<(plan: TranscriptCorrectionPlan, inverse: TranscriptCorrectionPlan)?>(nil)
        let saved = try await write(id) { row in
            try Self.check(row, baseline: baseline)
            let plan = makePlan(row)
            let before = row.textCorrections?.items ?? []
            guard !plan.isEmpty else { return false }
            let inverse: TranscriptCorrectionPlan
            do {
                inverse = try row.applyCorrections(plan, now: now)
            } catch let error as TranscriptCorrectionsError {
                throw Self.map(error)
            }
            // Nothing changed (gone ids, retyped heard words over no correction): write nothing.
            guard row.textCorrections?.items != before else { return false }
            Self.derive(&row, context: context)
            result.withLock { $0 = (plan, inverse) }
            return true
        }
        guard let saved, let (plan, inverse) = result.withLock({ $0 }) else {
            return CorrectionOutcome(row: try await unchanged(id), undo: .init(), created: [])
        }
        let created = Set(inverse.remove)
        Self.logger.notice(
            "corrections_saved id=\(id, privacy: .public) added=\(plan.add.count, privacy: .public) removed=\(inverse.add.count, privacy: .public) origin=\(plan.add.first?.origin.rawValue ?? "revert", privacy: .public)"
        )
        let order = saved.textCorrections?.items.map(\.id) ?? []
        return CorrectionOutcome(row: saved, undo: inverse, created: order.filter { created.contains($0) })
    }

    /// Deletes corrections kept from an earlier transcript of this audio (D7), on the person's request.
    public func deleteDetached(_ id: UUID, corrections: Set<UUID>) async throws -> Transcription {
        let saved = try await write(id) { row in
            guard var envelope = row.textCorrections, !envelope.isFromNewerBuild else { return false }
            let before = envelope.detached.count
            envelope.detached.removeAll { corrections.contains($0.id) }
            guard envelope.detached.count != before else { return false }
            row.textCorrections = envelope
            return true
        }
        guard let saved else { return try await unchanged(id) }
        Self.logger.notice(
            "corrections_detached_deleted id=\(id, privacy: .public) count=\(corrections.count, privacy: .public)")
        return saved
    }

    // MARK: - Helpers

    private func write(
        _ id: UUID, _ change: @escaping @Sendable (inout Transcription) throws -> Bool
    ) async throws -> Transcription? {
        try await store.updateTextCorrections(id: id, change)
    }

    /// The row when a write wrote nothing: the reason as an error, or the row as it is (no change).
    private func unchanged(_ id: UUID) async throws -> Transcription {
        guard let row = try await store.fetch(id: id) else { throw TranscriptCorrectionError.notFound }
        if row.textCorrections?.isFromNewerBuild == true { throw TranscriptCorrectionError.newerVersion }
        return row
    }

    /// A write is refused unless the row is completed and timed, its corrections are this build's, and (when given)
    /// its words are the ones the screen loaded.
    private static func check(_ row: Transcription, baseline: String?) throws {
        guard row.status == .completed else { throw TranscriptCorrectionError.notCompleted }
        guard row.hasWordTimings else { throw TranscriptCorrectionError.noWordTimings }
        guard row.textCorrections?.isFromNewerBuild != true else { throw TranscriptCorrectionError.newerVersion }
        if let baseline, row.wordsFingerprint != baseline { throw TranscriptCorrectionError.transcriptChanged }
    }

    /// The derived title and snippet from the corrected text (`Transcription.titleSource(context:)`); with no
    /// corrections left they are the pipeline's again.
    static func derive(_ row: inout Transcription, context: TranscriptTextContext) {
        let source = row.titleSource(context: context)
        let title = TitleDeriver.derive(from: source) ?? ""
        row.derivedTitle = title
        row.derivedSnippet = SnippetDeriver.derive(from: source, excluding: title) ?? ""
    }

    private static func map(_ error: TranscriptCorrectionsError) -> TranscriptCorrectionError {
        switch error {
        case .emptyText: .emptyText
        case .newerVersion: .newerVersion
        case .overlapping: .correctedAgain
        case .baselineChanged, .invalidRange, .mixedSpeakers: .transcriptChanged
        }
    }
}

/// The Correct passage sheet's rules, testable without the GUI (plan 025 D5): Save is off while the text is blank or
/// has no change other than spacing.
public struct CorrectionDraft: Sendable, Equatable {
    /// The passage as the sheet opened it.
    public let original: String
    public var text: String

    public init(original: String) {
        self.original = original
        text = original
    }

    /// The words differ from the original (spacing and line breaks alone are no change).
    public var hasChanges: Bool { Self.words(text) != Self.words(original) }
    public var canSave: Bool { hasChanges && !Self.words(text).isEmpty }

    private static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: \.isWhitespace)
    }
}
