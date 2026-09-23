import XCTest

@testable import ChirpCore

final class SpeechSynthesisContractTests: XCTestCase {
    func testSpeechSynthesisErrorKindNamesAreDistinctAndContentFree() {
        let errors: [SpeechSynthesisError] = [
            .notConfigured("x"), .unauthorized, .rateLimited, .server(status: 500, message: "secret text"),
            .connectionFailed("x"), .redirectRefused, .unsupportedVoice("x"), .emptyAudio, .privacyRefused,
        ]
        let names = errors.map(\.kindName)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertFalse(names.contains { $0.contains("secret") })
    }

    func testSynthesisRequestCarriesThePrivacyClassForRouting() {
        let request = SynthesisRequest(text: "Hello.", voiceID: "Ryan", privacyClass: .clinical)
        XCTAssertEqual(request.privacyClass, .clinical)
        XCTAssertNil(request.style)
        XCTAssertEqual(EngineKind(rawValue: "speechSynthesis"), .speechSynthesis)
    }
}
