import ChirpCore
import ChirpText
import Foundation

/// One recording the benchmark transcribes. `referenceText` is the known transcript (the synthetic reference set);
/// nil for a person's own file, which then gets speed and memory but no word error rate.
public struct ASRBenchmarkItem: Sendable, Equatable, Identifiable, Codable {
    public var id: String
    public var title: String
    public var audioURL: URL
    public var referenceText: String?

    public init(id: String, title: String, audioURL: URL, referenceText: String?) {
        self.id = id
        self.title = title
        self.audioURL = audioURL
        self.referenceText = referenceText
    }
}

/// The synthetic reference set's manifest (`asr-benchmark-reference.json` next to the `asr-bench-*.m4a` audio, written
/// by `scripts/make_benchmark_audio.sh`; the app bundles it from `App/Resources/Benchmark`).
public struct ASRBenchmarkReferenceSet: Codable, Sendable, Equatable {
    public static let manifestName = "asr-benchmark-reference.json"

    public struct Entry: Codable, Sendable, Equatable {
        public var id: String
        public var file: String
        public var voice: String
        public var text: String
    }

    public var version: Int
    public var entries: [Entry]

    /// Reads the manifest in `folder` and resolves each entry's audio file there.
    public static func load(from folder: URL) throws -> [ASRBenchmarkItem] {
        let data = try Data(contentsOf: folder.appendingPathComponent(manifestName))
        let set = try JSONDecoder().decode(ASRBenchmarkReferenceSet.self, from: data)
        return set.entries.map {
            ASRBenchmarkItem(
                id: $0.id, title: "\($0.id) (\($0.voice))", audioURL: folder.appendingPathComponent($0.file),
                referenceText: $0.text)
        }
    }
}

/// An engine the benchmark can run: its registry key, a name and the instance.
public struct ASRBenchmarkEngine: Sendable {
    public var key: SpeechEngineVariantKey
    public var name: String
    public var engine: any SpeechEngine

    public init(key: SpeechEngineVariantKey, name: String, engine: any SpeechEngine) {
        self.key = key
        self.name = name
        self.engine = engine
    }
}

/// One engine × one recording.
public struct ASRBenchmarkResult: Sendable, Equatable, Codable, Identifiable {
    public var id: String { "\(engineKey)|\(itemID)" }
    public var engineKey: String
    public var engineName: String
    public var itemID: String
    public var itemTitle: String
    public var audioSeconds: Double
    /// Nil without a reference text or when the run failed.
    public var wordErrorRate: WordErrorRate?
    /// Transcription time ÷ audio length (lower is faster; 0.1 = ten times faster than real time).
    public var realTimeFactor: Double?
    public var transcribeMs: Int?
    /// The engine's model load after the benchmark unloaded it (only on its first recording; nil after). The very
    /// first Core ML compile after install is slower and is not what this measures.
    public var loadMs: Int?
    /// The app's peak physical footprint while this engine loaded and ran (bytes); nil where it cannot be read.
    /// Apple Speech runs in a system process, so its own memory is not included.
    public var peakMemoryBytes: UInt64?
    /// fix/speech-memory-fit: what iOS let the app use (`os_proc_available_memory`) right before this pass's model
    /// load, inside the job's slot; nil without a load attempt or where the system does not say (Mac, Simulator).
    public var availableMemoryBeforeLoadBytes: UInt64?
    /// fix/speech-memory-fit: the app's peak physical footprint during the load alone (on a first load, the Core ML
    /// compile); nil without a load attempt. Minus `footprintBeforeLoadBytes`, it is how much the load raised the
    /// app's memory: the number that replaces a registry row's first-load peak placeholder.
    public var loadPeakMemoryBytes: UInt64?
    /// fix/speech-memory-fit: the app's physical footprint right before the load.
    public var footprintBeforeLoadBytes: UInt64?
    public var hypothesis: String?
    public var error: String?
}

/// A complete benchmark run: where and when, and every result.
public struct ASRBenchmarkRun: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var startedAt: Date
    public var device: String
    public var appBuild: String
    public var results: [ASRBenchmarkResult]

    public init(id: UUID = UUID(), startedAt: Date, device: String, appBuild: String, results: [ASRBenchmarkResult]) {
        self.id = id
        self.startedAt = startedAt
        self.device = device
        self.appBuild = appBuild
        self.results = results
    }

    /// Per engine, in run order: corpus WER over the items with a reference, total audio ÷ total transcription time
    /// as a real-time factor, the load time and the highest peak memory.
    public struct EngineSummary: Sendable, Equatable, Identifiable {
        public var id: String { engineKey }
        public var engineKey: String
        public var engineName: String
        public var wordErrorRate: WordErrorRate?
        public var realTimeFactor: Double?
        public var loadMs: Int?
        public var peakMemoryBytes: UInt64?
        /// The first load attempt's reading, load-only peak and footprint before it (fix/speech-memory-fit).
        public var availableMemoryBeforeLoadBytes: UInt64?
        public var loadPeakMemoryBytes: UInt64?
        public var footprintBeforeLoadBytes: UInt64?
        public var failures: Int
    }

    public var summaries: [EngineSummary] {
        var order: [String] = []
        var grouped: [String: [ASRBenchmarkResult]] = [:]
        for result in results {
            if grouped[result.engineKey] == nil { order.append(result.engineKey) }
            grouped[result.engineKey, default: []].append(result)
        }
        return order.map { key in
            let rows = grouped[key] ?? []
            let scored = rows.compactMap(\.wordErrorRate)
            let timed = rows.filter { $0.transcribeMs != nil }
            let audio = timed.reduce(0) { $0 + $1.audioSeconds }
            let spent = timed.reduce(0) { $0 + Double($1.transcribeMs ?? 0) / 1_000 }
            return EngineSummary(
                engineKey: key, engineName: rows.first?.engineName ?? key,
                wordErrorRate: scored.isEmpty ? nil : WordErrorRate.corpus(scored),
                realTimeFactor: audio > 0 && !timed.isEmpty ? spent / audio : nil,
                loadMs: rows.compactMap(\.loadMs).first,
                peakMemoryBytes: rows.compactMap(\.peakMemoryBytes).max(),
                availableMemoryBeforeLoadBytes: rows.compactMap(\.availableMemoryBeforeLoadBytes).first,
                loadPeakMemoryBytes: rows.compactMap(\.loadPeakMemoryBytes).first,
                footprintBeforeLoadBytes: rows.compactMap(\.footprintBeforeLoadBytes).first,
                failures: rows.filter { $0.error != nil }.count)
        }
    }
}

/// Progress for the screen.
public struct ASRBenchmarkProgress: Sendable, Equatable {
    public var engineName: String
    public var itemTitle: String
    public var completed: Int
    public var total: Int
}

/// Runs engines over recordings one at a time, each engine's load and passes through the scheduler's background slot,
/// and measures word error rate, real-time factor, load time and peak memory (M7 Step 6, plan 016).
///
/// - Every recording is normalized to 16 kHz mono once, then shared by all engines; the temporary WAVs are deleted.
/// - Before and after each engine the runner unloads it (`SpeechEngineUnloading`) so load time and memory are its own.
/// - fix/speech-memory-fit: right before each load it reads `availableMemory` (the memory iOS lets the app use) and it
///   samples the peak footprint during the load alone, for the device numbers that replace the registry's first-load
///   peak placeholders. An engine that refuses a load that would not fit reports that refusal as the pass's error.
/// - Privacy routing runs first: a person's own file is treated as clinical (only on-device engines), the synthetic
///   set as general. Engines whose model is not on disk are reported, never downloaded.
public struct ASRBenchmarkRunner: Sendable {
    public typealias MemoryReader = @Sendable () -> UInt64?

    private let scheduler: SpeechJobScheduler
    private let normalizer: any AudioNormalizing
    private let memory: MemoryReader
    private let availableMemory: MemoryReader
    private let routing: PrivacyRoutingPolicy
    private let workDirectory: URL
    private let sampleInterval: Duration

    /// - Parameters:
    ///   - memory: the app's physical footprint (`MemoryProbe.physicalFootprintBytes` in the app).
    ///   - availableMemory: what iOS lets the app use now (`MemoryProbe.availableBytes`), read before each load.
    public init(
        scheduler: SpeechJobScheduler,
        normalizer: any AudioNormalizing,
        memory: @escaping MemoryReader,
        availableMemory: @escaping MemoryReader = { nil },
        routing: PrivacyRoutingPolicy = PrivacyRoutingPolicy(),
        workDirectory: URL = FileManager.default.temporaryDirectory,
        sampleInterval: Duration = .milliseconds(100)
    ) {
        self.scheduler = scheduler
        self.normalizer = normalizer
        self.memory = memory
        self.availableMemory = availableMemory
        self.routing = routing
        self.workDirectory = workDirectory
        self.sampleInterval = sampleInterval
    }

    public func run(
        engines: [ASRBenchmarkEngine],
        items: [ASRBenchmarkItem],
        progress: @escaping @Sendable (ASRBenchmarkProgress) -> Void = { _ in }
    ) async throws -> [ASRBenchmarkResult] {
        let folder = workDirectory.appendingPathComponent("asr-benchmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Normalize once; a recording that cannot be read is reported for every engine.
        var prepared: [(item: ASRBenchmarkItem, audio: NormalizedAudio?, error: String?)] = []
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            let output = folder.appendingPathComponent("item-\(index).wav")
            do {
                prepared.append(
                    (item, try await normalizer.normalize(sourceURL: item.audioURL, outputURL: output), nil))
            } catch {
                if error is CancellationError { throw error }
                prepared.append((item, nil, "Could not read this recording: \(error.localizedDescription)"))
            }
        }

        var results: [ASRBenchmarkResult] = []
        let total = engines.count * items.count
        for entry in engines {
            try Task.checkCancellation()
            await (entry.engine as? any SpeechEngineUnloading)?.unloadModels()
            let status = await entry.engine.assetStatus()
            let ready: Bool
            if case .ready = status { ready = true } else { ready = false }
            var loaded = false
            for (item, audio, readError) in prepared {
                try Task.checkCancellation()
                progress(
                    ASRBenchmarkProgress(
                        engineName: entry.name, itemTitle: item.title, completed: results.count, total: total))
                var result = ASRBenchmarkResult(
                    engineKey: entry.key.description, engineName: entry.name, itemID: item.id, itemTitle: item.title,
                    audioSeconds: Double(audio?.durationMs ?? 0) / 1_000)
                let privacy: PrivacyClass = item.referenceText == nil ? .clinical : .general
                if let readError {
                    result.error = readError
                } else if !routing.allows(entry.engine.descriptor, for: privacy) {
                    result.error = "Privacy routing does not allow \(entry.name) for this recording."
                } else if !ready {
                    result.error = "Model not downloaded. Download it in Settings → Speech engines."
                } else if let audio {
                    await measure(entry, audio: audio, reference: item.referenceText, load: !loaded, into: &result)
                    // Load time is measured once per engine, on the first pass whose load succeeded.
                    if result.error == nil || result.loadMs != nil { loaded = true }
                }
                results.append(result)
            }
            await (entry.engine as? any SpeechEngineUnloading)?.unloadModels()
        }
        progress(ASRBenchmarkProgress(engineName: "", itemTitle: "", completed: results.count, total: total))
        return results
    }

    /// One engine × one recording inside the background slot: optional load, the pass, and the peak footprint.
    private func measure(
        _ entry: ASRBenchmarkEngine, audio: NormalizedAudio, reference: String?, load: Bool,
        into result: inout ASRBenchmarkResult
    ) async {
        let memory = self.memory
        let availableMemory = self.availableMemory
        let interval = sampleInterval
        let sampler = Self.samplePeak(memory, every: interval)
        let engine = entry.engine
        let clock = ContinuousClock()
        let loadMemory = LoadMemoryReading()
        do {
            let (loadDuration, passDuration, speech) = try await scheduler.run(.fileTranscription) {
                var loadDuration: Duration?
                if load {
                    // Inside the slot, right before the load: nothing else of the app's speech work runs now.
                    let before = availableMemory()
                    let footprintBefore = memory()
                    let loadSampler = Self.samplePeak(memory, every: interval)
                    let start = clock.now
                    let outcome: Result<Void, any Error>
                    do {
                        try await engine.prepare()
                        outcome = .success(())
                    } catch {
                        outcome = .failure(error)
                    }
                    let elapsed = clock.now - start
                    loadSampler.cancel()
                    loadMemory.set(
                        availableBefore: before, loadPeak: await loadSampler.value, footprintBefore: footprintBefore)
                    try outcome.get()
                    loadDuration = elapsed
                }
                let start = clock.now
                let speech = try await engine.transcribe(fileAt: audio.url, options: .init(), progress: { _ in })
                return (loadDuration, clock.now - start, speech)
            }
            result.loadMs = loadDuration.map(Self.milliseconds)
            result.transcribeMs = Self.milliseconds(passDuration)
            // A person's own recording may be clinical: its text is compared nowhere and kept nowhere.
            result.hypothesis = reference == nil ? nil : speech.text
            if audio.durationMs > 0 {
                result.realTimeFactor = Double(Self.milliseconds(passDuration)) / Double(audio.durationMs)
            }
            if let reference {
                result.wordErrorRate = WordErrorRate.score(reference: reference, hypothesis: speech.text)
            }
        } catch {
            result.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if let reference, (error as? SpeechEngineError) == .emptyTranscript {
                result.wordErrorRate = WordErrorRate.score(reference: reference, hypothesis: "")
            }
        }
        sampler.cancel()
        result.peakMemoryBytes = await sampler.value
        (result.availableMemoryBeforeLoadBytes, result.loadPeakMemoryBytes, result.footprintBeforeLoadBytes) =
            loadMemory.values
    }

    /// Samples `memory` every `interval` until cancelled and returns the highest value (nil if it never read one).
    private static func samplePeak(_ memory: @escaping MemoryReader, every interval: Duration) -> Task<UInt64?, Never> {
        Task.detached(priority: .high) { () -> UInt64? in
            var peak = memory()
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if let value = memory() { peak = max(peak ?? 0, value) }
            }
            if let value = memory() { peak = max(peak ?? 0, value) }
            return peak
        }
    }

    static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1_000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}

/// One load's memory readings, written from inside the scheduler's job and read after it (fix/speech-memory-fit).
private final class LoadMemoryReading: @unchecked Sendable {
    // @unchecked Sendable: `stored` is only touched while `lock` is held.
    private let lock = NSLock()
    private var stored: (availableBefore: UInt64?, loadPeak: UInt64?, footprintBefore: UInt64?) = (nil, nil, nil)

    func set(availableBefore: UInt64?, loadPeak: UInt64?, footprintBefore: UInt64?) {
        lock.withLock { stored = (availableBefore, loadPeak, footprintBefore) }
    }

    var values: (UInt64?, UInt64?, UInt64?) { lock.withLock { stored } }
}

// MARK: - Export

public enum ASRBenchmarkExport {
    public static let csvHeader =
        "run_id,started_at,device,app_build,engine_key,engine,item,audio_s,wer,substitutions,deletions,insertions,"
        + "reference_words,rtf,transcribe_ms,load_ms,peak_memory_mb,error"

    /// One row per result, RFC 4180 quoting.
    public static func csv(_ runs: [ASRBenchmarkRun]) -> String {
        var lines = [csvHeader]
        let formatter = ISO8601DateFormatter()
        for run in runs {
            for result in run.results {
                let wer = result.wordErrorRate
                let fields: [String] = [
                    run.id.uuidString, formatter.string(from: run.startedAt), run.device, run.appBuild,
                    result.engineKey, result.engineName, result.itemID, format(result.audioSeconds, 2),
                    wer.map { format($0.rate, 4) } ?? "", wer.map { "\($0.substitutions)" } ?? "",
                    wer.map { "\($0.deletions)" } ?? "", wer.map { "\($0.insertions)" } ?? "",
                    wer.map { "\($0.referenceWords)" } ?? "", result.realTimeFactor.map { format($0, 4) } ?? "",
                    result.transcribeMs.map(String.init) ?? "", result.loadMs.map(String.init) ?? "",
                    result.peakMemoryBytes.map { format(Double($0) / 1_048_576, 1) } ?? "", result.error ?? "",
                ]
                lines.append(fields.map(quoted).joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `{"format": "ichirp.asr-benchmark/v1", "runs": […]}` with ISO 8601 dates and sorted keys.
    public static func json(_ runs: [ASRBenchmarkRun]) throws -> Data {
        struct Document: Encodable {
            let format = "ichirp.asr-benchmark/v1"
            let runs: [ASRBenchmarkRun]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Document(runs: runs))
    }

    private static func format(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }

    private static func quoted(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
