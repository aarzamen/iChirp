import Foundation
import XCTest

@testable import ChirpCore

final class LanguageModelProviderTests: XCTestCase {
    private func provider(
        _ kind: LanguageModelProviderKind = .ollama,
        _ url: String?,
        model: String = "llama3.1:8b",
        trusted: Bool = false
    ) -> LanguageModelProviderConfiguration {
        LanguageModelProviderConfiguration(
            kind: kind, displayName: "Test", baseURL: url.flatMap(URL.init(string:)), modelName: model,
            trustsLocalNetworkHost: trusted)
    }

    // MARK: LocalNetworkHost

    func testLocalHostsAreRecognized() {
        for host in [
            "localhost", "mac-studio.local", "MAC-STUDIO.LOCAL", "mac.local.", "box.home.arpa", "nas.internal",
            "router.lan", "127.0.0.1", "10.0.0.5", "172.16.0.1", "172.31.255.255", "192.168.1.20", "169.254.3.4",
            "::1", "[::1]", "fd12:3456::1", "fe80::1%en0", "api.localhost",
        ] {
            XCTAssertTrue(LocalNetworkHost.isLocal(host), host)
        }
    }

    func testPublicAndAmbiguousHostsAreNotLocal() {
        for host in [
            "api.anthropic.com", "api.openai.com", "local", ".local", "mac-studio", "8.8.8.8", "172.32.0.1",
            "172.15.0.1", "100.64.0.1", "192.169.0.1", "2001:4860::8888", "evil.local.example.com", "",
            "999.1.1.1", "10.0.0", "localhost.example.com",
        ] {
            XCTAssertFalse(LocalNetworkHost.isLocal(host), host)
        }
    }

    /// Review R1-10: resolvers that follow inet_aton, and the WHATWG URL parser, read a leading-zero octet as octal
    /// ("010" is 8, so "010.0.0.1" is 8.0.0.1, a public address). An ambiguous form is never local.
    func testLeadingZeroAndOtherAmbiguousIPv4FormsAreNotLocal() {
        for host in [
            "010.0.0.1", "0177.0.0.1", "192.168.001.1", "10.0.0.01", "0127.0.0.1", "172.016.0.1", "00.0.0.0",
            "0x7f.0.0.1", "127.1", "2130706433",
        ] {
            XCTAssertFalse(LocalNetworkHost.isLocal(host), host)
        }
        let lookalike = provider(.ollama, "http://010.0.0.1:11434", trusted: true)
        XCTAssertEqual(lookalike.locality, .cloud)
        XCTAssertFalse(lookalike.isTrustedLocalNetworkHost, "it can never be trusted for clinical content")
        XCTAssertThrowsError(try lookalike.validate()) { error in
            XCTAssertEqual(error as? LanguageModelProviderConfiguration.ValidationError, .insecureCloudURL)
        }
        XCTAssertTrue(LocalNetworkHost.isLocal("10.0.0.1"), "a plain single zero is still a number")
        XCTAssertTrue(LocalNetworkHost.isLocal("192.168.0.10"))
    }

    // MARK: Locality is derived, never chosen

    func testLocalityDerivesFromHost() {
        XCTAssertEqual(provider(.appleFoundationModels, nil, model: "").locality, .onDevice)
        XCTAssertEqual(provider(.ollama, "http://mac-studio.local:11434").locality, .localNetwork)
        XCTAssertEqual(provider(.openAICompatible, "http://192.168.1.20:1234/v1").locality, .localNetwork)
        XCTAssertEqual(provider(.anthropic, "https://api.anthropic.com/v1").locality, .cloud)
        // An "Ollama" pointed at a public host is cloud, whatever its kind suggests.
        XCTAssertEqual(provider(.ollama, "https://ollama.example.com").locality, .cloud)
        XCTAssertEqual(provider(.ollama, nil).locality, .cloud)
    }

    func testTrustFlagIsIgnoredForCloudHosts() {
        let cloud = provider(.openAICompatible, "https://api.openai.com/v1", model: "gpt-5", trusted: true)
        XCTAssertFalse(cloud.isTrustedLocalNetworkHost)
        let lan = provider(.ollama, "http://Mac-Studio.local:11434", trusted: true)
        XCTAssertTrue(lan.isTrustedLocalNetworkHost)
        let untrustedLan = provider(.ollama, "http://other.local:11434")

        let policy = PrivacyRoutingPolicy(trustingLocalNetworkHostsOf: [cloud, lan, untrustedLan])
        XCTAssertEqual(policy.trustedLocalNetworkHosts, ["mac-studio.local"])
    }

    // MARK: Validation

    func testValidationRules() {
        XCTAssertNoThrow(try provider(.appleFoundationModels, nil, model: "").validate())
        XCTAssertNoThrow(try provider(.ollama, "http://mac.local:11434").validate())
        XCTAssertNoThrow(try provider(.anthropic, "https://api.anthropic.com/v1", model: "claude-x").validate())

        XCTAssertThrowsError(try provider(.ollama, nil).validate()) {
            XCTAssertEqual($0 as? LanguageModelProviderConfiguration.ValidationError, .missingBaseURL)
        }
        XCTAssertThrowsError(try provider(.anthropic, "http://api.anthropic.com/v1").validate()) {
            XCTAssertEqual($0 as? LanguageModelProviderConfiguration.ValidationError, .insecureCloudURL)
        }
        XCTAssertThrowsError(try provider(.ollama, "ftp://mac.local").validate()) {
            XCTAssertEqual($0 as? LanguageModelProviderConfiguration.ValidationError, .unsupportedScheme)
        }
        XCTAssertThrowsError(try provider(.ollama, "http://user:pw@mac.local:11434").validate()) {
            XCTAssertEqual($0 as? LanguageModelProviderConfiguration.ValidationError, .credentialsInURL)
        }
        XCTAssertThrowsError(try provider(.ollama, "http://mac.local:11434", model: "  ").validate()) {
            XCTAssertEqual($0 as? LanguageModelProviderConfiguration.ValidationError, .missingModelName)
        }
    }

    func testRequiresAPIKey() {
        XCTAssertTrue(provider(.anthropic, "https://api.anthropic.com/v1").requiresAPIKey)
        XCTAssertTrue(provider(.openAICompatible, "https://api.openai.com/v1").requiresAPIKey)
        XCTAssertFalse(provider(.openAICompatible, "http://192.168.1.2:1234/v1").requiresAPIKey)
        XCTAssertFalse(provider(.ollama, "http://mac.local:11434").requiresAPIKey)
        XCTAssertFalse(provider(.appleFoundationModels, nil, model: "").requiresAPIKey)
    }

    // MARK: No secret in the configuration

    func testEncodedConfigurationHasNoKeyField() throws {
        let config = provider(.anthropic, "https://api.anthropic.com/v1", model: "claude-x")
        let json = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        XCTAssertFalse(json.lowercased().contains("key\""), json)
        XCTAssertFalse(json.contains("locality"), "locality is derived, never stored: \(json)")
        XCTAssertEqual(try JSONDecoder().decode(LanguageModelProviderConfiguration.self, from: Data(json.utf8)), config)
    }

    func testEngineIDsAreStable() {
        XCTAssertEqual(LanguageModelProviderKind.appleFoundationModels.engineID, "apple.foundation-models")
        XCTAssertEqual(LanguageModelProviderKind.anthropic.engineID, "http.anthropic")
        XCTAssertEqual(LanguageModelProviderKind.openAICompatible.engineID, "http.openai-compatible")
        XCTAssertEqual(LanguageModelProviderKind.ollama.engineID, "http.ollama")
    }

    // MARK: SecretValue

    func testSecretValueNeverPrintsItself() {
        let secret = SecretValue("sk-ant-SUPERSECRET-123456")
        XCTAssertFalse("\(secret)".contains("SUPERSECRET"))
        XCTAssertFalse(String(reflecting: secret).contains("SUPERSECRET"))
        var dumped = ""
        dump(secret, to: &dumped)
        XCTAssertFalse(dumped.contains("SUPERSECRET"), dumped)
        struct Holder { let key: SecretValue }
        var dumpedHolder = ""
        dump(Holder(key: secret), to: &dumpedHolder)
        XCTAssertFalse(dumpedHolder.contains("SUPERSECRET"), dumpedHolder)
        XCTAssertEqual(secret.reveal(), "sk-ant-SUPERSECRET-123456")
    }

    // MARK: PrivacyClass ordering

    func testStricterClass() {
        XCTAssertEqual(PrivacyClass.personal.stricter(.clinical), .clinical)
        XCTAssertEqual(PrivacyClass.clinical.stricter(.general), .clinical)
        XCTAssertEqual(PrivacyClass.general.stricter(nil), .general)
        XCTAssertEqual(PrivacyClass.general.stricter(.personal), .personal)
    }

    func testLanguageModelErrorKindNamesCarryNoDetail() {
        let error = LanguageModelError.providerError("patient John Doe has chest pain")
        XCTAssertEqual(error.kindName, "provider_error")
    }
}
