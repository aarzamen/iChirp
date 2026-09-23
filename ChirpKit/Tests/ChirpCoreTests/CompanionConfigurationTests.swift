import ChirpCore
import Foundation
import XCTest

final class CompanionConfigurationTests: XCTestCase {
    func testLocalityFollowsTheHost() {
        XCTAssertEqual(CompanionEndpoint(host: "studio.local").locality, .localNetwork)
        XCTAssertEqual(CompanionEndpoint(host: "192.168.1.20").locality, .localNetwork)
        XCTAssertEqual(CompanionEndpoint(host: "voices.example.com").locality, .cloud)
        XCTAssertEqual(CompanionEndpoint(host: "8.8.8.8").locality, .cloud)
    }

    func testTrustCountsOnlyOnTheLocalNetwork() {
        XCTAssertTrue(CompanionEndpoint(host: "studio.local", isTrustedForClinicalText: true).isTrusted)
        XCTAssertFalse(CompanionEndpoint(host: "studio.local").isTrusted)
        XCTAssertFalse(CompanionEndpoint(host: "voices.example.com", isTrustedForClinicalText: true).isTrusted)
    }

    func testBaseURL() {
        XCTAssertEqual(CompanionEndpoint(host: " Studio.Local. ").baseURL?.absoluteString, "http://studio.local:8765")
        XCTAssertEqual(
            CompanionEndpoint(host: "192.168.1.20", port: 9000).baseURL?.absoluteString, "http://192.168.1.20:9000")
        XCTAssertEqual(CompanionEndpoint(host: "fe80::1").baseURL?.absoluteString, "http://[fe80::1]:8765")
        XCTAssertNil(CompanionEndpoint(host: "  ").baseURL)
        XCTAssertNil(CompanionEndpoint(host: "studio.local", port: 0).baseURL)
    }

    func testRoutingTrustsATrustedCompanionOnly() {
        let descriptor = EngineDescriptor(
            id: "companion.speech", kind: .speechSynthesis, provider: "Parakeet companion",
            displayName: "Mac companion", locality: .localNetwork, license: "Apache-2.0")
        let base = PrivacyRoutingPolicy()
        let trusted = base.trusting(CompanionEndpoint(host: "Studio.local", isTrustedForClinicalText: true))
        XCTAssertTrue(trusted.allows(descriptor, for: .clinical, host: "studio.local"))
        XCTAssertFalse(base.trusting(nil).allows(descriptor, for: .clinical, host: "studio.local"))
        XCTAssertFalse(
            base.trusting(CompanionEndpoint(host: "studio.local")).allows(
                descriptor, for: .clinical, host: "studio.local"))
        XCTAssertEqual(
            base.trusting(CompanionEndpoint(host: "voices.example.com", isTrustedForClinicalText: true))
                .trustedLocalNetworkHosts, [], "an internet host is never trusted")
    }
}
