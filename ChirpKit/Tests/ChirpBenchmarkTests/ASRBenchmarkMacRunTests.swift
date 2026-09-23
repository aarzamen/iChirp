import ChirpAudio
import ChirpCore
import ChirpEngineAppleSpeech
import ChirpEngineFluidAudio
import ChirpEngineWhisperKit
import ChirpFeatures
import Darwin
import Foundation
import XCTest

/// The benchmark on this Mac: every speech engine over the synthetic reference set (`App/Resources/Benchmark`,
/// `scripts/make_benchmark_audio.sh`), through the same `ASRBenchmarkRunner` the app's screen uses. Opt-in with
/// `CHIRP_BENCHMARK=1`: it downloads any missing model (Parakeet ~0.5 GB, Whisper base ~150 MB, large-v3 turbo
/// ~650 MB; Apple asks macOS for its English model). Writes CSV and JSON to `CHIRP_BENCHMARK_OUT` (default: the
/// temporary folder) and prints one line per engine. `CHIRP_BENCHMARK_ENGINES` limits the engines (comma-separated
/// registry keys, e.g. `apple.speech-transcriber,argmax.whisperkit:base`).
final class ASRBenchmarkMacRunTests: XCTestCase {
    func testRunEveryEngineOverTheReferenceSet() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["CHIRP_BENCHMARK"] == "1", "Set CHIRP_BENCHMARK=1 to run the Mac benchmark.")
        let reference = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("App/Resources/Benchmark", isDirectory: true)
        let items = try ASRBenchmarkReferenceSet.load(from: reference)
        XCTAssertEqual(items.count, 5)

        let whisperModels =
            environment["CHIRP_WHISPER_MODELS_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iChirpTests/WhisperKit", isDirectory: true)
        var engines: [ASRBenchmarkEngine] = [
            ASRBenchmarkEngine(
                key: .init(engineID: ParakeetEngine.engineID, variant: "v3"), name: "Parakeet v3",
                engine: ParakeetEngine(variant: .v3)),
            ASRBenchmarkEngine(
                key: .init(engineID: AppleSpeechEngine.engineID), name: "Apple Speech",
                engine: AppleSpeechEngine(locale: Locale(identifier: "en_US"))),
        ]
        for engine in WhisperKitEngines.makeDefault(modelsDirectory: whisperModels) {
            engines.append(
                ASRBenchmarkEngine(
                    key: .init(engineID: WhisperKitEngine.engineID, variant: engine.variant.rawValue),
                    name: engine.variant.displayName, engine: engine))
        }
        if let only = environment["CHIRP_BENCHMARK_ENGINES"]?.split(separator: ",").map(String.init) {
            engines = engines.filter { only.contains($0.key.description) }
        }
        for entry in engines {
            if let reporting = entry.engine as? any SpeechEngineAvailabilityReporting,
                let reason = await reporting.unavailableReason()
            {
                print("benchmark_skip engine=\(entry.name) reason=\(reason)")
                continue
            }
            if case .ready = await entry.engine.assetStatus() { continue }
            print("benchmark_download engine=\(entry.name)")
            try await entry.engine.downloadAssets { _ in }
        }

        let runner = ASRBenchmarkRunner(
            scheduler: SpeechJobScheduler(), normalizer: AVAudioNormalizer(), memory: Self.physicalFootprint)
        let started = Date()
        let results = try await runner.run(engines: engines, items: items)
        let run = ASRBenchmarkRun(
            startedAt: started, device: Self.deviceDescription(), appBuild: "swift test (ChirpKit)", results: results)

        let out =
            environment["CHIRP_BENCHMARK_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("ichirp-asr-benchmark", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Data(ASRBenchmarkExport.csv([run]).utf8).write(to: out.appendingPathComponent("asr-benchmark-mac.csv"))
        try ASRBenchmarkExport.json([run]).write(to: out.appendingPathComponent("asr-benchmark-mac.json"))
        print("benchmark_out \(out.path)")
        for summary in run.summaries {
            let wer = summary.wordErrorRate.map { String(format: "%.2f%%", $0.rate * 100) } ?? "n/a"
            let rtf = summary.realTimeFactor.map { String(format: "%.3f", $0) } ?? "n/a"
            let memory = summary.peakMemoryBytes.map { "\($0 / 1_048_576) MB" } ?? "n/a"
            print(
                "benchmark_engine name=\(summary.engineName) wer=\(wer) rtf=\(rtf) load_ms=\(summary.loadMs ?? -1) "
                    + "peak=\(memory) failures=\(summary.failures)")
        }
        for result in results where result.error != nil {
            print("benchmark_error engine=\(result.engineName) item=\(result.itemID) error=\(result.error ?? "")")
        }
        XCTAssertFalse(results.isEmpty)
    }

    /// The process's physical footprint (what the system's memory limit counts).
    static let physicalFootprint: @Sendable () -> UInt64? = {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    static func deviceDescription() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let memory = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return "Mac \(String(cString: model)), \(memory) GB, macOS \(os)"
    }
}
