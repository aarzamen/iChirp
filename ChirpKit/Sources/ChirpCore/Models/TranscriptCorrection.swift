// Semantics from MacParakeet (GPL-3.0): spec/adr/031-timed-transcript-corrections.md,
// Sources/MacParakeetCore/Models/SpeakerCorrection.swift and Services/Diarization/SpeakerAttributionResolver.swift @
// bbae9e0e: immutable baseline, fingerprint, envelope timing. Word-span targets instead of whole segments. Fresh
// implementation, not a line port.

import Foundation

/// One correction: a contiguous, single-speaker run of the engine's words `[a, b)` replaced by the person's text
/// (plan 025 D1). The words as heard stay in the row (the baseline is never rewritten); `heard` keeps a copy so Show
/// Original never re-derives it. Contract: `spec/contracts/transcript-corrections-v1.md`.
public struct TranscriptCorrection: Codable, Sendable, Equatable, Identifiable {
    /// Where a correction came from. An origin this build does not know reads as `edit` (display only).
    public enum Origin: String, Codable, Sendable, CaseIterable {
        /// The person retyped a passage (Correct…).
        case edit
        /// One Find match replaced (Part B).
        case replace
        /// Every Find match replaced at once (`batchID` groups them; Part B).
        case replaceAll
        /// A learned rule ("Also fix future transcripts", `ruleID`; Part B).
        case rule
        /// A dictation's voice command ("scratch that", "new paragraph"; review R5-2).
        case voiceCommand

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Origin(rawValue: raw) ?? .edit
        }
    }

    public var id: UUID
    /// Half-open range into the row's `wordTimestamps`.
    public var wordRange: TranscriptSegmentWordRange
    /// The words in the range as heard, trimmed and joined by single spaces (`TranscriptCorrections.heardText`).
    public var heard: String
    /// What the words now read; trimmed, never empty.
    public var text: String
    public var origin: Origin
    /// Corrections made together (a Replace all, the voice commands of one dictation) share it.
    public var batchID: UUID?
    /// The learned rule that made it (Part B).
    public var ruleID: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), wordRange: Range<Int>, heard: String, text: String, origin: Origin, batchID: UUID? = nil,
        ruleID: UUID? = nil, createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.wordRange = TranscriptSegmentWordRange(
            startIndex: wordRange.lowerBound, endIndexExclusive: wordRange.upperBound)
        self.heard = heard
        self.text = text
        self.origin = origin
        self.batchID = batchID
        self.ruleID = ruleID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// `wordRange` as a Swift range.
    public var range: Range<Int> {
        wordRange.startIndex..<max(wordRange.startIndex, wordRange.endIndexExclusive)
    }
}

/// What a correction write changes: the items to remove (by id) and the ones to add. The inverse of an applied plan
/// is a plan too (undo).
public struct TranscriptCorrectionPlan: Sendable, Equatable {
    public var remove: Set<UUID>
    public var add: [TranscriptCorrection]

    public init(remove: Set<UUID> = [], add: [TranscriptCorrection] = []) {
        self.remove = remove
        self.add = add
    }

    public var isEmpty: Bool { remove.isEmpty && add.isEmpty }
}

/// Why a plan cannot be applied.
public enum TranscriptCorrectionsError: Error, Equatable, Sendable {
    /// A range is empty or outside the words.
    case invalidRange
    /// Two added ranges overlap, or an added range only partly covers a stored correction.
    case overlapping
    /// A range holds words of more than one speaker.
    case mixedSpeakers
    /// A correction's text is blank.
    case emptyText
    /// The envelope was made against other words (`baseline` differs).
    case baselineChanged
    /// A newer build wrote the envelope; this build never changes it.
    case newerVersion
}

/// The person's corrections of one transcript (`Transcription.textCorrections`, column `textCorrections`, migration
/// `v11-transcript-corrections`). Pure value rules; the store writes it field by field and the accessor in ChirpText
/// is the only reader that applies it.
public struct TranscriptCorrections: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    public var schema: Int
    /// `TranscriptFingerprint.of(words)` of the words `items` index.
    public var baseline: String
    /// Set on every add, revert and detach; never cleared (Extract fields compares a run's date with it).
    public var changedAt: Date
    /// Applied in the transcript; sorted by start, never overlapping.
    public var items: [TranscriptCorrection]
    /// From an earlier transcript of this audio (the words changed): kept, never applied.
    public var detached: [TranscriptCorrection]

    public init(
        schema: Int = TranscriptCorrections.currentSchema, baseline: String, changedAt: Date,
        items: [TranscriptCorrection] = [], detached: [TranscriptCorrection] = []
    ) {
        self.schema = schema
        self.baseline = baseline
        self.changedAt = changedAt
        self.items = items
        self.detached = detached
    }

    /// No corrections yet: the start of a row's first write.
    public static let empty = TranscriptCorrections(baseline: "", changedAt: .distantPast)

    /// A newer build wrote it: it applies nothing here and every write path keeps the stored JSON unchanged.
    public var isFromNewerBuild: Bool { schema > Self.currentSchema }

    private enum CodingKeys: String, CodingKey {
        case schema, baseline, changedAt, items, detached
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        guard schema <= Self.currentSchema else {
            // A newer shape: read nothing else (its items may not decode here). The store keeps the stored text.
            baseline = ""
            changedAt = (try? container.decode(Date.self, forKey: .changedAt)) ?? .distantPast
            items = []
            detached = []
            return
        }
        baseline = try container.decode(String.self, forKey: .baseline)
        changedAt = try container.decode(Date.self, forKey: .changedAt)
        items = try container.decodeIfPresent([TranscriptCorrection].self, forKey: .items) ?? []
        detached = try container.decodeIfPresent([TranscriptCorrection].self, forKey: .detached) ?? []
    }

    // MARK: - Rules

    /// The words of `range` as a correction's `heard`: each word trimmed, joined by single spaces.
    public static func heardText(of words: [WordTimestamp], in range: Range<Int>) -> String {
        words[range].map { $0.word.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The items that keep every invariant against `words`, in order: in bounds, non-empty, one speaker, non-blank
    /// text, `heard` equal to the words now, not overlapping an earlier valid item. Anything else is skipped (and
    /// logged by id only). Nothing from a newer build.
    public func validItems(in words: [WordTimestamp]) -> [TranscriptCorrection] {
        guard !isFromNewerBuild, !items.isEmpty else { return [] }
        var result: [TranscriptCorrection] = []
        var end = 0
        for item in items.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            let range = item.range
            let valid =
                range.lowerBound >= end && Self.check(range, text: item.text, in: words) == nil
                && item.heard == Self.heardText(of: words, in: range)
            guard valid else {
                Self.logger.error("correction_skipped_invalid id=\(item.id.uuidString, privacy: .public)")
                continue
            }
            result.append(item)
            end = range.upperBound
        }
        return result
    }

    /// Applies `plan` against `words`: removes `plan.remove`, then adds each item (its `heard` set from `words`). An
    /// added item replaces the stored items it covers whole; one whose text equals its heard words only removes them (a
    /// revert by retyping). Returns the new envelope (`changedAt` = `now`, `baseline` = the words' fingerprint) and the
    /// inverse plan, which restores the previous items exactly.
    public func applying(
        _ plan: TranscriptCorrectionPlan, words: [WordTimestamp], now: Date, strict: Bool = false
    ) throws -> (
        corrections: TranscriptCorrections, inverse: TranscriptCorrectionPlan
    ) {
        guard !isFromNewerBuild else { throw TranscriptCorrectionsError.newerVersion }
        let fingerprint = TranscriptFingerprint.of(words)
        if !items.isEmpty, baseline != fingerprint { throw TranscriptCorrectionsError.baselineChanged }

        var kept = items.filter { !plan.remove.contains($0.id) }
        var removed = items.filter { plan.remove.contains($0.id) }
        var added: [TranscriptCorrection] = []
        let adds = plan.add.sorted { $0.range.lowerBound < $1.range.lowerBound }
        for (index, add) in adds.enumerated() {
            let range = add.range
            guard add.wordRange.endIndexExclusive > add.wordRange.startIndex else {
                throw TranscriptCorrectionsError.invalidRange
            }
            if let error = Self.check(range, text: add.text, in: words) { throw error }
            if index > 0, adds[index - 1].range.overlaps(range) { throw TranscriptCorrectionsError.overlapping }
            // Stored items it touches must lie inside it: it replaces them whole.
            let touched = kept.filter { $0.range.overlaps(range) }
            if touched.contains(where: {
                $0.range.lowerBound < range.lowerBound || $0.range.upperBound > range.upperBound
            }) {
                throw TranscriptCorrectionsError.overlapping
            }
            kept.removeAll { $0.range.overlaps(range) }
            removed += touched
            var item = add
            item.text = add.text.trimmingCharacters(in: .whitespacesAndNewlines)
            item.heard = Self.heardText(of: words, in: range)
            if item.text != item.heard {
                added.append(item)
            }
        }
        var result = self
        result.schema = Self.currentSchema
        result.items = (kept + added).sorted { $0.range.lowerBound < $1.range.lowerBound }
        result.baseline = fingerprint
        result.changedAt = now
        let inverse = TranscriptCorrectionPlan(remove: Set(added.map(\.id)), add: removed)
        return (result, inverse)
    }

    /// What a pipeline save keeps (plan 025 D7). Same words (or a save without words): unchanged. Different words: the
    /// items move to `detached` (kept, never applied), the envelope binds to the new words and `changedAt` moves. A
    /// newer build's envelope is returned as it is.
    public func preserved(acrossNewWords words: [WordTimestamp], now: Date) -> TranscriptCorrections {
        guard !isFromNewerBuild, !words.isEmpty else { return self }
        let fingerprint = TranscriptFingerprint.of(words)
        guard fingerprint != baseline else { return self }
        var result = self
        result.baseline = fingerprint
        if !items.isEmpty {
            result.detached += items
            result.items = []
            result.changedAt = now
        }
        return result
    }

    /// Nil when `range` and `text` keep the invariants against `words`.
    private static func check(_ range: Range<Int>, text: String, in words: [WordTimestamp])
        -> TranscriptCorrectionsError?
    {
        guard range.lowerBound >= 0, range.upperBound <= words.count, !range.isEmpty else { return .invalidRange }
        let speaker = words[range.lowerBound].speakerId
        guard words[range].allSatisfy({ $0.speakerId == speaker }) else { return .mixedSpeakers }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .emptyText }
        return nil
    }

    private static let logger = Log.logger("corrections")
}
