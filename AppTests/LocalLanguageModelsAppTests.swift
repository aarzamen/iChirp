import ChirpCore
import ChirpFeatures
import UIKit
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

/// Review N1: `AppEnvironment.init` runs during `iChirpApp.init` (`@State … = AppEnvironment.shared`), before UIKit
/// has finished its own launch sequence, so `observeLifecycle` cannot read `UIApplication.shared.applicationState`
/// to tell a background launch (a continued-processing relaunch, a background download event) apart from a
/// foreground one — a throwaway probe app showed the read comes back `.active` either way. It must seed the runtime
/// as backgrounded and rely on the transition every launch actually posts: `willEnterForegroundNotification` fires
/// once UIKit's own sequence reaches the active state, even on a fresh foreground launch, the same notification a
/// resume from the background already uses.
@MainActor
final class LocalLanguageModelsLifecycleAppTests: XCTestCase {
    func testLifecycleSeedsBackgroundThenTheForegroundNotificationRestoresIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "local-llm-lifecycle-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = AppLocalLanguageModels(modelsDirectory: folder)
        try XCTSkipIf(local.runtimeProblem != nil, "llama.cpp is not in this build")

        local.observeLifecycle()
        XCTAssertFalse(
            local.debugIsForeground,
            "a launch straight into the background must not be reported as available, and App.init cannot yet tell "
                + "it apart from a foreground launch")

        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        XCTAssertTrue(
            local.debugIsForeground,
            "every foreground launch posts this notification once UIKit reaches the active state")
    }
}
