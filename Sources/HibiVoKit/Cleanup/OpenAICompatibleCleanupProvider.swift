import Foundation

/// Any `/chat/completions` endpoint: OpenAI, Groq, OpenRouter, an in-house gateway, etc.
public struct OpenAICompatibleCleanupProvider: TextCleanupProvider {
    public let id = "openai-compatible"
    public let displayName = "OpenAI 互換"
    public let defaultModel = ""

    private let baseURL: URL
    private let apiKey: String
    private let urlSession: URLSession

    public static let defaultBaseURL = "https://api.openai.com/v1"

    public init(baseURL: URL, apiKey: String, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.urlSession = urlSession
    }

    struct Request: Encodable {
        struct Message: Encodable {
            var role: String
            var content: String
        }
        var model: String
        var messages: [Message]
        var temperature: Double = 0
    }

    struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { var content: String? }
            var message: Message
        }
        struct Usage: Decodable {
            var promptTokens: Int
            var completionTokens: Int

            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
            }
        }
        var choices: [Choice]
        var usage: Usage?
    }

    public func complete(system: String, user: String, model: String) async throws -> CleanupCompletion {
        let body = Request(
            model: model,
            messages: [.init(role: "system", content: system), .init(role: "user", content: user)])
        let request = try HTTPJSON.post(
            baseURL.appending(path: "chat/completions"),
            headers: ["Authorization": "Bearer \(apiKey)"], body: body, timeout: 15)
        let (data, response) = try await urlSession.data(for: request)
        try HTTPJSON.checkStatus(response)
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> CleanupCompletion {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let text = response.choices.first?.message.content, !text.isEmpty else {
            throw CleanupError.invalidResponse
        }
        return CleanupCompletion(
            text: text, usage: response.usage.map { TokenUsage(input: $0.promptTokens, output: $0.completionTokens) })
    }
}
