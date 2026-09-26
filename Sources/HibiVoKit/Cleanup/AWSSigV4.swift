import CryptoKit
import Foundation

public struct AWSCredentials: Sendable, Equatable {
    public var accessKeyID: String
    public var secretAccessKey: String
    /// Present for temporary credentials (STS / SSO).
    public var sessionToken: String?

    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
    }
}

/// AWS Signature Version 4 for a single request. There is no AWS SDK dependency, so this is the
/// minimal subset HibiVo needs: header-based signing of a request with an in-memory body.
enum AWSSigV4 {
    static func sign(
        _ request: inout URLRequest, credentials: AWSCredentials, region: String, service: String,
        date: Date = Date()
    ) {
        guard let url = request.url, let host = url.host else { return }
        let amzDate = format(date, "yyyyMMdd'T'HHmmss'Z'")
        let dateStamp = format(date, "yyyyMMdd")

        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        if let token = credentials.sessionToken, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Amz-Security-Token")
        }

        // Host is added by URLSession; sign it explicitly with the value it will send.
        var headers = ["host": url.port.map { "\(host):\($0)" } ?? host]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            headers[name.lowercased()] = value.trimmingCharacters(in: .whitespaces)
        }
        let names = headers.keys.sorted()
        let signedHeaders = names.joined(separator: ";")
        let canonicalHeaders = names.map { "\($0):\(headers[$0] ?? "")\n" }.joined()

        let canonicalRequest = [
            request.httpMethod ?? "GET",
            canonicalURI(url.path),
            canonicalQuery(url),
            canonicalHeaders,
            signedHeaders,
            hex(SHA256.hash(data: request.httpBody ?? Data())),
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256", amzDate, scope, hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
        ].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8))
        for part in [dateStamp, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))

        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), "
                + "SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization")
    }

    /// Non-S3 services expect each path segment URI-encoded twice.
    private static func canonicalURI(_ path: String) -> String {
        guard !path.isEmpty else { return "/" }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { encode(encode(String($0))) }
            .joined(separator: "/")
    }

    private static func canonicalQuery(_ url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.map { (encode($0.name), encode($0.value ?? "")) }
            .sorted { $0 < $1 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
