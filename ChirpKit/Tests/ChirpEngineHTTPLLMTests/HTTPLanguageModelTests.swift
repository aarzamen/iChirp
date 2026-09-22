import ChirpCore
import Foundation
import XCTest

@testable import ChirpEngineHTTPLLM

final class HTTPLanguageModelTests: XCTestCase {
    private let key = SecretValue("sk-ant-TESTKEY-0123456789abcdef")

    private func model(
        _ kind: LanguageModelProviderKind,
        _ url: String,
        modelName: String = "test-model",
        key: SecretValue? = nil,
        contextWindow: Int? = nil
    ) -> HTTPLanguageModel {
        let configuration = LanguageModelProviderConfiguration(
            kind: kind, displayName: "Test \(kind.rawValue)", baseURL: URL(string: url), modelName: modelName,
            contextWindowTokens: contextWindow)
        return HTTPLanguageModels.make(
            configuration: configuration, apiKey: key, sessionConfiguration: StubURLProtocol.configuration())
    }

    private let request = GenerationRequest(
        system: "You write documents.", prompt: "Synthetic transcript: the blue heron landed.",
        privacyClass: .personal, maxOutputTokens: 256)

    private func collect(_ stream: AsyncThrowingStream<GenerationEvent, Error>) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    private func text(_ events: [GenerationEvent]) -> String {
        events.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
    }

    private func expectError(
        _ stream: AsyncThrowingStream<GenerationEvent, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Error? {
        do {
            _ = try await collect(stream)
            XCTFail("expected an error", file: file, line: line)
            return nil
        } catch {
            return error
        }
    }

    // MARK: Anthropic

    func testAnthropicRequestShapeAndStreaming() async throws {
        StubURLProtocol.reset { _ in
            .lines([
                "event: message_start",
                #"data: {"type":"message_start","message":{"model":"claude-test-1","usage":{"input_tokens":42,"output_tokens":1}}}"#,
                "",
                #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello "}}"#,
                #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"world."}}"#,
                #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}"#,
                #"data: {"type":"message_stop"}"#,
            ])
        }
        let engine = model(.anthropic, "https://api.anthropic.com/v1", modelName: "claude-test", key: key)
        let events = try await collect(engine.generate(request))

        XCTAssertEqual(text(events), "Hello world.")
        XCTAssertEqual(events.last, .finished)
        XCTAssertTrue(
            events.contains(
                .usage(
                    GenerationUsage(
                        promptTokens: 42, completionTokens: 7, model: "claude-test-1", stopReason: "end_turn"))))

        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertEqual(sent.url.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.headers["x-api-key"], key.reveal())
        XCTAssertEqual(sent.headers["anthropic-version"], "2023-06-01")
        let json = try XCTUnwrap(sent.json)
        XCTAssertEqual(json["model"] as? String, "claude-test")
        XCTAssertEqual(json["system"] as? String, "You write documents.")
        XCTAssertEqual(json["max_tokens"] as? Int, 256)
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertNil(json["temperature"])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "user", "content": request.prompt]])
    }

    func testAnthropicStreamWithoutMessageStopIsTruncationError() async {
        StubURLProtocol.reset { _ in
            .lines([#"data: {"type":"content_block_delta","delta":{"text":"Partial"}}"#])
        }
        let engine = model(.anthropic, "https://api.anthropic.com/v1", key: key)
        let error = await expectError(engine.generate(request))
        guard case .streamingError = error as? LanguageModelError else {
            return XCTFail("expected streamingError, got \(String(describing: error))")
        }
    }

    func testAnthropicAuthErrorIsScrubbedOfKeys() async {
        StubURLProtocol.reset { _ in
            .body(
                #"{"error":{"message":"invalid x-api-key: sk-ant-LEAKEDKEY-99999999 rejected"}}"#, status: 401,
                contentType: "application/json")
        }
        let engine = model(.anthropic, "https://api.anthropic.com/v1", key: key)
        let error = await expectError(engine.generate(request))
        guard case .authenticationFailed(let message) = error as? LanguageModelError else {
            return XCTFail("expected authenticationFailed, got \(String(describing: error))")
        }
        XCTAssertFalse(message?.contains("LEAKEDKEY") ?? true, message ?? "")
    }

    func testCloudProviderWithoutKeyIsUnavailableAndSendsNothing() async {
        StubURLProtocol.reset { _ in .body("unexpected") }
        let engine = model(.anthropic, "https://api.anthropic.com/v1", key: nil)
        let availability = await engine.availability()
        guard case .unavailable(.notConfigured) = availability else {
            return XCTFail("expected notConfigured, got \(availability)")
        }
        let error = await expectError(engine.generate(request))
        guard case .unavailable = error as? LanguageModelError else {
            return XCTFail("expected unavailable, got \(String(describing: error))")
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testInsecureCloudURLIsUnavailableAndSendsNothing() async {
        StubURLProtocol.reset { _ in .body("unexpected") }
        let engine = model(.openAICompatible, "http://api.example.com/v1", key: key)
        let error = await expectError(engine.generate(request))
        guard case .unavailable(.notConfigured) = error as? LanguageModelError else {
            return XCTFail("expected notConfigured, got \(String(describing: error))")
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    // MARK: OpenAI-compatible

    func testLMStudioOnLANUsesMaxTokensNoAuthAndAcceptsEOFWithoutDone() async throws {
        StubURLProtocol.reset { _ in
            .lines([
                #"data: {"model":"qwen","choices":[{"delta":{"role":"assistant"}}]}"#,
                #"data: {"model":"qwen","choices":[{"delta":{"content":"Blue "}}]}"#,
                #"data: {"model":"qwen","choices":[{"delta":{"content":"heron."},"finish_reason":"stop"}]}"#,
            ])
        }
        let engine = model(.openAICompatible, "http://192.168.1.20:1234/v1", modelName: "gpt-5-lookalike")
        XCTAssertEqual(engine.descriptor.locality, .localNetwork)
        XCTAssertEqual(engine.endpointHost, "192.168.1.20")
        let events = try await collect(engine.generate(request))
        XCTAssertEqual(text(events), "Blue heron.")
        XCTAssertEqual(events.last, .finished)

        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.url.absoluteString, "http://192.168.1.20:1234/v1/chat/completions")
        XCTAssertNil(sent.headers["Authorization"])
        let json = try XCTUnwrap(sent.json)
        XCTAssertEqual(json["max_tokens"] as? Int, 256)
        XCTAssertNil(json["max_completion_tokens"])
        XCTAssertNil(json["stream_options"])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
    }

    func testOpenAICloudUsesNewTokenParameterUsageAndRequiresDone() async throws {
        StubURLProtocol.reset { _ in
            .lines([
                #"data: {"model":"gpt-5.5","choices":[{"delta":{"content":"Done "}}]}"#,
                #"data: {"model":"gpt-5.5","choices":[{"delta":{"content":"here."},"finish_reason":"stop"}]}"#,
                #"data: {"model":"gpt-5.5","choices":[],"usage":{"prompt_tokens":11,"completion_tokens":3}}"#,
                "data: [DONE]",
            ])
        }
        let engine = model(.openAICompatible, "https://api.openai.com/v1", modelName: "gpt-5.5", key: key)
        let events = try await collect(engine.generate(request))
        XCTAssertEqual(text(events), "Done here.")
        XCTAssertTrue(
            events.contains(
                .usage(GenerationUsage(promptTokens: 11, completionTokens: 3, model: "gpt-5.5", stopReason: "stop"))))
        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.headers["Authorization"], "Bearer \(key.reveal())")
        let json = try XCTUnwrap(sent.json)
        XCTAssertEqual(json["max_completion_tokens"] as? Int, 256)
        XCTAssertNil(json["max_tokens"])
        XCTAssertEqual((json["stream_options"] as? [String: Bool])?["include_usage"], true)

        // Strict host: EOF without [DONE] is a truncated response.
        StubURLProtocol.reset { _ in
            .lines([#"data: {"choices":[{"delta":{"content":"Cut"}}]}"#])
        }
        let error = await expectError(engine.generate(request))
        guard case .streamingError = error as? LanguageModelError else {
            return XCTFail("expected streamingError, got \(String(describing: error))")
        }
    }

    func testMidStreamErrorFrameAndContextOverflow() async {
        StubURLProtocol.reset { _ in
            .lines([
                "event: error",
                #"data: {"error":{"message":"x"},"message":"The number of tokens to keep from the initial prompt is greater than the context length"}"#,
            ])
        }
        let engine = model(.openAICompatible, "http://mac-studio.local:1234/v1")
        let error = await expectError(engine.generate(request))
        XCTAssertEqual(error as? LanguageModelError, .contextTooLong)

        StubURLProtocol.reset { _ in
            .body(
                #"{"error":{"message":"This model's maximum context length is 4096 tokens"}}"#, status: 400,
                contentType: "application/json")
        }
        let httpError = await expectError(engine.generate(request))
        XCTAssertEqual(httpError as? LanguageModelError, .contextTooLong)
    }

    func testEmptyStreamIsAnError() async {
        StubURLProtocol.reset { _ in .lines(["data: [DONE]"]) }
        let engine = model(.openAICompatible, "http://mac.local:1234/v1")
        let error = await expectError(engine.generate(request))
        guard case .streamingError = error as? LanguageModelError else {
            return XCTFail("expected streamingError, got \(String(describing: error))")
        }
    }

    // MARK: Ollama

    func testOllamaUsesNativeChatAndSendsNumCtxEqualToTheBudgetedWindow() async throws {
        StubURLProtocol.reset { _ in
            .lines(
                [
                    #"{"model":"llama3.1:8b","message":{"role":"assistant","content":"Heron "},"done":false}"#,
                    #"{"model":"llama3.1:8b","message":{"role":"assistant","content":"notes."},"done":false}"#,
                    #"{"model":"llama3.1:8b","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","prompt_eval_count":30,"eval_count":4}"#,
                ], contentType: "application/x-ndjson")
        }
        let engine = model(.ollama, "http://mac-studio.local:11434/v1", modelName: "llama3.1:8b")
        let window = await engine.contextWindowTokens()
        XCTAssertEqual(window, 8_192)
        let events = try await collect(engine.generate(request))
        XCTAssertEqual(text(events), "Heron notes.")
        XCTAssertTrue(
            events.contains(
                .usage(
                    GenerationUsage(promptTokens: 30, completionTokens: 4, model: "llama3.1:8b", stopReason: "stop"))))

        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.url.absoluteString, "http://mac-studio.local:11434/api/chat")
        let json = try XCTUnwrap(sent.json)
        let options = try XCTUnwrap(json["options"] as? [String: Int])
        XCTAssertEqual(options["num_ctx"], 8_192)
        XCTAssertEqual(options["num_predict"], 256)
        XCTAssertEqual(json["think"] as? Bool, false)

        // A configured window is both the budget and num_ctx.
        StubURLProtocol.reset { _ in
            .lines([#"{"message":{"content":"ok"},"done":true}"#], contentType: "application/x-ndjson")
        }
        let wide = model(.ollama, "http://mac-studio.local:11434", contextWindow: 32_768)
        let wideWindow = await wide.contextWindowTokens()
        XCTAssertEqual(wideWindow, 32_768)
        _ = try await collect(wide.generate(request))
        let wideOptions = try XCTUnwrap(StubURLProtocol.requests.first?.json?["options"] as? [String: Int])
        XCTAssertEqual(wideOptions["num_ctx"], 32_768)
    }

    func testOllamaErrorLineIsSurfaced() async {
        StubURLProtocol.reset { _ in
            .lines([#"{"error":"model 'nope' not found"}"#], contentType: "application/x-ndjson")
        }
        let engine = model(.ollama, "http://mac.local:11434")
        let error = await expectError(engine.generate(request))
        guard case .modelNotFound = error as? LanguageModelError else {
            return XCTFail("expected modelNotFound, got \(String(describing: error))")
        }
    }

    // MARK: Privacy hardening

    func testRedirectsAreRefusedAndNothingIsForwarded() async {
        StubURLProtocol.reset { request in
            if request.url.host() == "mac-studio.local" {
                return StubResponse(redirectTo: URL(string: "https://collector.example.com/steal")!)
            }
            return .lines([#"{"message":{"content":"leaked"},"done":true}"#])
        }
        let engine = model(.ollama, "http://mac-studio.local:11434")
        let error = await expectError(engine.generate(request))
        XCTAssertEqual(error as? LanguageModelError, .redirectRefused)
        let hosts = StubURLProtocol.requests.map { $0.url.host() }
        XCTAssertEqual(hosts, ["mac-studio.local"], "the body must never reach the redirect target")
    }

    func testModelDescriptionNeverShowsTheKey() {
        let engine = model(.anthropic, "https://api.anthropic.com/v1", key: key)
        var dumped = ""
        dump(engine, to: &dumped)
        XCTAssertFalse(dumped.contains("TESTKEY"), dumped)
        XCTAssertFalse("\(engine)".contains("TESTKEY"))
        XCTAssertFalse(String(reflecting: engine).contains("TESTKEY"))
    }

    func testDescriptorsAndRegistration() throws {
        let cloud = model(.anthropic, "https://api.anthropic.com/v1", key: key)
        XCTAssertEqual(cloud.descriptor.id, "http.anthropic")
        XCTAssertEqual(cloud.descriptor.kind, .language)
        XCTAssertEqual(cloud.descriptor.locality, .cloud)
        XCTAssertEqual(cloud.endpointHost, "api.anthropic.com")
        XCTAssertFalse(cloud.descriptor.license.isEmpty)

        let apple = LanguageModelProviderConfiguration(
            kind: .appleFoundationModels, displayName: "Apple", baseURL: nil, modelName: "")
        XCTAssertThrowsError(try HTTPLanguageModels.make(configuration: apple, apiKey: nil))
    }

    func testTestConnectionSendsNoUserContent() async throws {
        StubURLProtocol.reset { _ in
            .body(#"{"id":"x","content":[],"usage":{"input_tokens":1,"output_tokens":1}}"#, contentType: "application/json")
        }
        let engine = model(.anthropic, "https://api.anthropic.com/v1", key: key)
        try await engine.testConnection()
        let json = try XCTUnwrap(StubURLProtocol.requests.first?.json)
        XCTAssertEqual(json["max_tokens"] as? Int, 1)
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertEqual((json["messages"] as? [[String: String]])?.first?["content"], "Hi")
    }

    // MARK: Pure parsing

    func testSSELineParsing() {
        typealias Adapter = OpenAICompatibleLLMHTTPAdapter
        XCTAssertEqual(Adapter.parseSSELine(""), .skip)
        XCTAssertEqual(Adapter.parseSSELine(": keep-alive"), .skip)
        XCTAssertEqual(Adapter.parseSSELine("data: [DONE]"), .done)
        XCTAssertEqual(Adapter.parseSSELine("data:[DONE]"), .done)
        XCTAssertEqual(Adapter.parseSSELine(#"data: {"choices":[{"delta":{"content":"hi"}}]}"#), .content("hi"))
        XCTAssertEqual(Adapter.parseSSELine(#"data: {"error":"boom"}"#), .error("boom"))
        XCTAssertEqual(Adapter.parseSSELine(#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#), .skip)
    }

    func testKeyScrubbing() {
        let scrubbed = LLMHTTPErrorMapper.scrubAPIKeyArtifacts(
            from: "bad sk-proj-ABCDEFGH12345 and Bearer abcdefgh12345678 and key=AAAAAAAAAAAAAAAAAAAA")
        XCTAssertFalse(scrubbed.contains("ABCDEFGH12345"))
        XCTAssertFalse(scrubbed.contains("abcdefgh12345678"))
        XCTAssertFalse(scrubbed.contains("AAAAAAAAAAAAAAAAAAAA"))
    }

    func testRequiresMaxCompletionTokens() {
        typealias Adapter = OpenAICompatibleLLMHTTPAdapter
        XCTAssertTrue(Adapter.requiresMaxCompletionTokens("gpt-5.5"))
        XCTAssertTrue(Adapter.requiresMaxCompletionTokens("openai/gpt-5.6-luna"))
        XCTAssertTrue(Adapter.requiresMaxCompletionTokens("o3-mini"))
        XCTAssertFalse(Adapter.requiresMaxCompletionTokens("gpt-4o"))
        XCTAssertFalse(Adapter.requiresMaxCompletionTokens("llama3"))
        XCTAssertFalse(Adapter.requiresMaxCompletionTokens("omni-model"))
    }
}

/// Opt-in real-server check against LM Studio's OpenAI-compatible server on this Mac. Never starts a server or loads a
/// model: it skips unless `CHIRP_LLM_TESTS=1` is set and `http://localhost:1234/v1/models` already answers with a model.
/// `CHIRP_LLM_TESTS=1 swift test --package-path ChirpKit --filter LMStudioLiveTests`
final class LMStudioLiveTests: XCTestCase {
    func testStreamsFromARunningLMStudio() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CHIRP_LLM_TESTS"] == "1", "set CHIRP_LLM_TESTS=1")
        let probe = LanguageModelProviderConfiguration(
            kind: .openAICompatible, displayName: "LM Studio (this Mac)",
            baseURL: URL(string: "http://localhost:1234/v1"), modelName: "probe")
        let lister = try HTTPLanguageModels.make(configuration: probe, apiKey: nil)
        let models: [String]
        do {
            models = try await lister.listModels()
        } catch {
            throw XCTSkip("LM Studio is not running on localhost:1234 (\(error.localizedDescription))")
        }
        guard let first = models.first else { throw XCTSkip("LM Studio has no model loaded") }

        var configuration = probe
        configuration.modelName = first
        let engine = try HTTPLanguageModels.make(configuration: configuration, apiKey: nil)
        XCTAssertEqual(engine.descriptor.locality, .localNetwork)
        var text = ""
        var finished = false
        let request = GenerationRequest(
            system: "Reply with one word.", prompt: "Say the word heron.", privacyClass: .general,
            maxOutputTokens: 200)
        for try await event in engine.generate(request) {
            if case .text(let delta) = event { text += delta }
            if event == .finished { finished = true }
        }
        XCTAssertTrue(finished)
        XCTAssertFalse(text.isEmpty)
    }
}
