import ChirpCore
import Foundation

/// Where benchmark runs are kept: one JSON file (`ichirp.asr-benchmark/v1`), newest last, the last `limit` runs. No
/// database table (plan 016 refinement: no migration). Holds engine names, timings and the recognized text of the
/// synthetic set; a person's own files contribute only their file name and numbers (their text is not kept).
public actor ASRBenchmarkStore {
    public let fileURL: URL
    private let limit: Int

    public init(fileURL: URL, limit: Int = 20) {
        self.fileURL = fileURL
        self.limit = limit
    }

    /// The app's file: `<library root>/benchmarks/asr-benchmark-runs.json`.
    public static func appDefault(paths: AppPaths) -> ASRBenchmarkStore {
        ASRBenchmarkStore(
            fileURL: paths.root.appendingPathComponent("benchmarks", isDirectory: true)
                .appendingPathComponent("asr-benchmark-runs.json"))
    }

    /// Every saved run, oldest first; an unreadable file reads as none (it is replaced on the next save).
    public func load() -> [ASRBenchmarkRun] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        struct Document: Decodable { let runs: [ASRBenchmarkRun] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Document.self, from: data))?.runs ?? []
    }

    /// Appends `run` and keeps the newest `limit` runs.
    public func append(_ run: ASRBenchmarkRun) throws {
        var runs = load()
        runs.append(Self.stored(run))
        if runs.count > limit { runs.removeFirst(runs.count - limit) }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ASRBenchmarkExport.json(runs).write(to: fileURL, options: .atomic)
    }

    /// A person's own recordings may be clinical: their recognized text is not written to disk.
    static func stored(_ run: ASRBenchmarkRun) -> ASRBenchmarkRun {
        var copy = run
        copy.results = run.results.map { result in
            var result = result
            if result.wordErrorRate == nil { result.hypothesis = nil }
            return result
        }
        return copy
    }
}
