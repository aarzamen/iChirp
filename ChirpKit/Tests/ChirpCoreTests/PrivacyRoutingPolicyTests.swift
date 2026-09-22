import XCTest
@testable import ChirpCore

final class PrivacyRoutingPolicyTests: XCTestCase {
    private func engine(_ locality: EngineLocality) -> EngineDescriptor {
        EngineDescriptor(
            id: "test.\(locality.rawValue)", kind: .language, provider: "Test", displayName: "Test \(locality.rawValue)",
            locality: locality, license: "MIT")
    }

    func testClinicalAllowsOnDevice() {
        let policy = PrivacyRoutingPolicy()
        XCTAssertTrue(policy.allows(engine(.onDevice), for: .clinical))
    }

    func testClinicalDeniesCloudWithoutOverrideAndAllowsItWithOverride() {
        let policy = PrivacyRoutingPolicy()
        XCTAssertFalse(policy.allows(engine(.cloud), for: .clinical))
        XCTAssertFalse(policy.allows(engine(.cloud), for: .clinical, host: "api.example.com"))
        XCTAssertTrue(policy.allows(engine(.cloud), for: .clinical, userOverride: true))
    }

    func testClinicalLocalNetworkRequiresTrustedHostOrOverride() {
        let policy = PrivacyRoutingPolicy(trustedLocalNetworkHosts: ["mac-studio.local"])
        XCTAssertFalse(policy.allows(engine(.localNetwork), for: .clinical))
        XCTAssertFalse(policy.allows(engine(.localNetwork), for: .clinical, host: "other.local"))
        XCTAssertTrue(policy.allows(engine(.localNetwork), for: .clinical, host: "mac-studio.local"))
        XCTAssertTrue(policy.allows(engine(.localNetwork), for: .clinical, host: "Mac-Studio.local"))
        XCTAssertTrue(policy.allows(engine(.localNetwork), for: .clinical, host: "other.local", userOverride: true))
        XCTAssertFalse(PrivacyRoutingPolicy().allows(engine(.localNetwork), for: .clinical, host: "mac-studio.local"))
    }

    func testGeneralAndPersonalAreAllowedEverywhere() {
        let policy = PrivacyRoutingPolicy()
        for privacy in [PrivacyClass.general, .personal] {
            for locality in [EngineLocality.onDevice, .localNetwork, .cloud] {
                XCTAssertTrue(policy.allows(engine(locality), for: privacy), "\(privacy) on \(locality)")
            }
        }
    }
}
