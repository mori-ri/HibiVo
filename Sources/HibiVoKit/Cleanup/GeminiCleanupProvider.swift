import Foundation

/// Gemini via the Interactions API (POST /v1beta/interactions). Shares its API key with
/// Gemini transcription.
public struct GeminiCleanupProvider: TextCleanupProvider {
    public let id = CleanupProviderKind.gemini.rawValue
    public let displayName = CleanupProviderKind.gemini.displayName
    public let defaultModel = CleanupProviderKind.gemini.defaultModel

    private let apiKey: String
    private let urlSession: URLSession
    static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!

    public static let suggestedModels = ["gemini-3.5-flash-lite", "gemini-3.8-flash"]

    public init(apiKey: String, urlSession: URLSession = .shared) {
        self.apiKey = apiKey
        self.urlSession = urlSession
    }

    struct Request: Encodable {
        struct GenerationConfig: Encodable {
            var thinkingLevel: String?

            enum CodingKeys: String, CodingKey {
                case thinkingLevel = "thinking_level"
            }
        }

        var model: String
        var input: String
        var systemInstruction: String
        /// Dictated text must not be kept server-side for later retrieval.
        var store = false
        var generationConfig: GenerationConfig?

        enum CodingKeys: String, CodingKey {
            case model, input, store
            case systemInstruction = "system_instruction"
            case generationConfig = "generation_config"
        }
    }

    struct Response: Decodable {
        struct Step: Decodable {
            struct Content: Decodable {
                var type: String
                var text: String?
            }
            var type: String
            var content: [Content]?
        }
        struct Usage: Decodable {
            var totalInputTokens: Int?
            var totalOutputTokens: Int?
            var totalThoughtTokens: Int?

            enum CodingKeys: String, CodingKey {
                case totalInputTokens = "total_input_tokens"
                case totalOutputTokens = "total_output_tokens"
                case totalThoughtTokens = "total_thought_tokens"
            }

            /// Thinking tokens are billed at the output rate.
            var tokens: TokenUsage {
                TokenUsage(
                    input: totalInputTokens ?? 0, output: (totalOutputTokens ?? 0) + (totalThoughtTokens ?? 0))
            }
        }
        var steps: [Step]?
        var usage: Usage?
    }

    static func makeRequest(system: String, user: String, model: String) -> Request {
        // Cleanup is a light rewrite, so keep thinking low. Gemini 3.8 Flash rejects `minimal`,
        // and pre-3 models don't take `thinking_level` at all.
        let thinking = model.hasPrefix("gemini-3") ? Request.GenerationConfig(thinkingLevel: "low") : nil
        return Request(model: model, input: user, systemInstruction: system, generationConfig: thinking)
    }

    public func complete(system: String, user: String, model: String) async throws -> CleanupCompletion {
        let request = try HTTPJSON.post(
            Self.endpoint, headers: ["x-goog-api-key": apiKey],
            body: Self.makeRequest(system: system, user: user, model: model), timeout: 60)
        let (data, response) = try await urlSession.data(for: request)
        // A bad key comes back as 400 API_KEY_INVALID rather than 401.
        if let http = response as? HTTPURLResponse, http.statusCode == 400,
            String(decoding: data, as: UTF8.self).contains("API_KEY_INVALID")
        {
            throw CleanupError.unauthorized
        }
        try HTTPJSON.checkStatus(response, data: data)
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> CleanupCompletion {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let text = (response.steps ?? [])
            .filter { $0.type == "model_output" }
            .flatMap { $0.content ?? [] }
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
        guard !text.isEmpty else { throw CleanupError.invalidResponse }
        return CleanupCompletion(text: text, usage: response.usage?.tokens)
    }
}
