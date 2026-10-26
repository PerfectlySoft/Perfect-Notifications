import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Crypto
@testable import PerfectNotifications

/// Request shape, response parsing, retries, timeouts and redaction, through a
/// URLProtocol stub. Serialized: the stub's state is shared.
@Suite(.serialized)
struct ClientTests {

    // MARK: Request shape

    @Test func requestShape() async throws {
        let key = P256.Signing.PrivateKey()
        let client = try makeClient(key: key) { _ in ok() }
        let notification = try APNSNotification(items: [.alertBody("test")])
        _ = try await client.send(notification, to: token64, topic: "com.example.App",
                                  expiration: .absolute(1_900_000_000), collapseID: "order-42")
        let req = try #require(MockURLProtocol.lastRequest)
        #expect(req.url?.absoluteString == "https://api.sandbox.push.apple.com/3/device/\(token64)")
        #expect(req.method == "POST")
        #expect(req.body == notification.payload)
        #expect(req.header("content-type")     == "application/json")
        #expect(req.header("apns-topic")       == "com.example.App")
        #expect(req.header("apns-push-type")   == "alert")
        #expect(req.header("apns-priority")    == "10")
        #expect(req.header("apns-expiration")  == "1900000000")
        #expect(req.header("apns-collapse-id") == "order-42")
        let jwt = try decodeJWT(try #require(bearer(req)), publicKey: key.publicKey)
        #expect(jwt.signatureValid)
        #expect(jwt.header["kid"] as? String == keyID)
        #expect(jwt.claims["iss"] as? String == teamID)
    }

    @Test func optionalHeadersAreOmittedByDefault() async throws {
        let client = try makeClient { _ in ok() }
        _ = try await client.send(APNSNotification(items: [.alertBody("x")]), to: token64, topic: "com.example.App")
        let req = try #require(MockURLProtocol.lastRequest)
        #expect(req.header("apns-expiration") == nil)
        #expect(req.header("apns-collapse-id") == nil)
    }

    @Test func productionAndCustomHosts() async throws {
        var client = try makeClient(environment: .production) { _ in ok() }
        _ = try await client.send(APNSNotification(items: [.alertBody("x")]), to: token64, topic: "com.example.App")
        #expect(MockURLProtocol.lastRequest?.url?.absoluteString == "https://api.push.apple.com/3/device/\(token64)")

        client = try makeClient(environment: .custom(host: "localhost", port: 8443)) { _ in ok() }
        _ = try await client.send(APNSNotification(items: [.alertBody("x")]), to: token64, topic: "com.example.App")
        #expect(MockURLProtocol.lastRequest?.url?.absoluteString == "https://localhost:8443/3/device/\(token64)")

        for bad: APNSClient.Environment in [.custom(host: "evil.test/x?", port: 443), .custom(host: "a@b", port: 443),
                                            .custom(host: "localhost", port: 0), .custom(host: "", port: 443)] {
            #expect(throws: APNSClientError.invalidHost) { try makeClient(environment: bad) { _ in ok() } }
        }
    }

    @Test func backgroundPushUsesPriority5AndRefusesOthers() async throws {
        let client = try makeClient { _ in ok() }
        _ = try await client.sendBackground(to: token64, topic: "com.example.App",
                                            customData: [.customPayload("refresh", true)])
        let req = try #require(MockURLProtocol.lastRequest)
        #expect(req.header("apns-push-type") == "background")
        #expect(req.header("apns-priority")  == "5")
        let body = try json(req.body)
        #expect((body["aps"] as? [String: Any])?["content-available"] as? Int == 1)
        #expect(body["refresh"] as? Bool == true)

        for priority in [APNSPriority.immediate, .low] {
            await #expect(throws: APNSClientError.invalidPriority(priority, pushType: .background)) {
                try await client.send(APNSNotification(items: [.contentAvailable]), to: token64,
                                      topic: "com.example.App", pushType: .background, priority: priority)
            }
        }
        _ = try await client.send(APNSNotification(items: [.alertBody("x")]), to: token64,
                                  topic: "com.example.App", priority: .low)
        #expect(MockURLProtocol.lastRequest?.header("apns-priority") == "1")
    }

    // MARK: Input validation never reaches the transport

    @Test func invalidInputThrowsBeforeAnyRequest() async throws {
        let client = try makeClient { _ in ok() }
        let n = try APNSNotification(items: [.alertBody("x")])
        await #expect(throws: APNSClientError.invalidDeviceToken) {
            try await client.send(n, to: "../../../3/device/" + token64 + "?", topic: "com.example.App")
        }
        await #expect(throws: APNSClientError.invalidTopic) {
            try await client.send(n, to: token64, topic: "com.example.App\r\nx-injected: 1")
        }
        await #expect(throws: APNSClientError.invalidCollapseID) {
            try await client.send(n, to: token64, topic: "com.example.App", collapseID: "a\r\nb: c")
        }
        await #expect(throws: APNSClientError.invalidExpiration) {
            try await client.send(n, to: token64, topic: "com.example.App", expiration: .relative(.max))
        }
        #expect(MockURLProtocol.requests.isEmpty)
    }

    @Test func payloadSizeLimits() async throws {
        let client = try makeClient { _ in ok() }
        func payload(_ size: Int) -> APNSNotification {
            let filler = String(repeating: "x", count: size - #"{"aps":{"alert":""}}"#.utf8.count)
            return try! APNSNotification(raw: Data(#"{"aps":{"alert":"\#(filler)"}}"#.utf8))
        }
        #expect(payload(4096).payload.count == 4096)
        _ = try await client.send(payload(4096), to: token64, topic: "com.example.App")
        await #expect(throws: APNSClientError.payloadTooLarge(size: 4097, limit: 4096)) {
            try await client.send(payload(4097), to: token64, topic: "com.example.App")
        }
        _ = try await client.send(payload(5120), to: token64, topic: "com.example.App.voip", pushType: .voip)
        #expect(throws: APNSClientError.payloadTooLarge(size: 5121, limit: 5120)) {
            try APNSNotification(raw: Data(repeating: UInt8(ascii: " "), count: 5121))
        }
        #expect(MockURLProtocol.requests.count == 2)
    }

    // MARK: Response parsing

    @Test func successResponse() async throws {
        let client = try makeClient { _ in ok(apnsID: "ID-1", uniqueID: "UNIQUE-1") }
        let result = try await client.sendAlert(to: token64, topic: "com.example.App", title: "Hey", body: "World", badge: 2)
        #expect(result == APNSResponse(statusCode: 200, apnsID: "ID-1", apnsUniqueID: "UNIQUE-1", error: nil))
        #expect(result.isSuccess)
        let aps = try #require(try json(MockURLProtocol.lastRequest!.body)["aps"] as? [String: Any])
        #expect((aps["alert"] as? [String: Any])?["title"] as? String == "Hey")
        #expect(aps["badge"] as? Int == 2)
    }

    @Test func rejectionParsesReason() async throws {
        let client = try makeClient { _ in rejected(400, "BadDeviceToken") }
        let result = try await client.send(APNSNotification(items: [.alertBody("x")]), to: token64, topic: "com.example.App")
        #expect(!result.isSuccess)
        #expect(result.statusCode == 400)
        #expect(result.error?.reason == "BadDeviceToken")
        #expect(result.error?.knownReason == .badDeviceToken)
        #expect(result.apnsID != nil)
    }

    @Test func unregisteredTimestampIsMilliseconds() async throws {
        let ms: Int64 = 1_700_000_000_123
        let client = try makeClient { _ in rejected(410, "Unregistered", timestamp: ms) }
        let result = try await client.send(APNSNotification(items: [.alertBody("x")]), to: token64, topic: "com.example.App")
        #expect(result.statusCode == 410)
        #expect(result.error?.knownReason == .unregistered)
        #expect(result.error?.timestamp == ms)
        #expect(result.error?.invalidatedAt == Date(timeIntervalSince1970: 1_700_000_000.123))
    }

    @Test func unknownReasonAndNonJSONBodies() async throws {
        var client = try makeClient { _ in rejected(400, "SomethingNew") }
        var result = try await client.send(APNSNotification(items: [.alertBody("x")]), to: token64, topic: "com.example.App")
        #expect(result.error?.reason == "SomethingNew")
        #expect(result.error?.knownReason == nil)

        client = try makeClient { _ in .respond(status: 502, headers: [:], body: Data("<html>bad gateway</html>".utf8)) }
        result = try await client.send(APNSNotification(items: [.alertBody("x")]), to: token64, topic: "com.example.App")
        #expect(result.statusCode == 502)
        #expect(result.error == nil)
    }

    @Test func oversizedResponseBodyIsRefused() async throws {
        let big = Data(repeating: UInt8(ascii: "x"), count: 64 * 1024)
        let client = try makeClient { _ in .respond(status: 400, headers: [:], body: big) }
        await #expect(throws: APNSClientError.responseTooLarge(limit: 16 * 1024)) {
            try await client.send(APNSNotification(items: [.alertBody("x")]), to: token64, topic: "com.example.App")
        }
    }

    @Test func networkFailureIsAClientError() async throws {
        let client = try makeClient { _ in .fail(.cannotConnectToHost) }
        do {
            _ = try await client.send(APNSNotification(items: [.alertBody("x")]), to: token64, topic: "com.example.App")
            Issue.record("expected a network error")
        } catch let APNSClientError.network(message) {
            #expect(message.contains("\(URLError.Code.cannotConnectToHost.rawValue)"))
            #expect(!message.contains("bearer"))
        }
    }

    // MARK: Timeouts and cancellation

    @Test func hangingRequestTimesOut() async throws {
        let client = try makeClient(timeout: 0.5) { _ in .hang }
        let start = Date()
        await #expect(throws: APNSClientError.timedOut) {
            try await client.send(APNSNotification(items: [.alertBody("x")]), to: token64, topic: "com.example.App")
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed >= 0.4 && elapsed < 10)
    }

    @Test func cancellationIsPrompt() async throws {
        let client = try makeClient(timeout: 60) { _ in .hang }
        let task = Task {
            try await client.send(APNSNotification(items: [.alertBody("x")]), to: token64, topic: "com.example.App")
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let start = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func subSecondDeadlineWithAPromptServerSucceeds() async throws {
        // corelibs truncates URLRequest.timeoutInterval to whole seconds, so a 0.5 s value
        // used to fail at once on Linux. The client's own deadline handles fractions.
        let client = try makeClient(timeout: 0.5) { _ in ok() }
        let result = try await client.send(APNSNotification(items: [.alertBody("x")]), to: token64, topic: "com.example.App")
        #expect(result.isSuccess)
        let start = Date()
        let hung = try makeClient(timeout: 0.5) { _ in .hang }
        await #expect(throws: APNSClientError.timedOut) {
            try await hung.send(APNSNotification(items: [.alertBody("x")]), to: token64, topic: "com.example.App")
        }
        #expect(Date().timeIntervalSince(start) >= 0.4)
    }

    @Test func urlSessionIdleTimeoutIsPastTheDeadline() async throws {
        let client = try makeClient(timeout: 0.5) { _ in ok() }
        _ = try await client.send(APNSNotification(items: [.alertBody("x")]), to: token64, topic: "com.example.App")
        // Recorded by the stub from the request as sent; the deadline itself is 0.5 s.
        #expect(MockURLProtocol.lastTimeout == 6)
    }

    // MARK: Redirects

    @Test func redirectStatusIsAnErrorNotASuccess() async throws {
        for status in [301, 302, 307, 308] {
            let client = try makeClient { _ in
                .respond(status: status, headers: ["location": "https://evil.test/3/device/\(token64)"], body: Data())
            }
            await #expect(throws: APNSClientError.unexpectedRedirect(statusCode: status)) {
                try await client.send(APNSNotification(items: [.alertBody("x")]), to: token64, topic: "com.example.App")
            }
            #expect(MockURLProtocol.requests.count == 1)
            #expect(MockURLProtocol.requests.allSatisfy { $0.url?.host == "api.sandbox.push.apple.com" })
        }
    }

    @Test func responseFromAnotherOriginIsRefused() async throws {
        let client = try makeClient { _ in .respondFrom(url: "https://evil.test/3/device/x", status: 200) }
        await #expect(throws: APNSClientError.unexpectedRedirect(statusCode: 200)) {
            try await client.send(APNSNotification(items: [.alertBody("x")]), to: token64, topic: "com.example.App")
        }
    }

    // MARK: Provider-token rejections

    @Test func expiredProviderTokenIsRetriedOnceWithAFreshToken() async throws {
        let clock = TestClock()
        let client = try makeClient(clock: clock) { i in i == 1 ? rejected(403, "ExpiredProviderToken") : ok() }
        _ = try await client.send(APNSNotification(items: [.alertBody("x")]), to: token64, topic: "com.example.App")
        clock.advance(minutes: 25)
        let result = try await client.send(APNSNotification(items: [.alertBody("x")]), to: token64, topic: "com.example.App")
        #expect(result.isSuccess)
        let tokens = MockURLProtocol.requests.map(bearer)
        #expect(tokens.count == 3)
        #expect(tokens[0] == tokens[1])
        #expect(tokens[2] != tokens[1])
    }

    @Test func expiredProviderTokenIsNotRetriedWithinTwentyMinutes() async throws {
        let clock = TestClock()
        let client = try makeClient(clock: clock) { _ in rejected(403, "ExpiredProviderToken") }
        clock.advance(minutes: 0)
        let result = try await client.send(APNSNotification(items: [.alertBody("x")]), to: token64, topic: "com.example.App")
        #expect(result.error?.knownReason == .expiredProviderToken)
        #expect(MockURLProtocol.requests.count == 1)
        // Still within 20 minutes: same token, no new mint.
        clock.advance(minutes: 10)
        _ = try await client.send(APNSNotification(items: [.alertBody("x")]), to: token64, topic: "com.example.App")
        #expect(MockURLProtocol.requests.count == 2)
        #expect(bearer(MockURLProtocol.requests[0]) == bearer(MockURLProtocol.requests[1]))
        // Past 20 minutes the rejected token is replaced on the next send. That fresh
        // token is rejected too, and it can't be replaced yet, so there is no retry.
        clock.advance(minutes: 11)
        let third = try await client.send(APNSNotification(items: [.alertBody("x")]), to: token64, topic: "com.example.App")
        #expect(third.error?.knownReason == .expiredProviderToken)
        let tokens = MockURLProtocol.requests.map(bearer)
        try #require(tokens.count == 3)
        #expect(tokens[2] != tokens[1])
    }

    @Test func invalidProviderTokenInvalidatesWithoutRetry() async throws {
        let clock = TestClock()
        let client = try makeClient(clock: clock) { i in i == 0 ? rejected(403, "InvalidProviderToken") : ok() }
        clock.advance(minutes: 0)
        let first = try await client.send(APNSNotification(items: [.alertBody("x")]), to: token64, topic: "com.example.App")
        #expect(first.error?.knownReason == .invalidProviderToken)
        #expect(MockURLProtocol.requests.count == 1)
        clock.advance(minutes: 21)    // below the 50-minute refresh, but the token was rejected
        _ = try await client.send(APNSNotification(items: [.alertBody("x")]), to: token64, topic: "com.example.App")
        let tokens = MockURLProtocol.requests.map(bearer)
        #expect(tokens[1] != tokens[0])
    }

    @Test func tooManyProviderTokenUpdatesKeepsTheToken() async throws {
        let clock = TestClock()
        let client = try makeClient(clock: clock) { i in i == 0 ? rejected(429, "TooManyProviderTokenUpdates") : ok() }
        let first = try await client.send(APNSNotification(items: [.alertBody("x")]), to: token64, topic: "com.example.App")
        #expect(first.error?.knownReason == .tooManyProviderTokenUpdates)
        clock.advance(minutes: 30)
        _ = try await client.send(APNSNotification(items: [.alertBody("x")]), to: token64, topic: "com.example.App")
        let tokens = MockURLProtocol.requests.map(bearer)
        #expect(tokens.count == 2)
        #expect(tokens[0] == tokens[1])
    }

    // MARK: Batch send

    @Test func batchCarriesPerTokenResults() async throws {
        let client = try makeClient { i in i == 1 ? rejected(410, "Unregistered", timestamp: 1) : (i == 2 ? .fail(.networkConnectionLost) : ok()) }
        let other = String(repeating: "cd", count: 32)
        let third = String(repeating: "ef", count: 32)
        let fourth = String(repeating: "01", count: 32)
        let results = try await client.send(APNSNotification(items: [.alertBody("x")]),
                                            to: [token64, "not-a-token", other, third, fourth],
                                            topic: "com.example.App")
        #expect(results.map(\.deviceToken) == [token64, "not-a-token", other, third, fourth])
        #expect(try results[0].result.get().isSuccess)
        #expect(throws: APNSClientError.invalidDeviceToken) { try results[1].result.get() }
        #expect(try results[2].result.get().error?.knownReason == .unregistered)
        guard case .failure(.network) = results[3].result else { Issue.record("expected network failure"); return }
        #expect(try results[4].result.get().isSuccess)
        #expect(MockURLProtocol.requests.count == 4)
    }

    @Test func cancellingABatchKeepsTheResultsSoFar() async throws {
        let client = try makeClient(timeout: 60) { i in i < 2 ? ok() : .hang }
        let tokens = ["aa", "bb", "cc", "dd"].map { String(repeating: $0, count: 32) }
        let task = Task {
            try await client.send(APNSNotification(items: [.alertBody("x")]), to: tokens, topic: "com.example.App")
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let results = try await task.value
        #expect(results.map(\.deviceToken) == tokens)
        #expect(try results[0].result.get().isSuccess)
        #expect(try results[1].result.get().isSuccess)
        #expect(results[2].result == .failure(.cancelled))     // in flight
        #expect(results[3].result == .failure(.cancelled))     // never started
        #expect(MockURLProtocol.requests.count == 3)
        #expect(results[2] == APNSBatchResult(deviceToken: tokens[2], result: .failure(.cancelled)))
    }

    @Test func batchSharedProblemsThrowBeforeSending() async throws {
        let client = try makeClient { _ in ok() }
        await #expect(throws: APNSClientError.invalidTopic) {
            try await client.send(APNSNotification(items: [.alertBody("x")]), to: [token64, token64], topic: "bad topic")
        }
        #expect(MockURLProtocol.requests.isEmpty)
    }

    // MARK: Redaction

    @Test func clientNeverPrintsTheKeyOrToken() async throws {
        let key = P256.Signing.PrivateKey()
        let client = try makeClient(key: key) { _ in ok() }
        _ = try await client.send(APNSNotification(items: [.alertBody("x")]), to: token64, topic: "com.example.App")
        let token = try #require(bearer(MockURLProtocol.lastRequest))
        var dumped = ""
        dump(client, to: &dumped)
        let mirrored = Mirror(reflecting: client).children.map { "\($0.label ?? ""): \($0.value)" }.joined(separator: "\n")
        for text in ["\(client)", String(reflecting: client), dumped, mirrored] {
            #expect(!text.contains(token))
            #expect(!text.contains(String(token.split(separator: ".")[2])))
            #expect(!text.contains(key.rawRepresentation.base64EncodedString()))
            #expect(!text.contains("PRIVATE KEY"))
            #expect(text.contains(keyID))
        }
    }
}
