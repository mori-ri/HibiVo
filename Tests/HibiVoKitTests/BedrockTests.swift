import Foundation
import Testing

@testable import HibiVoKit

@Suite struct AWSSigV4Tests {
    /// "get-vanilla" from the AWS Signature Version 4 test suite.
    @Test func matchesAWSTestSuiteVector() throws {
        var request = URLRequest(url: try #require(URL(string: "https://example.amazonaws.com/")))
        request.httpMethod = "GET"
        let credentials = AWSCredentials(
            accessKeyID: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
        AWSSigV4.sign(
            &request, credentials: credentials, region: "us-east-1", service: "service",
            date: Date(timeIntervalSince1970: 1_440_938_160))  // 2015-08-30T12:36:00Z

        #expect(request.value(forHTTPHeaderField: "X-Amz-Date") == "20150830T123600Z")
        #expect(
            request.value(forHTTPHeaderField: "Authorization")
                == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, "
                + "SignedHeaders=host;x-amz-date, "
                + "Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }

    @Test func sessionTokenIsSentAndSigned() throws {
        var request = URLRequest(url: try #require(URL(string: "https://example.amazonaws.com/")))
        AWSSigV4.sign(
            &request, credentials: AWSCredentials(accessKeyID: "AK", secretAccessKey: "SK", sessionToken: "TOKEN"),
            region: "us-east-1", service: "service")
        #expect(request.value(forHTTPHeaderField: "X-Amz-Security-Token") == "TOKEN")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("x-amz-security-token") == true)
    }
}

@Suite struct BedrockCleanupProviderTests {
    let date = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func apiKeyRequestTargetsInvokeModelWithBearerToken() throws {
        let sut = BedrockCleanupProvider(region: "ap-northeast-1", authentication: .apiKey("BEDROCK-KEY"))
        let request = try sut.makeURLRequest(system: "sys", user: "usr", model: "global.anthropic.claude-opus-4-6-v1")
        #expect(
            request.url?.absoluteString
                == "https://bedrock-runtime.ap-northeast-1.amazonaws.com/model/global.anthropic.claude-opus-4-6-v1/invoke"
        )
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer BEDROCK-KEY")
        #expect(request.value(forHTTPHeaderField: "X-Amz-Date") == nil)
    }

    @Test func modelIDWithColonIsPercentEncoded() throws {
        let sut = BedrockCleanupProvider(region: "us-east-1", authentication: .apiKey("k"))
        let url = try #require(sut.endpoint(model: "jp.anthropic.claude-sonnet-4-5-20250929-v1:0"))
        #expect(url.absoluteString.hasSuffix("/model/jp.anthropic.claude-sonnet-4-5-20250929-v1%3A0/invoke"))
    }

    @Test func iamRequestIsSignedForBedrockService() throws {
        let sut = BedrockCleanupProvider(
            region: "ap-northeast-1",
            authentication: .iam(AWSCredentials(accessKeyID: "AKIAEXAMPLE", secretAccessKey: "secret")))
        let request = try sut.makeURLRequest(system: "s", user: "u", model: "anthropic.claude-opus-5", date: date)
        let auth = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(auth.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIAEXAMPLE/"))
        #expect(auth.contains("/ap-northeast-1/bedrock/aws4_request"))
        #expect(auth.contains("SignedHeaders=accept;content-type;host;x-amz-date"))
    }

    @Test func bodyUsesBedrockAnthropicVersionWithoutModelOrFallbacks() throws {
        let body = BedrockCleanupProvider.makeInvokeBody(system: "sys", user: "usr", model: "anthropic.claude-opus-5-5")
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        #expect(json["anthropic_version"] as? String == "bedrock-2023-05-31")
        #expect(json["model"] == nil)
        #expect(json["fallbacks"] == nil)
        #expect(json["system"] as? String == "sys")
        #expect((json["output_config"] as? [String: Any])?["effort"] as? String == "low")
    }

    @Test func haikuInferenceProfileOmitsEffort() {
        let body = BedrockCleanupProvider.makeInvokeBody(
            system: "s", user: "u", model: "global.anthropic.claude-haiku-4-5-20251001-v1:0")
        #expect(body.outputConfig == nil)
    }

    @Test func haiku55SendsLowEffort() {
        let body = BedrockCleanupProvider.makeInvokeBody(
            system: "s", user: "u", model: "global.anthropic.claude-haiku-5-5")
        #expect(body.outputConfig?.effort == "low")
    }

    @Test func errorMessageIsReadFromBedrockAndAnthropicBodies() {
        let bedrock = #"{"message":"Retry your request with the ID or ARN of an inference profile."}"#
        #expect(
            HTTPJSON.errorMessage(Data(bedrock.utf8))
                == "Retry your request with the ID or ARN of an inference profile.")
        let anthropic = #"{"type":"error","error":{"type":"invalid_request_error","message":"bad"}}"#
        #expect(HTTPJSON.errorMessage(Data(anthropic.utf8)) == "bad")
        #expect(HTTPJSON.errorMessage(Data("not json".utf8)) == nil)
    }

    @MainActor @Test func builderUsesBedrockCredentialsFromKeychain() {
        let defaults = UserDefaults(suiteName: "BedrockTests-\(UUID())")!
        let settings = SettingsStore(defaults: defaults)
        settings.cleanupProviderID = CleanupProviderKind.bedrock.rawValue
        settings.bedrockAuth = .iam
        let builder = { (values: [String: String]) in
            DictationContextBuilder(
                settings: settings, secrets: MockSecrets(values: values), transcriptionProviders: [])
        }
        // Missing secret key → no provider → cleanup falls back to raw.
        #expect(builder([SecretAccount.awsAccessKeyID: "AK"]).cleanup(for: nil).provider == nil)
        let cleanup = builder([SecretAccount.awsAccessKeyID: "AK", SecretAccount.awsSecretAccessKey: "SK"])
            .cleanup(for: nil)
        #expect(cleanup.provider?.id == "bedrock")
        #expect(cleanup.model == "global.anthropic.claude-haiku-4-5-20251001-v1:0")
    }

    @Test(arguments: ["minimax.minimax-m2.5", "zai.glm-4.7-flash", "zai.glm-4.7", "global.openai.gpt-6-luna"])
    func nonClaudeModelsUseConverse(model: String) throws {
        let sut = BedrockCleanupProvider(region: "ap-northeast-1", authentication: .apiKey("k"))
        let request = try sut.makeURLRequest(system: "sys", user: "usr", model: model)
        #expect(
            request.url?.absoluteString
                == "https://bedrock-runtime.ap-northeast-1.amazonaws.com/model/\(model)/converse")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((json["system"] as? [[String: String]])?.first?["text"] == "sys")
        let message = try #require((json["messages"] as? [[String: Any]])?.first)
        #expect(message["role"] as? String == "user")
        #expect((message["content"] as? [[String: String]])?.first?["text"] == "usr")
        #expect((json["inferenceConfig"] as? [String: Int])?["maxTokens"] == BedrockCleanupProvider.maxTokens)
        #expect(json["anthropic_version"] == nil)
    }

    @Test func claudeModelsUseInvokeModel() {
        #expect(BedrockCleanupProvider.API(model: "anthropic.claude-opus-5") == .invokeModel)
        #expect(BedrockCleanupProvider.API(model: "jp.anthropic.claude-sonnet-4-5-20250929-v1:0") == .invokeModel)
        #expect(BedrockCleanupProvider.API(model: "zai.glm-4.7") == .converse)
    }

    @Test func converseResponseSkipsReasoningBlocks() throws {
        let data = Data(
            #"{"output":{"message":{"role":"assistant","content":[{"reasoningContent":{"reasoningText":{"text":"考え中"}}},{"text":"整形済みの文章です。"}]}},"stopReason":"end_turn","usage":{"inputTokens":10,"outputTokens":5}}"#
                .utf8)
        let completion = try BedrockCleanupProvider.parseConverse(data)
        #expect(completion.text == "整形済みの文章です。")
        #expect(completion.usage == TokenUsage(input: 10, output: 5))
    }

    @Test func converseGuardrailStopIsRefusal() {
        let data = Data(
            #"{"output":{"message":{"role":"assistant","content":[{"text":"blocked"}]}},"stopReason":"guardrail_intervened"}"#
                .utf8)
        #expect(throws: CleanupError.refused) { try BedrockCleanupProvider.parseConverse(data) }
    }

    @Test func minutesLimitsRaiseTheCapAndLeaveEffortToTheModel() throws {
        let body = BedrockCleanupProvider.makeInvokeBody(
            system: "s", user: "u", model: "global.anthropic.claude-haiku-5-5", limits: .minutes)
        #expect(body.maxTokens == 16_000)
        #expect(body.outputConfig == nil)
        let converse = BedrockCleanupProvider.makeConverseBody(system: "s", user: "u", limits: .minutes)
        #expect(converse.inferenceConfig.maxTokens == 16_000)

        let sut = BedrockCleanupProvider(region: "us-east-1", authentication: .apiKey("k"), limits: .minutes)
        let request = try sut.makeURLRequest(system: "s", user: "u", model: "global.anthropic.claude-haiku-5-5")
        #expect(request.timeoutInterval == 600)
    }

    @Test func cleanupLimitsKeepTheShortDefaults() {
        let body = BedrockCleanupProvider.makeInvokeBody(
            system: "s", user: "u", model: "global.anthropic.claude-haiku-5-5")
        #expect(body.maxTokens == 4_000)
        #expect(body.outputConfig?.effort == "low")
        #expect(BedrockCleanupProvider.makeConverseBody(system: "s", user: "u").inferenceConfig.maxTokens == 2_000)
    }

    @MainActor @Test func configuredUsesSavedCredentials() throws {
        let settings = SettingsStore(defaults: try #require(UserDefaults(suiteName: "BedrockTests-\(UUID())")))
        settings.bedrockRegion = "us-west-2"
        settings.bedrockAuth = .apiKey
        #expect(BedrockCleanupProvider.configured(settings: settings, secrets: MockSecrets()) == nil)
        let secrets = MockSecrets(values: [SecretAccount.bedrockAPIKey: "KEY"])
        let provider = try #require(
            BedrockCleanupProvider.configured(settings: settings, secrets: secrets, limits: .minutes))
        #expect(provider.region == "us-west-2")
        #expect(provider.limits == .minutes)
    }

    @Test func converseEmptyOutputIsInvalid() {
        let data = Data(#"{"output":{"message":{"role":"assistant","content":[]}},"stopReason":"end_turn"}"#.utf8)
        #expect(throws: CleanupError.invalidResponse) { try BedrockCleanupProvider.parseConverse(data) }
    }
}

@Suite struct BedrockMinutesWriterTests {
    actor RecordingProvider: TextCleanupProvider {
        nonisolated let id = "recording"
        nonisolated let displayName = "Recording"
        nonisolated let defaultModel = ""
        let result: Result<String, CleanupError>
        private(set) var calls: [(system: String, user: String, model: String)] = []

        init(_ result: Result<String, CleanupError>) { self.result = result }

        func complete(system: String, user: String, model: String) async throws -> CleanupCompletion {
            calls.append((system, user, model))
            return CleanupCompletion(text: try result.get())
        }
    }

    @Test func sendsTheMinutesPromptToTheModel() async throws {
        let provider = RecordingProvider(.success("\n# 日程の確認\n\n## 概要\n決めた。\n"))
        let sut = BedrockMinutesWriter(provider: provider, instructions: "## 要点")
        let minutes = try await sut.writeMinutes(
            transcript: "**話者1** 来週です",
            vocabulary: [CleanupPromptBuilder.Term(preferred: "AppSync", spokenForms: [])],
            model: BedrockMinutesWriter.defaultModel)
        #expect(minutes == "# 日程の確認\n\n## 概要\n決めた。")
        let call = try #require(await provider.calls.first)
        #expect(call.model == "global.anthropic.claude-haiku-5-5")
        #expect(call.system == MeetingMinutesPrompt.system(instructions: "## 要点"))
        #expect(call.user.contains("<vocabulary>"))
        #expect(call.user.contains("<transcript>\n**話者1** 来週です\n</transcript>"))
    }

    @Test func providerErrorsBecomeMinutesFailures() async {
        let sut = BedrockMinutesWriter(provider: RecordingProvider(.failure(.unauthorized)))
        await #expect(throws: MeetingMinutesError.failed("Bedrock: unauthorized")) {
            try await sut.writeMinutes(transcript: "t", vocabulary: [], model: "m")
        }
    }

    @Test func suggestionsAreClaudeModelsOnly() {
        #expect(BedrockMinutesWriter.suggestedModels.contains(BedrockMinutesWriter.defaultModel))
        #expect(BedrockMinutesWriter.suggestedModels.allSatisfy { $0.contains("anthropic.") })
    }
}
