// swift-tools-version: 6.2
import PackageDescription

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
        .library(name: "ChirpKeychain", targets: ["ChirpKeychain"]),
        .library(name: "ChirpIngest", targets: ["ChirpIngest"]),
        .library(name: "ChirpFeatures", targets: ["ChirpFeatures"]),
        .library(name: "ChirpUI", targets: ["ChirpUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.16.1"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
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
        .target(name: "ChirpKeychain", dependencies: ["ChirpCore"], exclude: ["README.md"]),
        // M5: links, podcasts, downloads, YouTube captions and document text. Apple frameworks only, no new dependency.
        .target(name: "ChirpIngest", dependencies: ["ChirpCore"], exclude: ["README.md"]),
        .target(
            name: "ChirpFeatures", dependencies: ["ChirpCore", "ChirpText", "ChirpExport", "ChirpIngest"],
            exclude: ["README.md"]),
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
        .testTarget(name: "ChirpKeychainTests", dependencies: ["ChirpKeychain"]),
        .testTarget(name: "ChirpIngestTests", dependencies: ["ChirpIngest"]),
        .testTarget(name: "ChirpFeaturesTests", dependencies: ["ChirpFeatures"]),
    ],
    swiftLanguageModes: [.v6]
)
