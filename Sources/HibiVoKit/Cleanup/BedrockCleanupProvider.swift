import Foundation

/// Claude on Amazon Bedrock via the `bedrock-runtime` InvokeModel API:
/// `POST https://bedrock-runtime.{region}.amazonaws.com/model/{modelId}/invoke`
///
/// The body is Anthropic's Messages format with `anthropic_version` instead of `model`.
/// The model can be a model ID, an inference profile ID (`global.` / `jp.` / `us.` …) or an ARN.
public struct BedrockCleanupProvider: TextCleanupProvider {
    public enum Authentication: Sendable, Equatable {
        /// Bedrock API key, sent as a bearer token.
        case apiKey(String)
        /// IAM access key, signed with SigV4 for the `bedrock` service.
        case iam(AWSCredentials)
    }

    public let id = "bedrock"
    public let displayName = "Amazon Bedrock"
    public let defaultModel = CleanupProviderKind.bedrock.defaultModel
    public static let defaultRegion = "ap-northeast-1"

    private let region: String
    private let authentication: Authentication
    private let urlSession: URLSession

    public init(region: String, authentication: Authentication, urlSession: URLSession = .shared) {
        self.region = region
        self.authentication = authentication
        self.urlSession = urlSession
    }

    struct Body: Encodable {
        var anthropicVersion = "bedrock-2023-05-31"
        var maxTokens: Int
        var system: String
        var messages: [AnthropicCleanupProvider.Request.Message]
        var outputConfig: AnthropicCleanupProvider.Request.OutputConfig?

        enum CodingKeys: String, CodingKey {
            case anthropicVersion = "anthropic_version", maxTokens = "max_tokens", system, messages
            case outputConfig = "output_config"
        }
    }

    static func makeBody(system: String, user: String, model: String) -> Body {
        // Same shaping as the first-party API, minus `model` (it is in the URL) and `fallbacks`
        // (not supported on Bedrock).
        let request = AnthropicCleanupProvider.makeRequest(system: system, user: user, model: model, allowFallbacks: false)
        return Body(
            maxTokens: request.maxTokens, system: request.system, messages: request.messages,
            outputConfig: request.outputConfig)
    }

    func endpoint(model: String) -> URL? {
        // Model IDs can contain ":" and ARNs contain "/", so encode the whole ID as one path segment.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encoded = model.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://bedrock-runtime.\(region).amazonaws.com/model/\(encoded)/invoke")
    }

    func makeURLRequest(system: String, user: String, model: String, date: Date = Date()) throws -> URLRequest {
        guard let url = endpoint(model: model) else { throw CleanupError.invalidResponse }
        var headers = ["Accept": "application/json"]
        if case .apiKey(let key) = authentication { headers["Authorization"] = "Bearer \(key)" }
        var request = try HTTPJSON.post(
            url, headers: headers, body: Self.makeBody(system: system, user: user, model: model), timeout: 15)
        if case .iam(let credentials) = authentication {
            AWSSigV4.sign(&request, credentials: credentials, region: region, service: "bedrock", date: date)
        }
        return request
    }

    public func complete(system: String, user: String, model: String) async throws -> String {
        let request = try makeURLRequest(system: system, user: user, model: model)
        let (data, response) = try await urlSession.data(for: request)
        try HTTPJSON.checkStatus(response)
        return try AnthropicCleanupProvider.parse(data)
    }
}
