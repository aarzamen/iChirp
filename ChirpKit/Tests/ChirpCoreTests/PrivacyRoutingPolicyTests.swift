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

    /// Review R1-12: every class × locality × host (trusted, untrusted, none) × override case, against a literal truth
    /// table. A host the person trusted never unlocks a cloud engine, and an on-device engine needs nothing.
    func testTheFullRoutingMatrix() {
        enum Host: CaseIterable {
            case trusted, untrusted, none

            var name: String? {
                switch self {
                case .trusted: "mac-studio.local"
                case .untrusted: "other.local"
                case .none: nil
                }
            }
        }
        // Clinical content: (allowed without the override, allowed with it), per locality and host.
        let clinical: [EngineLocality: [Host: (plain: Bool, overridden: Bool)]] = [
            .onDevice: [.trusted: (true, true), .untrusted: (true, true), .none: (true, true)],
            .localNetwork: [.trusted: (true, true), .untrusted: (false, true), .none: (false, true)],
            .cloud: [.trusted: (false, true), .untrusted: (false, true), .none: (false, true)],
        ]
        let policy = PrivacyRoutingPolicy(trustedLocalNetworkHosts: ["mac-studio.local"])
        var cases = 0
        for privacy in PrivacyClass.allCases {
            for locality in [EngineLocality.onDevice, .localNetwork, .cloud] {
                for host in Host.allCases {
                    for userOverride in [false, true] {
                        let expected: Bool
                        if privacy == .clinical, let row = clinical[locality]?[host] {
                            expected = userOverride ? row.overridden : row.plain
                        } else {
                            expected = true
                        }
                        let allowed = policy.allows(
                            engine(locality), for: privacy, host: host.name, userOverride: userOverride)
                        XCTAssertEqual(
                            allowed, expected, "\(privacy) on \(locality), host \(host), override \(userOverride)")
                        cases += 1
                    }
                }
            }
        }
        XCTAssertEqual(cases, 54)
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
