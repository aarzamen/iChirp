// swift-tools-version: 6.2
import Foundation
import PackageDescription

// M6 (ADR-012): Needle 3's runtime, built from needle-rs source by scripts/build_needle.sh into the gitignored
// vendor/NeedleC.xcframework. Linked only when it exists; without it ChirpEngineNeedle reports "not in this build".
let needleRuntimePath = "../vendor/NeedleC.xcframework"
let hasNeedleRuntime = FileManager.default.fileExists(atPath: Context.packageDirectory + "/" + needleRuntimePath)
// M7 (ADR-015): llama.cpp, the on-device small-language-model runtime, built from source by scripts/build_llamacpp.sh
// into the gitignored vendor/llama.xcframework. Linked only when it exists; without it ChirpEngineLlamaCpp reports
// "not in this build".
let llamaRuntimePath = "../vendor/llama.xcframework"
let hasLlamaRuntime = FileManager.default.fileExists(atPath: Context.packageDirectory + "/" + llamaRuntimePath)

let package = Package(
    name: "ChirpKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ChirpCore", targets: ["ChirpCore"]),
        .library(name: "ChirpText", targets: ["ChirpText"]),
        .library(name: "ChirpExport", targets: ["ChirpExport"]),
        .library(name: "ChirpStore", targets: ["ChirpStore"]),
        .library(name: "ChirpAudio", targets: ["ChirpAudio"]),
        .library(name: "ChirpEngineFluidAudio", targets: ["ChirpEngineFluidAudio"]),
        .library(name: "ChirpEngineAppleFM", targets: ["ChirpEngineAppleFM"]),
        .library(name: "ChirpEngineHTTPLLM", targets: ["ChirpEngineHTTPLLM"]),
        .library(name: "ChirpEngineJev", targets: ["ChirpEngineJev"]),
        .library(name: "ChirpEngineVoiceHTTP", targets: ["ChirpEngineVoiceHTTP"]),
        .library(name: "ChirpKeychain", targets: ["ChirpKeychain"]),
        .library(name: "ChirpIngest", targets: ["ChirpIngest"]),
        .library(name: "ChirpFeatures", targets: ["ChirpFeatures"]),
        .library(name: "ChirpUI", targets: ["ChirpUI"]),
        .library(name: "ChirpEngineNeedle", targets: ["ChirpEngineNeedle"]),
        .library(name: "ChirpEngineLlamaCpp", targets: ["ChirpEngineLlamaCpp"]),
        // M7 (plan 016): Apple SpeechTranscriber.
        .library(name: "ChirpEngineAppleSpeech", targets: ["ChirpEngineAppleSpeech"]),
        .library(name: "ChirpEngineWhisperKit", targets: ["ChirpEngineWhisperKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.16.1"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        // M7 (plan 016): WhisperKit. MIT; exact pin (model folder names and the loader have changed between minors).
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", exact: "1.1.0"),
    ],
    targets: [
        .target(name: "ChirpCore", exclude: ["README.md"]),
        .target(name: "ChirpText", dependencies: ["ChirpCore"], exclude: ["README.md"]),
        .target(name: "ChirpExport", dependencies: ["ChirpCore", "ChirpText"], exclude: ["README.md"]),
        .target(name: "ChirpStore", dependencies: ["ChirpCore", "ChirpText", .product(name: "GRDB", package: "GRDB.swift")], exclude: ["README.md"]),
        .target(name: "ChirpAudio", dependencies: ["ChirpCore"], exclude: ["README.md"]),
        .target(name: "ChirpEngineFluidAudio", dependencies: ["ChirpCore", .product(name: "FluidAudio", package: "FluidAudio")], exclude: ["README.md"]),
        .target(name: "ChirpEngineAppleFM", dependencies: ["ChirpCore"], exclude: ["README.md"]),
        .target(name: "ChirpEngineHTTPLLM", dependencies: ["ChirpCore"], exclude: ["README.md"]),
        // M6a (plan 021): Jev, TypeSafe's cloud decision model. ChirpCore only; no SDK.
        .target(name: "ChirpEngineJev", dependencies: ["ChirpCore"], exclude: ["README.md"]),
        // Plan 020: text to speech over HTTP (Grok voices on xAI, the owner's voices on the Mac companion).
        .target(name: "ChirpEngineVoiceHTTP", dependencies: ["ChirpCore"], exclude: ["README.md"]),
        .target(name: "ChirpKeychain", dependencies: ["ChirpCore"], exclude: ["README.md"]),
        // M5: links, podcasts, downloads, YouTube captions and document text. Apple frameworks only, no new dependency.
        .target(name: "ChirpIngest", dependencies: ["ChirpCore"], exclude: ["README.md"]),
        .target(
            name: "ChirpFeatures", dependencies: ["ChirpCore", "ChirpText", "ChirpExport", "ChirpIngest"],
            exclude: ["README.md"],
            // M6: frozen structure-model tool catalogs (soap-meds.v1, dictation-commands.v1).
            resources: [.copy("Resources/StructureCatalogs")]),
        .target(name: "ChirpUI", dependencies: ["ChirpCore"], exclude: ["README.md"]),
        .testTarget(name: "ChirpCoreTests", dependencies: ["ChirpCore"]),
        .testTarget(name: "ChirpTextTests", dependencies: ["ChirpText"]),
        .testTarget(name: "ChirpExportTests", dependencies: ["ChirpExport"]),
        .testTarget(name: "ChirpStoreTests", dependencies: ["ChirpStore", "ChirpText"]),
        .testTarget(name: "ChirpAudioTests", dependencies: ["ChirpAudio"], resources: [.copy("Fixtures")]),
        .testTarget(name: "ChirpEngineFluidAudioTests", dependencies: ["ChirpEngineFluidAudio"], resources: [.copy("Fixtures")]),
        .testTarget(name: "ChirpEngineAppleFMTests", dependencies: ["ChirpEngineAppleFM"]),
        .testTarget(name: "ChirpEngineHTTPLLMTests", dependencies: ["ChirpEngineHTTPLLM"]),
        // ChirpFeatures too: the gated live eval runs the app's own recipes and window through the real engine.
        .testTarget(
            name: "ChirpEngineJevTests", dependencies: ["ChirpEngineJev", "ChirpFeatures"], resources: [.copy("Fixtures")]),
        .testTarget(name: "ChirpEngineVoiceHTTPTests", dependencies: ["ChirpEngineVoiceHTTP"]),
        .testTarget(name: "ChirpKeychainTests", dependencies: ["ChirpKeychain"]),
        .testTarget(name: "ChirpIngestTests", dependencies: ["ChirpIngest"]),
        // Round 3: Fixtures/clinical-safety-corpus.json, the synthetic clinical-safety corpus.
        .testTarget(name: "ChirpFeaturesTests", dependencies: ["ChirpFeatures"], resources: [.copy("Fixtures")]),
        // M6: Needle 3 (structure model) on needle-rs; the NeedleC binary target only when it has been built.
        .target(
            name: "ChirpEngineNeedle", dependencies: ["ChirpCore"] + (hasNeedleRuntime ? ["NeedleC"] : []),
            exclude: ["README.md"]),
        // The opt-in real eval (NeedleEvalRealTests) runs ChirpFeatures' eval runner on the real model.
        .testTarget(name: "ChirpEngineNeedleTests", dependencies: ["ChirpEngineNeedle", "ChirpFeatures"]),
        // M7 (ADR-015): small language models on the iPhone through llama.cpp; the `llama` binary target only when
        // it has been built.
        .target(
            name: "ChirpEngineLlamaCpp", dependencies: ["ChirpCore"] + (hasLlamaRuntime ? ["llama"] : []),
            exclude: ["README.md"]),
        // The opt-in real-model test (CHIRP_ONDEVICE_LLM_TESTS=1) runs a SOAP note through the app's DeliverableService
        // and a real database.
        .testTarget(
            name: "ChirpEngineLlamaCppTests", dependencies: ["ChirpEngineLlamaCpp", "ChirpFeatures", "ChirpStore"]),
        // M7 (plan 016): Apple SpeechTranscriber / SpeechAnalyzer (system framework, no package dependency).
        .target(name: "ChirpEngineAppleSpeech", dependencies: ["ChirpCore"], exclude: ["README.md"]),
        .testTarget(name: "ChirpEngineAppleSpeechTests", dependencies: ["ChirpEngineAppleSpeech"]),
        // M7 (plan 016): WhisperKit (argmax-oss-swift); only the WhisperKit product is linked.
        .target(
            name: "ChirpEngineWhisperKit",
            dependencies: ["ChirpCore", .product(name: "WhisperKit", package: "argmax-oss-swift")],
            exclude: ["README.md"]),
        .testTarget(name: "ChirpEngineWhisperKitTests", dependencies: ["ChirpEngineWhisperKit"]),
        // M7 Step 6: the opt-in Mac benchmark run (CHIRP_BENCHMARK=1) over every speech engine; engines meet only here.
        .testTarget(
            name: "ChirpBenchmarkTests",
            dependencies: [
                "ChirpFeatures", "ChirpAudio", "ChirpEngineFluidAudio", "ChirpEngineAppleSpeech", "ChirpEngineWhisperKit",
            ]),
    ] + (hasNeedleRuntime ? [.binaryTarget(name: "NeedleC", path: needleRuntimePath)] : [])
        + (hasLlamaRuntime ? [.binaryTarget(name: "llama", path: llamaRuntimePath)] : []),
    swiftLanguageModes: [.v6]
)
