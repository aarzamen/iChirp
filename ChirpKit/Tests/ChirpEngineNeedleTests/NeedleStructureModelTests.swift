import ChirpCore
import CryptoKit
import Foundation
import XCTest

@testable import ChirpEngineNeedle

/// Step 2 (plan 015): the engine on a fake runtime and a fake downloader. No network, no model.
final class NeedleStructureModelTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NeedleTests-\(UUID())")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private static let tools = #"[{"name":"add_medication","parameters":{"type":"object","properties":{}}}]"#

    /// A fake pin whose "model" is `payload`.
    private func pin(for payload: Data) -> NeedleModelAssets.Pin {
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return NeedleModelAssets.Pin(
            fileName: "needle3.cact", remoteURL: URL(string: "https://example.invalid/needle3.cact")!, sha256: hash,
            byteCount: Int64(payload.count), revision: "test")
    }

    private func makeModel(
        payload: Data = Data("synthetic model bytes".utf8), servedBytes: Data? = nil,
        runtime: FakeRuntime = FakeRuntime()
    ) -> NeedleStructureModel {
        let assets = NeedleModelAssets(
            modelsDirectory: root, pin: pin(for: payload), fetcher: FakeFetcher(bytes: servedBytes ?? payload))
        return NeedleStructureModel(assets: assets, runtime: runtime, runtimeInBuild: true)
    }

    func testDescriptorIsAnOnDeviceStructureEngine() {
        let model = makeModel()
        XCTAssertEqual(model.descriptor.id, "needle.needle3")
        XCTAssertEqual(model.descriptor.kind, .structure)
        XCTAssertEqual(model.descriptor.locality, .onDevice)
        XCTAssertEqual(model.descriptor.license, "Apache-2.0 (weights) / MIT (runtime)")
        XCTAssertTrue(PrivacyRoutingPolicy().allows(model.descriptor, for: .clinical))
    }

    func testPinnedWeightsAreTheReviewedFile() {
        XCTAssertEqual(NeedleModelAssets.needle3.sha256, "c9d915eca282ed42d1a09b143b592adb4cc6744ffe2d294adf5cfc5548170c38")
        XCTAssertEqual(NeedleModelAssets.needle3.byteCount, 35_335_380)
        XCTAssertTrue(NeedleModelAssets.needle3.remoteURL.absoluteString.contains(NeedleModelAssets.needle3.revision))
    }

    func testExtractBeforeDownloadSaysModelNotDownloaded() async {
        let model = makeModel()
        await XCTAssertThrowsAsync(try await model.extract(jsonSchema: Self.tools, from: "x", privacyClass: .clinical))
        { XCTAssertEqual($0 as? StructureModelError, .modelNotDownloaded("needle.needle3")) }
    }

    func testWithoutTheRuntimeItSaysNotInThisBuild() async throws {
        let assets = NeedleModelAssets(modelsDirectory: root)
        let model = NeedleStructureModel(assets: assets, runtime: FakeRuntime(), runtimeInBuild: false)
        await XCTAssertThrowsAsync(try await model.extract(jsonSchema: Self.tools, from: "x", privacyClass: .general))
        { XCTAssertEqual($0 as? StructureModelError, .notInThisBuild(NeedleRuntimeInfo.notInBuildMessage)) }
    }

    func testDownloadVerifiesTheHashThenExtractReturnsThePayloadConfidenceAndHash() async throws {
        let runtime = FakeRuntime()
        await runtime.answer(
            "<think>A medication was started.</think><tool_call>[{\"name\":\"add_medication\",\"arguments\":{\"drug\":\"lisinopril\"}}]</tool_call>",
            confidence: 0.91)
        let model = makeModel(runtime: runtime)
        let fractions = FractionLog()
        try await model.downloadAssets { fractions.append($0) }
        guard case .ready = await model.assetStatus() else { return XCTFail("model should be ready") }
        XCTAssertEqual(fractions.values.last, 1)

        let output = try await model.extract(
            jsonSchema: Self.tools, from: "Started lisinopril.", privacyClass: .clinical)
        XCTAssertEqual(output.json, #"[{"name":"add_medication","arguments":{"drug":"lisinopril"}}]"#)
        XCTAssertEqual(output.confidence, 0.91, accuracy: 1e-9)
        XCTAssertEqual(output.modelSHA256, model.modelSHA256)
        XCTAssertFalse(output.isAbstention)
        let calls = await runtime.calls
        XCTAssertEqual(calls.map(\.query), ["Started lisinopril."])
        XCTAssertEqual(calls.map(\.tools), [Self.tools])
        let loads = await runtime.loadedURLs
        XCTAssertEqual(loads, [model.assets.modelURL])
    }

    func testEmptyArrayIsADeliberateAbstention() async throws {
        let runtime = FakeRuntime()
        await runtime.answer("<think>None fit.</think><tool_call>[]</tool_call>", confidence: 0.88)
        let model = makeModel(runtime: runtime)
        try await model.downloadAssets { _ in }
        let output = try await model.extract(jsonSchema: Self.tools, from: "Hello there.", privacyClass: .personal)
        XCTAssertTrue(output.isAbstention)
    }

    func testNoToolCallMarkersIsADegenerateGeneration() async throws {
        let runtime = FakeRuntime()
        await runtime.answer("<think>…</think> I am not sure.", confidence: 0.4)
        let model = makeModel(runtime: runtime)
        try await model.downloadAssets { _ in }
        await XCTAssertThrowsAsync(try await model.extract(jsonSchema: Self.tools, from: "x", privacyClass: .general))
        { XCTAssertEqual($0 as? StructureModelError, .noToolCall) }
    }

    func testAHashMismatchKeepsNothingAndReportsFailed() async throws {
        let model = makeModel(servedBytes: Data("tampered bytes!!!!!!!".utf8))
        await XCTAssertThrowsAsync(try await model.downloadAssets { _ in }) {
            XCTAssertEqual($0 as? NeedleModelAssets.AssetError, .hashMismatch)
        }
        guard case .failed = await model.assetStatus() else { return XCTFail("status should be failed") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.assets.modelURL.path))
    }

    func testDeleteUnloadsAndRemovesTheModel() async throws {
        let runtime = FakeRuntime()
        let model = makeModel(runtime: runtime)
        try await model.downloadAssets { _ in }
        try await model.deleteAssets()
        let status = await model.assetStatus()
        XCTAssertEqual(status, .notDownloaded)
        let unloads = await runtime.unloadCount
        XCTAssertEqual(unloads, 1)
    }

    func testEmbedIsUnsupported() async {
        await XCTAssertThrowsAsync(try await makeModel().embed("x")) {
            guard case .unsupported = $0 as? StructureModelError else { return XCTFail("\($0)") }
        }
    }

    func testToolCallParserMatchesNeedleRs() {
        XCTAssertEqual(NeedleToolCallParser.payload(from: "<think>x</think><tool_call> [] </tool_call>"), "[]")
        XCTAssertEqual(NeedleToolCallParser.payload(from: "<tool_call>[{\"name\":\"a\""), "[{\"name\":\"a\"")
        XCTAssertNil(NeedleToolCallParser.payload(from: "<think>only thinking</think>"))
    }
}

// MARK: - Fakes

actor FakeRuntime: NeedleInferring {
    struct Call: Equatable {
        var query: String
        var tools: String
    }

    private(set) var calls: [Call] = []
    private(set) var loadedURLs: [URL] = []
    private(set) var unloadCount = 0
    private var text = "<tool_call>[]</tool_call>"
    private var confidence = 0.9

    func answer(_ text: String, confidence: Double) {
        self.text = text
        self.confidence = confidence
    }

    func load(modelAt url: URL) async throws {
        if loadedURLs.last != url { loadedURLs.append(url) }
    }

    func unload() async { unloadCount += 1 }

    func complete(query: String, toolsJSON: String) async throws -> NeedleCompletion {
        calls.append(Call(query: query, tools: toolsJSON))
        return NeedleCompletion(text: text, confidence: confidence)
    }
}

struct FakeFetcher: NeedleFileFetching {
    let bytes: Data

    func fetch(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID()).cact")
        try bytes.write(to: file)
        progress(0.5)
        progress(1)
        return file
    }
}

final class FractionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func append(_ value: Double) { lock.withLock { storage.append(value) } }
    var values: [Double] { lock.withLock { storage } }
}

func XCTAssertThrowsAsync<T>(
    _ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line,
    _ check: (any Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        check(error)
    }
}
