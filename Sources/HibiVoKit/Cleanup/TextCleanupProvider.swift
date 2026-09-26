import Foundation

public enum CleanupError: Error, Equatable, Sendable {
    case missingAPIKey
    case missingModel
    case unauthorized
    case http(Int)
    case refused
    case invalidResponse
    case rejectedByGuard
    case timedOut
}

/// An LLM that rewrites text. It only knows how to send one system + user message and return text.
public protocol TextCleanupProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var defaultModel: String { get }

    func complete(system: String, user: String, model: String, apiKey: String) async throws -> String
}

enum HTTPJSON {
    static func post(_ url: URL, headers: [String: String], body: some Encodable, timeout: TimeInterval) throws
        -> URLRequest
    {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    static func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw CleanupError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw CleanupError.unauthorized
        default: throw CleanupError.http(http.statusCode)
        }
    }
}
