import ChirpCore
import ChirpFeatures
import XCTest

@testable import iChirp

/// Review minor 10: the Transform chip "Runs on this iPhone" and the missing "will ask before sending" note rely on
/// `LanguageModelChoice(localModel:)` asserting `.onDevice`. Pin that every offered id really builds an on-device
/// engine with no host, which the router then allows for clinical content without a confirmation.
@MainActor
final class LocalLanguageModelsAppTests: XCTestCase {
    func testEveryOfferedSmallModelIsAnOnDeviceEngineWithNoHost() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "local-llm-app-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = AppLocalLanguageModels(modelsDirectory: folder)
        let factory = AppLanguageModelFactory(local: local)
        try XCTSkipIf(factory.localModelOptions.isEmpty, "llama.cpp is not in this build")
        for option in factory.localModelOptions {
            let model = try factory.makeLocalModel(id: option.id)
            let choice = LanguageModelChoice(localModel: option)
            XCTAssertEqual(model.descriptor.locality, .onDevice, option.id)
            XCTAssertEqual(choice.locality, model.descriptor.locality, option.id)
            XCTAssertNil(model.endpointHost, option.id)
            XCTAssertNil(choice.host, option.id)
            XCTAssertTrue(
                PrivacyRoutingPolicy().allows(model.descriptor, for: .clinical, host: nil, userOverride: false),
                option.id)
        }
    }
}
