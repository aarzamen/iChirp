import ChirpCore
import ChirpFeatures
import ChirpStore
import Darwin
import Foundation
import XCTest

@testable import ChirpEngineLlamaCpp

/// Opt-in: the real llama.cpp runtime and the real pinned models on this Mac.
///
///     scripts/build_llamacpp.sh
///     CHIRP_ONDEVICE_LLM_TESTS=1 swift test --package-path ChirpKit --filter LlamaCppRealModelTests
///
/// Downloads each model once (SHA-256 checked) into `~/Library/Caches/iChirpTests/ondevice-llm` (or
/// `CHIRP_ONDEVICE_LLM_DIR`); `CHIRP_ONDEVICE_LLM_MODELS=id,id` picks models. Runs the built-in SOAP template on an
/// invented clinical visit through the app's own `DeliverableService` and a real database (routing: on device, so no
/// confirmation), and a visit dense in repeated-digit numbers that must survive verbatim (review I2), then prints load time, first-token latency, tokens per second and the peak memory footprint, and
/// writes them (and the note) next to the models, outside the repository. Everything here is synthetic.
final class LlamaCppRealModelTests: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    private var modelsDirectory: URL {
        if let path = environment["CHIRP_ONDEVICE_LLM_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/iChirpTests/ondevice-llm", isDirectory: true)
    }

    private var selectedSpecs: [LlamaCppModelSpec] {
        guard let list = environment["CHIRP_ONDEVICE_LLM_MODELS"], !list.isEmpty else {
            return LlamaCppModelCatalog.all
        }
        let ids = Set(list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        return LlamaCppModelCatalog.all.filter { ids.contains($0.id) }
    }

    override func setUp() async throws {
        try XCTSkipUnless(
            environment["CHIRP_ONDEVICE_LLM_TESTS"] == "1", "set CHIRP_ONDEVICE_LLM_TESTS=1 to run the real models")
        try XCTSkipUnless(LlamaCppRuntimeInfo.isInBuild, "run scripts/build_llamacpp.sh first")
    }

    func testSyntheticSOAPNoteThroughDeliverableService() async throws {
        for spec in selectedSpecs {
            let run = try await runSOAP(with: spec, visit: Self.syntheticVisit())
            let lowered = run.note.text.lowercased()
            for section in ["subjective", "objective", "assessment", "plan"] {
                XCTAssertTrue(lowered.contains(section), "\(spec.id): the note has a \(section) section")
            }
            XCTAssertTrue(lowered.contains("amoxicillin"), "\(spec.id): the spoken medication is in the plan")
            try write(run, spec: spec, name: "")
        }
    }

    /// Review I2: a visit dense in repeated-digit numbers; every dose and vital must reach the SOAP note verbatim and
    /// the note must carry no number the visit never had. `CHIRP_ONDEVICE_LLM_REPEATS=n` runs each model n times.
    func testNumbersSurviveVerbatimInTheSOAPNote() async throws {
        let repeats = max(1, Int(environment["CHIRP_ONDEVICE_LLM_REPEATS"] ?? "") ?? 1)
        for spec in selectedSpecs {
            var failures = 0
            for attempt in 1...repeats {
                let run = try await runSOAP(with: spec, visit: SyntheticNumberVisit.transcription())
                let report = NumberFidelity.check(
                    note: run.note.text, required: SyntheticNumberVisit.requiredNumbers,
                    source: SyntheticNumberVisit.text)
                if !report.passed { failures += 1 }
                XCTAssertTrue(
                    report.passed,
                    "\(spec.id) run \(attempt): missing \(report.missing), unexpected \(report.unexpected)")
                print(
                    "ONDEVICE_LLM_NUMBERS model=\(spec.id) run=\(attempt) passed=\(report.passed) "
                        + "missing=\(report.missing) unexpected=\(report.unexpected)")
                try write(run, spec: spec, name: "numbers-\(attempt)-", extra: ["number_report": report.dictionary])
            }
            print("ONDEVICE_LLM_NUMBERS_SUMMARY model=\(spec.id) runs=\(repeats) failed=\(failures)")
        }
    }

    private struct SOAPRun {
        var note: Deliverable
        var metrics: LlamaCppEngine.RunMetrics?
        var wallSeconds: Double
        var peakBytes: UInt64
    }

    private func runSOAP(with spec: LlamaCppModelSpec, visit: Transcription) async throws -> SOAPRun {
        let engine = LlamaCppEngine(configuration: .init(idleTimeout: .seconds(600)))
        let assets = LlamaCppModels.makeAssets(for: spec, modelsDirectory: modelsDirectory, engine: engine)
        try await assets.downloadAssets { _ in }
        XCTAssertTrue(assets.isReady, "\(spec.id): SHA-256 verified")
        let model = LlamaCppModels.makeLanguageModel(spec: spec, engine: engine, assets: assets)
        let availability = await model.availability()
        XCTAssertEqual(availability, .available)

        let databaseFolder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "llamacpp-real-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: databaseFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: databaseFolder) }
        let database = try DatabaseManager(url: databaseFolder.appendingPathComponent("ichirp.sqlite"))
        let transcripts = GRDBTranscriptionStore(database: database)
        let deliverables = GRDBDeliverableStore(database: database)
        let service = DeliverableService(
            transcripts: transcripts, deliverables: deliverables, routingPolicy: { PrivacyRoutingPolicy() })
        try await service.installBuiltInTemplates()
        try await transcripts.insert(visit)

        // Clinical content, on-device engine: allowed with no confirmation.
        let decision = try await service.route(
            transcriptionID: visit.id, templateID: BuiltInTemplates.soapNote.id, model: model)
        guard case .allowed(let route) = decision else {
            XCTFail("\(spec.id): expected allowed, got \(decision)")
            throw CancellationError()
        }
        XCTAssertEqual(route.locality, .onDevice)
        XCTAssertEqual(route.privacyClass, .clinical)

        let footprint = PeakFootprintSampler()
        footprint.start()
        let started = Date()
        var document: Deliverable?
        for try await event in service.generate(
            templateID: BuiltInTemplates.soapNote.id, transcriptionID: visit.id, model: model)
        {
            switch event {
            case .routed(_, let overrideUsed): XCTAssertFalse(overrideUsed)
            case .completed(let deliverable): document = deliverable
            default: break
            }
        }
        let wallSeconds = Date().timeIntervalSince(started)
        let peakBytes = footprint.stop()
        let metrics = await engine.lastRunMetrics
        await engine.unload(reason: "test_done")

        let note = try XCTUnwrap(document, "\(spec.id): a stored document")
        XCTAssertEqual(note.privacyClass, .clinical)
        XCTAssertEqual(note.engineID, LlamaCppLanguageModel.engineID)
        XCTAssertEqual(note.model, spec.id)
        XCTAssertEqual(note.locality, .onDevice)
        return SOAPRun(note: note, metrics: metrics, wallSeconds: wallSeconds, peakBytes: peakBytes)
    }

    /// Writes the timings (and the synthetic note) next to the models, outside the repository.
    private func write(_ run: SOAPRun, spec: LlamaCppModelSpec, name: String, extra: [String: Any] = [:]) throws {
        let metrics = run.metrics
        var result: [String: Any] = [
            "model": spec.id,
            "runtime": "llama.cpp \(LlamaCppRuntimeInfo.pinnedTag)",
            "machine": Self.machine(),
            "load_seconds": metrics?.loadSeconds ?? -1,
            "prompt_tokens": metrics?.promptTokens ?? -1,
            "completion_tokens": metrics?.completionTokens ?? -1,
            "first_token_seconds": metrics?.firstTokenSeconds ?? -1,
            "prompt_tokens_per_second": metrics?.promptTokensPerSecond ?? -1,
            "generation_tokens_per_second": metrics?.generationTokensPerSecond ?? -1,
            "wall_seconds": run.wallSeconds,
            "peak_footprint_mb": Double(run.peakBytes) / 1_048_576,
            "estimated_memory_mb": Double(spec.estimatedMemoryBytes) / 1_048_576,
            "context_tokens": spec.contextTokens,
        ]
        result.merge(extra) { _, new in new }
        let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: modelsDirectory.appendingPathComponent("results-\(name)\(spec.id).json"))
        try run.note.text.write(
            to: modelsDirectory.appendingPathComponent("soap-\(name)\(spec.id).md"), atomically: true, encoding: .utf8)
        print("ONDEVICE_LLM_RESULT \(String(decoding: json, as: UTF8.self))")
    }

    // MARK: - Fixtures (invented; no real patient)

    /// A made-up sick-call visit: two speakers, spoken vitals, a stated assessment and a plan with a dose.
    static func syntheticVisit() -> Transcription {
        let lines: [(String, String)] = [
            ("S1", "Good morning. What brings you in today?"),
            ("S2", "My throat has been really sore for three days, and I had a fever last night."),
            ("S1", "Any cough, runny nose or trouble swallowing?"),
            ("S2", "No cough. It hurts to swallow, though. No runny nose."),
            ("S1", "Any allergies to medications?"),
            ("S2", "No allergies. I don't take anything regularly."),
            ("S1", "Your temperature is 38.4, heart rate 96, blood pressure 118 over 76."),
            ("S1", "Your tonsils are swollen with some white patches, and the glands in your neck are tender."),
            ("S1", "The rapid strep test came back positive."),
            ("S1", "So this looks like strep throat, streptococcal pharyngitis."),
            ("S1", "I'm going to start amoxicillin 500 milligrams by mouth twice a day for ten days."),
            (
                "S1",
                "Use ibuprofen for the pain and fever, drink plenty of fluids, and come back if you can't "
                    + "swallow liquids or it isn't better in 48 hours."
            ),
            ("S2", "Okay, thank you."),
        ]
        var row = Transcription(fileName: "synthetic-visit.m4a", status: .completed, privacyClass: .clinical)
        var segments: [TranscriptSegmentRecord] = []
        var start = 0
        var wordIndex = 0
        for (speaker, text) in lines {
            let words = text.split(separator: " ").count
            let duration = words * 400
            segments.append(
                TranscriptSegmentRecord(
                    startMs: start, endMs: start + duration, speakerId: speaker,
                    speakerLabel: speaker == "S1" ? "Clinician" : "Patient", text: text,
                    wordRange: TranscriptSegmentWordRange(startIndex: wordIndex, endIndexExclusive: wordIndex + words)))
            start += duration + 300
            wordIndex += words
        }
        row.transcriptSegments = segments
        row.speakers = [SpeakerInfo(id: "S1", label: "Clinician"), SpeakerInfo(id: "S2", label: "Patient")]
        row.rawTranscript = lines.map(\.1).joined(separator: " ")
        row.durationMs = start
        return row
    }

    private static func machine() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let brand = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return "\(brand), \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB"
    }
}

/// Samples the process's physical footprint (the number iOS's memory limit counts) every 100 ms.
final class PeakFootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var running = false
    private var thread: Thread?

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    func start() {
        lock.withLock {
            running = true
            peak = Self.footprint()
        }
        let thread = Thread { [self] in
            while lock.withLock({ running }) {
                let now = Self.footprint()
                lock.withLock { peak = max(peak, now) }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        self.thread = thread
        thread.start()
    }

    func stop() -> UInt64 {
        lock.withLock {
            running = false
            return max(peak, Self.footprint())
        }
    }
}

extension NumberFidelityReport {
    fileprivate var dictionary: [String: Any] {
        ["passed": passed, "missing": missing, "unexpected": unexpected]
    }
}
