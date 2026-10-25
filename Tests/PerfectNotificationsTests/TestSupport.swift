import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Crypto
@testable import PerfectNotifications

// MARK: - URLProtocol stub
//
// Every request made through a session from `MockURLProtocol.session()` is answered here;
// nothing reaches the network. The suites using it are `.serialized`.

enum MockReply: Sendable {
    case respond(status: Int, headers: [String: String], body: Data)
    case fail(URLError.Code)
    /// Never answers (for timeout and cancellation tests).
    case hang
}

struct RecordedRequest: Sendable {
    let url: URL?
    let method: String?
    let headers: [String: String]
    let body: Data
    func header(_ name: String) -> String? {
        headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }
}

final class MockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: (@Sendable (Int) -> MockReply)?
    nonisolated(unsafe) private static var _requests: [RecordedRequest] = []

    static func reset(_ handler: @escaping @Sendable (_ callIndex: Int) -> MockReply) {
        lock.withLock { _handler = handler; _requests = [] }
    }
    static var requests: [RecordedRequest] { lock.withLock { _requests } }
    static var lastRequest: RecordedRequest? { requests.last }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = RecordedRequest(url: request.url, method: request.httpMethod,
                                       headers: request.allHTTPHeaderFields ?? [:],
                                       body: Self.readBody(from: request))
        let (index, handler) = Self.lock.withLock { () -> (Int, (@Sendable (Int) -> MockReply)?) in
            Self._requests.append(recorded)
            return (Self._requests.count - 1, Self._handler)
        }
        switch handler?(index) ?? .fail(.badServerResponse) {
        case .respond(let status, let headers, let body):
            let http = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/2", headerFields: headers)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hang:
            break
        }
    }

    override func stopLoading() {}

    static func readBody(from request: URLRequest) -> Data {
        if let b = request.httpBody { return b }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

// MARK: - Replies

func ok(apnsID: String = "8F1D2A6C-5B9E-4C3A-9F00-000000000001",
        uniqueID: String? = nil) -> MockReply {
    var headers = ["apns-id": apnsID]
    if let uniqueID { headers["apns-unique-id"] = uniqueID }
    return .respond(status: 200, headers: headers, body: Data())
}

func rejected(_ status: Int, _ reason: String, timestamp: Int64? = nil) -> MockReply {
    let body = timestamp.map { "{\"reason\":\"\(reason)\",\"timestamp\":\($0)}" } ?? "{\"reason\":\"\(reason)\"}"
    return .respond(status: status, headers: ["apns-id": "8F1D2A6C-5B9E-4C3A-9F00-000000000002"],
                    body: Data(body.utf8))
}

// MARK: - Fixtures

/// A syntactically valid 32-byte device token.
let token64 = String(repeating: "ab", count: 32)
let keyID = "ABCDE12345"
let teamID = "TEAM123456"

/// A settable clock for token-age tests.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(minutes: Double) { lock.withLock { current += minutes * 60 } }
}

func makeClient(key: P256.Signing.PrivateKey = P256.Signing.PrivateKey(),
                clock: TestClock? = nil,
                environment: APNSClient.Environment = .sandbox,
                timeout: TimeInterval = APNSClient.defaultTimeout,
                _ handler: @escaping @Sendable (Int) -> MockReply) throws -> APNSClient {
    MockURLProtocol.reset(handler)
    let now: @Sendable () -> Date
    if let clock { now = { clock.now } } else { now = { Date() } }
    let creds = try APNSCredentials(keyID: keyID, teamID: teamID, key: key, now: now)
    return try APNSClient(credentials: creds, environment: environment,
                          urlSession: MockURLProtocol.session(), timeout: timeout)
}

// MARK: - JWT helpers

func base64URLDecode(_ s: Substring) -> Data? {
    var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
    return Data(base64Encoded: b64)
}

struct DecodedJWT {
    let header: [String: Any]
    let claims: [String: Any]
    let headerJSON: String
    let claimsJSON: String
    let signatureValid: Bool
}

func decodeJWT(_ jwt: String, publicKey: P256.Signing.PublicKey) throws -> DecodedJWT {
    let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, let h = base64URLDecode(parts[0]), let c = base64URLDecode(parts[1]),
          let s = base64URLDecode(parts[2]) else { throw URLError(.cannotDecodeContentData) }
    let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
    let signature = try P256.Signing.ECDSASignature(rawRepresentation: s)
    return DecodedJWT(
        header: try JSONSerialization.jsonObject(with: h) as? [String: Any] ?? [:],
        claims: try JSONSerialization.jsonObject(with: c) as? [String: Any] ?? [:],
        headerJSON: String(decoding: h, as: UTF8.self),
        claimsJSON: String(decoding: c, as: UTF8.self),
        signatureValid: publicKey.isValidSignature(signature, for: signingInput))
}

func bearer(_ request: RecordedRequest?) -> String? {
    guard let auth = request?.header("authorization"), auth.hasPrefix("bearer ") else { return nil }
    return String(auth.dropFirst("bearer ".count))
}

func json(_ data: Data) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}
