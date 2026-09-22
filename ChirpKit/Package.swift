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
        .library(name: "ChirpFeatures", targets: ["ChirpFeatures"]),
        .library(name: "ChirpUI", targets: ["ChirpUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.16.1"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(name: "ChirpCore"),
        .target(name: "ChirpText", dependencies: ["ChirpCore"]),
        .target(name: "ChirpExport", dependencies: ["ChirpCore", "ChirpText"]),
        .target(name: "ChirpStore", dependencies: ["ChirpCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "ChirpAudio", dependencies: ["ChirpCore"]),
        .target(name: "ChirpEngineFluidAudio", dependencies: ["ChirpCore", .product(name: "FluidAudio", package: "FluidAudio")]),
        .target(name: "ChirpFeatures", dependencies: ["ChirpCore", "ChirpText", "ChirpExport"]),
        .target(name: "ChirpUI", dependencies: ["ChirpCore"]),
        .testTarget(name: "ChirpCoreTests", dependencies: ["ChirpCore"]),
        .testTarget(name: "ChirpTextTests", dependencies: ["ChirpText"]),
        .testTarget(name: "ChirpExportTests", dependencies: ["ChirpExport"]),
        .testTarget(name: "ChirpStoreTests", dependencies: ["ChirpStore"]),
        .testTarget(name: "ChirpAudioTests", dependencies: ["ChirpAudio"], resources: [.copy("Fixtures")]),
        .testTarget(name: "ChirpEngineFluidAudioTests", dependencies: ["ChirpEngineFluidAudio"], resources: [.copy("Fixtures")]),
        .testTarget(name: "ChirpFeaturesTests", dependencies: ["ChirpFeatures"]),
    ],
    swiftLanguageModes: [.v6]
)
