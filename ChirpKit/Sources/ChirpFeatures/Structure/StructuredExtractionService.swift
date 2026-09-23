import ChirpCore
import ChirpText
import Foundation

/// Whether an engine can run now.
public enum StructureEngineAvailability: Sendable, Equatable {
    case ready
    case unavailable(String)
}

/// The structure engines the app registered. ChirpFeatures never imports an engine target: the app hands Needle over
/// as `any StructureModel` with a closure that says whether it can run.
public struct StructureEngines: Sendable {
    public var needle: (any StructureModel)?
    public var needleAvailability: @Sendable () async -> StructureEngineAvailability
    public var stub: any StructureModel

    public init(
        needle: (any StructureModel)?,
        needleAvailability: @escaping @Sendable () async -> StructureEngineAvailability,
        stub: any StructureModel = StubStructureModel()
    ) {
        self.needle = needle
        self.needleAvailability = needleAvailability
        self.stub = stub
    }

    /// The chosen engine, or the STUB and the reason Needle could not be used (Needle Bench: fall back, and say so).
    public func resolve(_ choice: StructureEngineChoice) async -> (model: any StructureModel, fallbackReason: String?) {
        guard choice == .needle else { return (stub, nil) }
        guard let needle else { return (stub, "Needle is not in this build.") }
        switch await needleAvailability() {
        case .ready: return (needle, nil)
        case .unavailable(let reason): return (stub, reason)
        }
    }

    /// Display name for a stored engine id.
    public static func displayName(for engineID: String) -> String {
        switch engineID {
        case StubStructureModel.engineID: "STUB (rules)"
        case "needle.needle3": "Needle 3"
        default: engineID
        }
    }
}

/// One extraction run as the screens show it.
public struct StructuredDraft: Sendable, Equatable {
    public var run: StructuredRun
    public var fields: [StructuredField]
    /// The run's source text (spans index into it).
    public var sourceText: String
    /// Set when Needle was chosen but the STUB ran.
    public var fallbackReason: String?
    public var sentenceCount: Int
    /// Wall-clock seconds of the run (nil for a run read back from the ledger).
    public var seconds: Double?

    public var isStub: Bool { run.engineID == StubStructureModel.engineID }
    public var engineName: String { StructureEngines.displayName(for: run.engineID) }

    /// The whole sentence a field came from, and the UTF-16 range of the field's words inside it (nil when the field
    /// spans the whole sentence). Review L3 I2: the reviewer sees which drug and which vital a value belongs to.
    public func evidenceSentence(for field: StructuredField, sentences: [Range<Int>]) -> (
        text: String, highlight: Range<Int>?
    ) {
        let ns = sourceText as NSString
        guard
            let range = sentences.first(where: { $0.contains(field.span.characterStart) })
                ?? sentences.last(where: { $0.lowerBound <= field.span.characterStart })
        else { return (evidence(for: field), nil) }
        let raw = ns.substring(with: NSRange(location: range.lowerBound, length: range.count))
        let leading = raw.utf16.count - String(raw.drop { $0.isWhitespace || $0.isNewline }).utf16.count
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = range.lowerBound + leading
        let low = max(field.span.characterStart - start, 0)
        let high = min(field.span.characterEnd - start, text.utf16.count)
        let whole = low == 0 && high == text.utf16.count
        return (text, low < high && !whole ? low..<high : nil)
    }

    /// The words a field's span covers.
    public func evidence(for field: StructuredField) -> String {
        let ns = sourceText as NSString
        let start = min(max(field.span.characterStart, 0), ns.length)
        let end = min(max(field.span.characterEnd, start), ns.length)
        return ns.substring(with: NSRange(location: start, length: end - start))
    }
}

/// SOAP fields and medications from a transcript (plan 015 Step 6): sentence by sentence, the numeric normalizer, the
/// structure engine against `soap-meds.v1`, the validator and the gate; every field saved to the evidence ledger.
///
/// Clinical text never leaves the phone: a clinical item may only reach an `.onDevice` structure engine (stricter
/// than `PrivacyRoutingPolicy`, which would allow a trusted LAN host). The output is always a draft for review.
public actor StructuredExtractionService {
    public enum ExtractionError: Error, Equatable, LocalizedError {
        case transcriptNotFound
        case noText
        case privacyRoutingRefused(String)

        public var errorDescription: String? {
            switch self {
            case .transcriptNotFound: "This transcript no longer exists."
            case .noText: "This transcript has no text to read yet."
            case .privacyRoutingRefused(let name):
                "\(name) does not run on this iPhone, so it may not read clinical text."
            }
        }
    }

    private let transcripts: any TranscriptionStoring
    private let results: any StructuredResultStoring
    private let settings: any StructureSettingsStoring
    private let engines: StructureEngines
    private let logger = Log.logger("structure")

    public init(
        transcripts: any TranscriptionStoring, results: any StructuredResultStoring,
        settings: any StructureSettingsStoring, engines: StructureEngines
    ) {
        self.transcripts = transcripts
        self.results = results
        self.settings = settings
        self.engines = engines
    }

    /// Whether `engine` may read content of `privacyClass`: the router's answer, and on-device only for clinical.
    public static func mayRun(_ engine: EngineDescriptor, on privacyClass: PrivacyClass) -> Bool {
        guard PrivacyRoutingPolicy().allows(engine, for: privacyClass) else { return false }
        return privacyClass != .clinical || engine.locality == .onDevice
    }

    /// Runs `soap-meds.v1` over the transcript and saves the run. `progress(done, total)` reports sentences.
    public func extractSOAP(
        transcriptionID: UUID, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> StructuredDraft {
        guard let transcription = try await transcripts.fetch(id: transcriptionID) else {
            throw ExtractionError.transcriptNotFound
        }
        let settingsValue = settings.load()
        let (engine, fallbackReason) = await engines.resolve(settingsValue.engine)
        guard Self.mayRun(engine.descriptor, on: transcription.privacyClass) else {
            logger.error("structure_refused engine=\(engine.descriptor.id, privacy: .public)")
            throw ExtractionError.privacyRoutingRefused(engine.descriptor.displayName)
        }
        let source = StructuredSourceText(transcription: transcription)
        let sentences = source.sentenceRanges()
        guard !sentences.isEmpty else { throw ExtractionError.noText }

        let started = Date()
        let catalog = StructureCatalog.soapMeds
        let gate = settingsValue.gate
        var run = StructuredRun(
            transcriptionID: transcriptionID, catalogVersion: catalog.versionedID, engineID: engine.descriptor.id,
            modelSHA256: nil, actThreshold: gate.act, provisionalThreshold: gate.provisional)
        var fields: [StructuredField] = []
        for (index, sentenceRange) in sentences.enumerated() {
            try Task.checkCancellation()
            let sentence = NumericNormalizer.normalize(source.substring(sentenceRange))
            let offset = sentenceRange.lowerBound + Self.leadingTrim(in: source, range: sentenceRange)
            let outcome = await Self.extract(
                sentence: sentence, engine: engine, catalog: catalog, privacy: transcription.privacyClass)
            if let hash = outcome.modelSHA256 { run.modelSHA256 = hash }
            for item in outcome.items {
                let local =
                    item.tagRanges.isEmpty
                    ? 0..<(sentence.original as NSString).length
                    : item.tagRanges.map(\.lowerBound).min()!..<item.tagRanges.map(\.upperBound).max()!
                let span = source.span(for: (local.lowerBound + offset)..<(local.upperBound + offset))
                fields.append(
                    StructuredField(
                        runID: run.id, tool: item.tool, argumentsJSON: JSONValue.object(item.arguments).compactJSON,
                        span: span, confidence: outcome.confidence,
                        verdict: gate.verdict(
                            confidence: outcome.confidence, problems: item.problems, engineID: engine.descriptor.id),
                        reviewReasons: item.problems, ordinal: fields.count))
            }
            progress(index + 1, sentences.count)
        }
        try await results.save(run, fields: fields)
        logger.notice(
            "structure_run run=\(run.id, privacy: .public) engine=\(run.engineID, privacy: .public) sentences=\(sentences.count, privacy: .public) fields=\(fields.count, privacy: .public)"
        )
        return StructuredDraft(
            run: run, fields: fields, sourceText: source.text, fallbackReason: fallbackReason,
            sentenceCount: sentences.count, seconds: Date().timeIntervalSince(started))
    }

    /// The newest saved run for the transcript, if any.
    public func latestDraft(transcriptionID: UUID) async throws -> StructuredDraft? {
        guard let run = try await results.runs(forTranscription: transcriptionID).first,
            let transcription = try await transcripts.fetch(id: transcriptionID)
        else { return nil }
        let source = StructuredSourceText(transcription: transcription)
        return StructuredDraft(
            run: run, fields: try await results.fields(forRun: run.id), sourceText: source.text, fallbackReason: nil,
            sentenceCount: source.sentenceRanges().count, seconds: nil)
    }

    /// Records a review; `argumentsJSON` carries the person's edits (nil keeps the arguments).
    public func setReviewed(_ field: StructuredField, reviewed: Bool, argumentsJSON: String? = nil) async throws {
        try await results.setReviewed(fieldID: field.id, reviewed: reviewed, argumentsJSON: argumentsJSON)
    }

    // MARK: - One sentence

    struct SentenceOutcome {
        var items: [ValidatedCall]
        var confidence: Double
        var modelSHA256: String?
    }

    /// Engine → parse → validate. Engine failures become a needs-review item, never a silent gap.
    static func extract(
        sentence: NormalizedText, engine: any StructureModel, catalog: StructureCatalog, privacy: PrivacyClass
    ) async -> SentenceOutcome {
        let output: StructuredOutput
        do {
            output = try await engine.extract(
                jsonSchema: catalog.toolsJSON, from: sentence.tagged, privacyClass: privacy)
        } catch {
            let message = (error as? any LocalizedError)?.errorDescription ?? "The engine failed on this sentence."
            return SentenceOutcome(items: [unanswered(message)], confidence: 0, modelSHA256: nil)
        }
        if output.isAbstention {
            return SentenceOutcome(items: [], confidence: output.confidence, modelSHA256: output.modelSHA256)
        }
        guard let calls = StructuredCall.parseArray(output.json) else {
            return SentenceOutcome(
                items: [unanswered("The engine's answer was not a list of tool calls.")], confidence: output.confidence,
                modelSHA256: output.modelSHA256)
        }
        return SentenceOutcome(
            items: StructuredCallValidator.validate(calls, sentence: sentence, catalog: catalog),
            confidence: output.confidence, modelSHA256: output.modelSHA256)
    }

    static func unanswered(_ reason: String) -> ValidatedCall {
        ValidatedCall(
            tool: "none", arguments: ["reason": .string("unclear")], problems: [reason], numericHardFail: false,
            tagRanges: [])
    }

    /// UTF-16 length of the whitespace `substring` trimmed from the front of a sentence range.
    static func leadingTrim(in source: StructuredSourceText, range: Range<Int>) -> Int {
        let raw = (source.text as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count))
        let trimmed = raw.drop { $0.isWhitespace || $0.isNewline }
        return raw.utf16.count - String(trimmed).utf16.count
    }
}
