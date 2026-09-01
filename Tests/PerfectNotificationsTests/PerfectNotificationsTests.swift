import Testing
import Foundation
import Crypto
@testable import PerfectNotifications

// MARK: - URLProtocol mock

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastBody = Self.readBody(from: request)
        Self.lastRequest = request
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func readBody(from request: URLRequest) -> Data? {
        if let b = request.httpBody { return b }
        guard let stream = request.httpBodyStream else { return nil }
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

// MARK: - Helpers

private func makeClient(
    handler: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data)
) throws -> APNSClient {
    MockURLProtocol.lastRequest = nil
    MockURLProtocol.requestHandler = handler
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: config)
    let key = P256.Signing.PrivateKey()
    return try APNSClient(keyID: "TESTKEY1234", teamID: "TEAMID1234",
                          pemString: key.pemRepresentation,
                          environment: .sandbox, urlSession: session)
}

private func okResponse(_ body: String = "{}") -> @Sendable (URLRequest) -> (HTTPURLResponse, Data) {
    { req in
        let apnsID = "test-apns-id-\(UUID().uuidString)"
        let http = HTTPURLResponse(
            url: req.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["apns-id": apnsID]
        )!
        return (http, Data(body.utf8))
    }
}

private func errorResponse(statusCode: Int, reason: String) -> @Sendable (URLRequest) -> (HTTPURLResponse, Data) {
    { req in
        let http = HTTPURLResponse(url: req.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        let body = "{\"reason\":\"\(reason)\"}"
        return (http, Data(body.utf8))
    }
}

private func unregisteredResponse(at timestamp: Int) -> @Sendable (URLRequest) -> (HTTPURLResponse, Data) {
    { req in
        let http = HTTPURLResponse(url: req.url!, statusCode: 410, httpVersion: nil, headerFields: nil)!
        let body = "{\"reason\":\"Unregistered\",\"timestamp\":\(timestamp)}"
        return (http, Data(body.utf8))
    }
}

// MARK: - Tests

@Suite(.serialized)
struct PerfectNotificationsTests {

    // MARK: Push type

    @Test func pushTypeRawValues() {
        #expect(APNSPushType.alert.rawValue          == "alert")
        #expect(APNSPushType.background.rawValue     == "background")
        #expect(APNSPushType.liveActivity.rawValue   == "liveactivity")
        #expect(APNSPushType.pushToTalk.rawValue     == "pushtotalk")
        #expect(APNSPushType.fileProvider.rawValue   == "fileprovider")
    }

    @Test func backgroundPushTypeHasPriority5() {
        #expect(APNSPushType.background.defaultPriority == 5)
        #expect(APNSPushType.alert.defaultPriority      == 10)
        #expect(APNSPushType.voip.defaultPriority       == 10)
        #expect(APNSPushType.liveActivity.defaultPriority == 10)
    }

    // MARK: Payload encoding

    @Test func simpleAlertEncodesToExpectedJSON() throws {
        let data = try APNSNotificationItem.encodePayload([
            .alertTitle("Hello"),
            .alertBody("World"),
            .badge(3),
            .sound("default")
        ])
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let aps   = json["aps"] as! [String: Any]
        let alert = aps["alert"] as! [String: Any]
        #expect(alert["title"] as? String == "Hello")
        #expect(alert["body"]  as? String == "World")
        #expect(aps["badge"]   as? Int    == 3)
        #expect(aps["sound"]   as? String == "default")
    }

    @Test func bodyOnlyAlertUsesStringNotDict() throws {
        let data = try APNSNotificationItem.encodePayload([.alertBody("Just a body")])
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let aps  = json["aps"] as! [String: Any]
        #expect(aps["alert"] as? String == "Just a body")
    }

    @Test func contentAvailableAndMutableContentEncodeAsOne() throws {
        let data = try APNSNotificationItem.encodePayload([.contentAvailable, .mutableContent])
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let aps  = json["aps"] as! [String: Any]
        #expect(aps["content-available"] as? Int == 1)
        #expect(aps["mutable-content"]   as? Int == 1)
    }

    @Test func subtitleAndInterruptionLevelEncodeCorrectly() throws {
        let data = try APNSNotificationItem.encodePayload([
            .alertTitle("Title"),
            .alertSubtitle("Subtitle"),
            .interruptionLevel(.timeSensitive),
            .relevanceScore(0.8)
        ])
        let json  = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let aps   = json["aps"] as! [String: Any]
        let alert = aps["alert"] as! [String: Any]
        #expect(alert["subtitle"]              as? String == "Subtitle")
        #expect(aps["interruption-level"]      as? String == "time-sensitive")
        #expect(aps["relevance-score"]         as? Double == 0.8)
    }

    @Test func customPayloadAppearsAtTopLevel() throws {
        let data = try APNSNotificationItem.encodePayload([
            .alertBody("msg"),
            .customPayload("orderId", "ORD-123"),
            .customPayload("amount",  49)
        ])
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["orderId"] as? String == "ORD-123")
        #expect(json["amount"]  as? Int    == 49)
    }

    // MARK: JWT structure

    @Test func jwtHasThreeBase64UrlParts() throws {
        let key = P256.Signing.PrivateKey()
        let creds = APNSCredentials(keyID: "KEYID12345", teamID: "TEAMID1234", key: key)
        let token = try creds.token()
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        #expect(parts.count == 3)
        // Each part should be non-empty and URL-safe base64 (no padding, no +/)
        for part in parts {
            #expect(!part.isEmpty)
            #expect(!part.contains("+"))
            #expect(!part.contains("/"))
            #expect(!part.contains("="))
        }
    }

    @Test func jwtHeaderContainsKidAndAlg() throws {
        let key = P256.Signing.PrivateKey()
        let creds = APNSCredentials(keyID: "KEYID12345", teamID: "TEAMID1234", key: key)
        let token = try creds.token()
        let headerB64 = String(token.split(separator: ".").first!)
        // Pad for standard base64 decoding
        let padded = headerB64 + String(repeating: "=", count: (4 - headerB64.count % 4) % 4)
        let urlDecoded = padded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let data = Data(base64Encoded: urlDecoded)!
        let header = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(header["alg"] as? String == "ES256")
        #expect(header["kid"] as? String == "KEYID12345")
    }

    @Test func jwtPayloadContainsIssAndIat() throws {
        let key = P256.Signing.PrivateKey()
        let creds = APNSCredentials(keyID: "KEYID12345", teamID: "TEAMID1234", key: key)
        let beforeMint = Int(Date().timeIntervalSince1970)
        let token = try creds.token()
        let afterMint = Int(Date().timeIntervalSince1970)

        let payloadB64 = String(token.split(separator: ".")[1])
        let padded = payloadB64 + String(repeating: "=", count: (4 - payloadB64.count % 4) % 4)
        let urlDecoded = padded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let data = Data(base64Encoded: urlDecoded)!
        let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(payload["iss"] as? String == "TEAMID1234")
        let iat = payload["iat"] as! Int
        #expect(iat >= beforeMint)
        #expect(iat <= afterMint)
    }

    @Test func jwtIsCachedOnSecondCall() throws {
        let key = P256.Signing.PrivateKey()
        let creds = APNSCredentials(keyID: "KEYID12345", teamID: "TEAMID1234", key: key)
        let first  = try creds.token()
        let second = try creds.token()
        #expect(first == second)
    }

    // MARK: Request construction

    @Test func sendBuildsCorrectURL() async throws {
        let client = try makeClient(handler: okResponse())
        _ = try await client.send(
            try APNSNotification(items: [.alertBody("test")]),
            to: "abc123token",
            topic: "com.example.App"
        )
        let url = MockURLProtocol.lastRequest?.url?.absoluteString
        #expect(url == "https://api.sandbox.push.apple.com/3/device/abc123token")
    }

    @Test func sendIncludesRequiredHeaders() async throws {
        let client = try makeClient(handler: okResponse())
        _ = try await client.send(
            try APNSNotification(items: [.alertBody("test")]),
            to: "tokenXYZ",
            topic: "com.example.App",
            pushType: .alert
        )
        let req = MockURLProtocol.lastRequest!
        #expect(req.value(forHTTPHeaderField: "apns-topic")     == "com.example.App")
        #expect(req.value(forHTTPHeaderField: "apns-push-type") == "alert")
        #expect(req.value(forHTTPHeaderField: "apns-priority")  == "10")
        #expect(req.value(forHTTPHeaderField: "content-type")   == "application/json")
        let auth = req.value(forHTTPHeaderField: "authorization") ?? ""
        #expect(auth.hasPrefix("bearer "))
        #expect(auth.split(separator: ".").count == 3) // valid JWT structure
    }

    @Test func backgroundPushUsesPriority5() async throws {
        let client = try makeClient(handler: okResponse())
        _ = try await client.send(
            try APNSNotification(items: [.contentAvailable]),
            to: "token",
            topic: "com.example.App",
            pushType: .background
        )
        #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "apns-push-type") == "background")
        #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "apns-priority")  == "5")
    }

    @Test func collapseIDHeaderIncludedWhenSet() async throws {
        let client = try makeClient(handler: okResponse())
        _ = try await client.send(
            try APNSNotification(items: [.alertBody("test")]),
            to: "token", topic: "com.example.App", collapseID: "order-42"
        )
        #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "apns-collapse-id") == "order-42")
    }

    @Test func productionEnvironmentUsesCorrectHost() async throws {
        MockURLProtocol.requestHandler = okResponse()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let key = P256.Signing.PrivateKey()
        let client = try APNSClient(keyID: "KID", teamID: "TID",
                                    pemString: key.pemRepresentation,
                                    environment: .production,
                                    urlSession: URLSession(configuration: config))
        _ = try await client.send(
            try APNSNotification(items: [.alertBody("test")]),
            to: "token", topic: "com.example.App"
        )
        let host = MockURLProtocol.lastRequest?.url?.host
        #expect(host == "api.push.apple.com")
    }

    // MARK: Response parsing

    @Test func successResponseIsSuccess() async throws {
        let client = try makeClient(handler: okResponse())
        let result = try await client.send(
            try APNSNotification(items: [.alertBody("hi")]),
            to: "token", topic: "com.example.App"
        )
        #expect(result.isSuccess)
        #expect(result.statusCode == 200)
        #expect(result.error == nil)
        #expect(result.apnsID != nil)
    }

    @Test func badDeviceTokenResponseParsesReason() async throws {
        let client = try makeClient(handler: errorResponse(statusCode: 400, reason: "BadDeviceToken"))
        let result = try await client.send(
            try APNSNotification(items: [.alertBody("hi")]),
            to: "badtoken", topic: "com.example.App"
        )
        #expect(!result.isSuccess)
        #expect(result.statusCode == 400)
        #expect(result.error?.reason == "BadDeviceToken")
    }

    @Test func unregisteredResponseIncludesTimestamp() async throws {
        let ts = 1_700_000_000
        let client = try makeClient(handler: unregisteredResponse(at: ts))
        let result = try await client.send(
            try APNSNotification(items: [.alertBody("hi")]),
            to: "oldtoken", topic: "com.example.App"
        )
        #expect(result.statusCode == 410)
        #expect(result.error?.reason    == "Unregistered")
        #expect(result.error?.timestamp == ts)
    }

    // MARK: Convenience helpers

    @Test func sendAlertBuildsCorrectPayload() async throws {
        let client = try makeClient(handler: okResponse())
        _ = try await client.sendAlert(to: "token", topic: "com.example.App",
                                       title: "Hey", body: "World", badge: 2)
        let body = MockURLProtocol.lastBody ?? Data()
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let aps   = json["aps"] as! [String: Any]
        let alert = aps["alert"] as! [String: Any]
        #expect(alert["title"] as? String == "Hey")
        #expect(alert["body"]  as? String == "World")
        #expect(aps["badge"]   as? Int    == 2)
        #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "apns-push-type") == "alert")
    }

    @Test func sendBackgroundSetsPushTypeAndContentAvailable() async throws {
        let client = try makeClient(handler: okResponse())
        _ = try await client.sendBackground(to: "token", topic: "com.example.App",
                                            customData: [.customPayload("refresh", true)])
        let body = MockURLProtocol.lastBody ?? Data()
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let aps  = json["aps"] as! [String: Any]
        #expect(aps["content-available"] as? Int == 1)
        #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "apns-push-type") == "background")
        #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "apns-priority")  == "5")
    }

    // MARK: Live sandbox (gated)

    private var liveEnabled: Bool {
        ProcessInfo.processInfo.environment["APNS_TESTS"] == "1"
    }

    @Test func liveSandboxSendAlert() async throws {
        guard liveEnabled,
              let keyID   = ProcessInfo.processInfo.environment["APNS_KEY_ID"],
              let teamID  = ProcessInfo.processInfo.environment["APNS_TEAM_ID"],
              let keyPath = ProcessInfo.processInfo.environment["APNS_KEY_PATH"],
              let token   = ProcessInfo.processInfo.environment["APNS_DEVICE_TOKEN"],
              let topic   = ProcessInfo.processInfo.environment["APNS_TOPIC"] else { return }

        let client = try APNSClient(keyID: keyID, teamID: teamID,
                                    privateKeyPath: keyPath, environment: .sandbox)
        let result = try await client.sendAlert(to: token, topic: topic,
                                                title: "Test", body: "Live sandbox test")
        if !result.isSuccess {
            Issue.record("sandbox push failed: \(result.error?.description ?? "HTTP \(result.statusCode)")")
        }
        #expect(result.apnsID != nil)
    }
}
