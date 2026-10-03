import Foundation

/// LLM cleanup through Amazon Bedrock's `bedrock-runtime` endpoint.
///
/// - Claude models (IDs containing `anthropic.`) use InvokeModel with Anthropic's Messages body,
///   which is where the newest Claude models and their parameters (effort) are available.
/// - Every other model (MiniMax, GLM, GPT, Nova, …) uses the model-agnostic Converse API.
///
/// The model can be a model ID, an inference profile ID (`global.` / `jp.` / `us.` …) or an ARN.
public struct BedrockCleanupProvider: TextCleanupProvider {
    public enum Authentication: Sendable, Equatable {
        /// Bedrock API key, sent as a bearer token.
        case apiKey(String)
        /// IAM access key, signed with SigV4 for the `bedrock` service.
        case iam(AWSCredentials)
    }

    enum API: Equatable {
        case invokeModel
        case converse

        init(model: String) {
            self = model.contains("anthropic.") ? .invokeModel : .converse
        }

        var action: String {
            switch self {
            case .invokeModel: "invoke"
            case .converse: "converse"
            }
        }
    }

    public let id = "bedrock"
    public let displayName = "Amazon Bedrock"
    public let defaultModel = CleanupProviderKind.bedrock.defaultModel
    public static let defaultRegion = "ap-northeast-1"

    /// Model IDs offered as suggestions in Settings. Any other ID can be typed in.
    public static let suggestedModels = [
        "global.anthropic.claude-haiku-4-5-20251001-v1:0",
        "anthropic.claude-opus-5-5",
        "zai.glm-4.7-flash",
        "zai.glm-4.7",
        "minimax.minimax-m2.5",
        "global.openai.gpt-6-luna",
    ]

    /// Cleanup output is short; this also stays under GLM 4.7's 4K output limit.
    static let maxTokens = 2_000

    let region: String
    private let authentication: Authentication
    private let urlSession: URLSession

    public init(region: String, authentication: Authentication, urlSession: URLSession = .shared) {
        self.region = region
        self.authentication = authentication
        self.urlSession = urlSession
    }

    // MARK: - InvokeModel (Claude)

    struct InvokeBody: Encodable {
        var anthropicVersion = "bedrock-2023-05-31"
        var maxTokens: Int
        var system: String
        var messages: [AnthropicCleanupProvider.Request.Message]
        var outputConfig: AnthropicCleanupProvider.Request.OutputConfig?

        enum CodingKeys: String, CodingKey {
            case anthropicVersion = "anthropic_version"
            case maxTokens = "max_tokens"
            case system, messages
            case outputConfig = "output_config"
        }
    }

    static func makeInvokeBody(system: String, user: String, model: String) -> InvokeBody {
        // Same shaping as the first-party API, minus `model` (it is in the URL) and `fallbacks`
        // (not supported on Bedrock).
        let request = AnthropicCleanupProvider.makeRequest(
            system: system, user: user, model: model, allowFallbacks: false)
        return InvokeBody(
            maxTokens: request.maxTokens, system: request.system, messages: request.messages,
            outputConfig: request.outputConfig)
    }

    // MARK: - Converse (everything else)

    struct ConverseBody: Encodable {
        struct Text: Encodable { var text: String }
        struct Message: Encodable {
            var role = "user"
            var content: [Text]
        }
        struct InferenceConfig: Encodable { var maxTokens: Int }

        var system: [Text]
        var messages: [Message]
        // No temperature: some reasoning models on Bedrock reject non-default sampling settings.
        var inferenceConfig: InferenceConfig
    }

    struct ConverseResponse: Decodable {
        struct Output: Decodable {
            struct Message: Decodable {
                /// Text blocks carry `text`; reasoning models also return `reasoningContent`
                /// blocks, which are ignored so their thinking never reaches the paste.
                struct Block: Decodable { var text: String? }
                var content: [Block]
            }
            var message: Message?
        }
        struct Usage: Decodable {
            var inputTokens: Int
            var outputTokens: Int
        }
        var output: Output
        var stopReason: String?
        var usage: Usage?
    }

    static func makeConverseBody(system: String, user: String) -> ConverseBody {
        ConverseBody(
            system: [.init(text: system)],
            messages: [.init(content: [.init(text: user)])],
            inferenceConfig: .init(maxTokens: maxTokens))
    }

    static func parseConverse(_ data: Data) throws -> CleanupCompletion {
        let response = try JSONDecoder().decode(ConverseResponse.self, from: data)
        if response.stopReason == "guardrail_intervened" || response.stopReason == "content_filtered" {
            throw CleanupError.refused
        }
        let text = (response.output.message?.content ?? []).compactMap(\.text).joined()
        guard !text.isEmpty else { throw CleanupError.invalidResponse }
        return CleanupCompletion(
            text: text, usage: response.usage.map { TokenUsage(input: $0.inputTokens, output: $0.outputTokens) })
    }

    // MARK: - Request

    func endpoint(model: String) -> URL? {
        // Model IDs can contain ":" and ARNs contain "/", so encode the whole ID as one path segment.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encoded = model.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(
            string: "https://bedrock-runtime.\(region).amazonaws.com/model/\(encoded)/\(API(model: model).action)")
    }

    func makeURLRequest(system: String, user: String, model: String, date: Date = Date()) throws -> URLRequest {
        guard let url = endpoint(model: model) else { throw CleanupError.invalidResponse }
        var headers = ["Accept": "application/json"]
        if case .apiKey(let key) = authentication { headers["Authorization"] = "Bearer \(key)" }
        var request =
            switch API(model: model) {
            case .invokeModel:
                try HTTPJSON.post(
                    url, headers: headers, body: Self.makeInvokeBody(system: system, user: user, model: model),
                    timeout: 15)
            case .converse:
                try HTTPJSON.post(
                    url, headers: headers, body: Self.makeConverseBody(system: system, user: user), timeout: 15)
            }
        if case .iam(let credentials) = authentication {
            AWSSigV4.sign(&request, credentials: credentials, region: region, service: "bedrock", date: date)
        }
        return request
    }

    public func complete(system: String, user: String, model: String) async throws -> CleanupCompletion {
        let request = try makeURLRequest(system: system, user: user, model: model)
        let (data, response) = try await urlSession.data(for: request)
        try HTTPJSON.checkStatus(response)
        switch API(model: model) {
        case .invokeModel: return try AnthropicCleanupProvider.parse(data)
        case .converse: return try Self.parseConverse(data)
        }
    }
}
