import ChirpCore
import FluidAudio
import XCTest

@testable import ChirpEngineFluidAudio

final class ParakeetEngineDescriptorTests: XCTestCase {
    func testV3DescriptorFacts() {
        let descriptor = ParakeetEngine(variant: .v3).descriptor

        XCTAssertEqual(descriptor.id, "fluidaudio.parakeet-tdt")
        XCTAssertEqual(descriptor.kind, .speech)
        XCTAssertEqual(descriptor.locality, .onDevice)
        XCTAssertFalse(descriptor.license.isEmpty)
        XCTAssertEqual(descriptor.license, "CC-BY-4.0 (model) / Apache-2.0 (FluidAudio)")
        XCTAssertEqual(descriptor.approximateDownloadBytes, 500_000_000)
        XCTAssertTrue(descriptor.providesWordTimestamps)
        XCTAssertEqual(descriptor.supportedLanguages.count, 25)
        XCTAssertEqual(Set(descriptor.supportedLanguages).count, 25, "language codes must be unique")
        XCTAssertTrue(descriptor.supportedLanguages.contains("en"))
        XCTAssertTrue(descriptor.supportedLanguages.contains("uk"))
    }

    func testV2DescriptorIsEnglishOnlyWithTheSameID() {
        let descriptor = ParakeetEngine(variant: .v2).descriptor

        XCTAssertEqual(descriptor.id, "fluidaudio.parakeet-tdt")
        XCTAssertEqual(descriptor.kind, .speech)
        XCTAssertEqual(descriptor.locality, .onDevice)
        XCTAssertFalse(descriptor.license.isEmpty)
        XCTAssertEqual(descriptor.supportedLanguages, ["en"])
    }

    func testDiarizerDescriptorFacts() {
        let descriptor = FluidAudioDiarizer().descriptor

        XCTAssertEqual(descriptor.id, "fluidaudio.offline-diarizer")
        XCTAssertEqual(descriptor.kind, .diarization)
        XCTAssertEqual(descriptor.locality, .onDevice)
        XCTAssertFalse(descriptor.license.isEmpty)
        XCTAssertFalse(descriptor.providesWordTimestamps)
    }

    func testDefaultModelsRootIsFluidAudiosDefaultCache() {
        let expected = MLModelConfigurationUtils.defaultModelsDirectory().standardizedFileURL
        XCTAssertEqual(ParakeetEngine().modelsRoot, expected)
        XCTAssertEqual(FluidAudioDiarizer().modelsRoot, expected)
    }

    func testModelDirectoriesMirrorUpstreamRepoFolderMapping() {
        let root = URL(fileURLWithPath: "/tmp/models", isDirectory: true)
        XCTAssertEqual(
            FluidAudioModelLocations.parakeetDirectory(in: root, variant: .v3).lastPathComponent,
            Repo.parakeetV3.folderName)
        XCTAssertEqual(
            FluidAudioModelLocations.parakeetDirectory(in: root, variant: .v2).lastPathComponent,
            Repo.parakeetV2.folderName)
        XCTAssertEqual(
            FluidAudioModelLocations.diarizerDirectory(in: root).lastPathComponent, Repo.diarizer.folderName)
    }

    func testMakeDefaultFollowsTheParakeetVariantSetting() {
        var settings = TranscriptionSettings()
        settings.parakeetVariant = .v2
        let engines = FluidAudioEngines.makeDefault(settings: settings)

        XCTAssertEqual(engines.speech.variant, .v2)
        XCTAssertEqual(engines.diarizer.descriptor.id, "fluidaudio.offline-diarizer")
    }

    func testLanguageHintMapsToFluidAudioScriptFilterOnlyForV3() {
        XCTAssertEqual(ParakeetEngine.fluidAudioLanguage(forHint: "en-US", variant: .v3), .english)
        XCTAssertEqual(ParakeetEngine.fluidAudioLanguage(forHint: "uk", variant: .v3), .ukrainian)
        XCTAssertNil(ParakeetEngine.fluidAudioLanguage(forHint: "ja", variant: .v3))
        XCTAssertNil(ParakeetEngine.fluidAudioLanguage(forHint: nil, variant: .v3))
        XCTAssertNil(ParakeetEngine.fluidAudioLanguage(forHint: "en", variant: .v2))
    }

    func testASRConfigMirrorsUpstreamOnMacOS() {
        #if os(macOS)
        XCTAssertEqual(ParakeetASRConfig.make(serializationRequired: false).parallelChunkConcurrency, 4)
        XCTAssertEqual(ParakeetASRConfig.make(serializationRequired: true).parallelChunkConcurrency, 1)
        XCTAssertNil(ParakeetASRConfig.encoderComputeUnits(serializationRequired: false))
        XCTAssertEqual(ParakeetASRConfig.encoderComputeUnits(serializationRequired: true), .cpuAndGPU)
        #else
        XCTAssertEqual(ParakeetASRConfig.make().parallelChunkConcurrency, ChirpTuning.parakeetParallelChunks)
        #endif
        XCTAssertEqual(ChirpTuning.parakeetParallelChunks, 2)
    }
}
