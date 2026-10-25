import Testing
import Foundation
import Crypto
@testable import PerfectNotifications

/// Payload encoding, JSON values, validation and JWT minting: no transport involved.
struct PayloadTests {

    static let invalidDeviceTokens: [String] = {
        let a64 = String(repeating: "a", count: 64)
        var list: [String] = ["", "abc123token"]
        list.append(String(repeating: "a", count: 63))
        list.append(String(repeating: "a", count: 65))
        list.append(String(repeating: "a", count: 202))
        list.append("../../../3/device/" + a64)
        list.append(a64 + "?x=1")
        list.append(a64 + "#frag")
        list.append(a64 + "/")
        list.append("zz" + String(a64.dropFirst(2)))
        list.append(a64 + " ")
        list.append("\u{FF21}\u{FF22}" + String(a64.dropFirst(2)))
        list.append(a64 + "\r\nx: y")
        list.append(String(repeating: "\u{0661}", count: 64))
        return list
    }()

    // MARK: Push type and priority

    @Test func pushTypeRawValues() {
        #expect(APNSPushType.alert.rawValue        == "alert")
        #expect(APNSPushType.background.rawValue   == "background")
        #expect(APNSPushType.liveActivity.rawValue == "liveactivity")
        #expect(APNSPushType.pushToTalk.rawValue   == "pushtotalk")
        #expect(APNSPushType.fileProvider.rawValue == "fileprovider")
    }

    @Test func defaultPriorities() {
        #expect(APNSPushType.background.defaultPriority == .background)
        for type in APNSPushType.allCases where type != .background {
            #expect(type.defaultPriority == .immediate)
        }
        #expect(APNSPriority.allCases.map(\.rawValue).sorted() == [1, 5, 10])
    }

    // MARK: Payload encoding

    @Test func simpleAlertEncodesToExpectedJSON() throws {
        let data = try APNSNotificationItem.encodePayload([
            .alertTitle("Hello"), .alertBody("World"), .badge(3), .sound("default")
        ])
        #expect(String(decoding: data, as: UTF8.self)
                == #"{"aps":{"alert":{"body":"World","title":"Hello"},"badge":3,"sound":"default"}}"#)
    }

    @Test func bodyOnlyAlertUsesStringNotDict() throws {
        let data = try APNSNotificationItem.encodePayload([.alertBody("Just a body")])
        #expect(String(decoding: data, as: UTF8.self) == #"{"aps":{"alert":"Just a body"}}"#)
    }

    @Test func contentAvailableAndMutableContentEncodeAsOne() throws {
        let aps = try json(APNSNotificationItem.encodePayload([.contentAvailable, .mutableContent]))["aps"] as? [String: Any]
        #expect(aps?["content-available"] as? Int == 1)
        #expect(aps?["mutable-content"]   as? Int == 1)
    }

    @Test func subtitleLocAndInterruptionLevelEncodeCorrectly() throws {
        let data = try APNSNotificationItem.encodePayload([
            .alertTitle("Title"), .alertSubtitle("Subtitle"),
            .alertLoc("KEY", ["a", "b"]), .interruptionLevel(.timeSensitive), .relevanceScore(0.8)
        ])
        let aps = try #require(try json(data)["aps"] as? [String: Any])
        let alert = try #require(aps["alert"] as? [String: Any])
        #expect(alert["subtitle"] as? String == "Subtitle")
        #expect(alert["loc-args"] as? [String] == ["a", "b"])
        #expect(aps["interruption-level"] as? String == "time-sensitive")
        #expect(aps["relevance-score"] as? Double == 0.8)
    }

    @Test func customPayloadLiteralsAppearAtTopLevel() throws {
        let data = try APNSNotificationItem.encodePayload([
            .alertBody("msg"),
            .customPayload("orderId", "ORD-123"),
            .customPayload("amount", 49),
            .customPayload("ratio", 0.5),
            .customPayload("refresh", true),
            .customPayload("none", nil),
            .customPayload("nested", ["ids": [1, 2], "ok": false]),
        ])
        #expect(String(decoding: data, as: UTF8.self) ==
                #"{"amount":49,"aps":{"alert":"msg"},"nested":{"ids":[1,2],"ok":false},"none":null,"orderId":"ORD-123","ratio":0.5,"refresh":true}"#)
    }

    @Test func customPayloadCannotReplaceAps() {
        #expect(throws: APNSClientError.reservedPayloadKey("aps")) {
            try APNSNotification(items: [.alertBody("x"), .customPayload("aps", ["alert": "spoof"])])
        }
    }

    @Test func nonFiniteNumbersAreRefused() {
        #expect(throws: (any Error).self) { try APNSNotification(items: [.relevanceScore(.nan)]) }
        #expect(throws: (any Error).self) { try APNSNotification(items: [.customPayload("x", .double(.infinity))]) }
    }

    @Test func notificationItemsAreSendableValues() {
        // Compile-time check: the 5.x `@unchecked Sendable` is gone.
        func requireSendable<T: Sendable & Equatable>(_: T) {}
        requireSendable(APNSNotificationItem.customPayload("k", ["a": [1, "two", nil]]))
        #expect(APNSNotificationItem.customPayload("k", 1) == .customPayload("k", .int(1)))
    }

    @Test func badgeAndRelevanceScoreRanges() throws {
        _ = try APNSNotification(items: [.badge(0), .relevanceScore(0), .relevanceScore(1)])
        #expect(throws: APNSClientError.invalidPayload("badge must not be negative")) {
            try APNSNotification(items: [.badge(-1)])
        }
        for score in [-0.01, 1.01, .nan, .infinity] {
            #expect(throws: APNSClientError.invalidPayload("relevanceScore must be 0-1")) {
                try APNSNotification(items: [.relevanceScore(score)])
            }
        }
    }

    @Test func rawPayloadMustBeAnObjectWithAps() throws {
        let ok = try APNSNotification(raw: Data(#"{"aps":{"alert":"x"},"k":1}"#.utf8))
        #expect(ok.payload.count == 27)
        for bad in ["", "[]", "\"aps\"", #"{"aps":"x"}"#, #"{"alert":"x"}"#, "{garbage", #"{"aps":{}"#] {
            #expect(throws: APNSClientError.self) { try APNSNotification(raw: Data(bad.utf8)) }
        }
    }

    // MARK: Nesting depth

    static func nestedArrays(_ depth: Int) -> APNSJSONValue {
        var v: APNSJSONValue = 1
        for _ in 0..<depth { v = .array([v]) }
        return v
    }

    /// Runs `body` on a thread with a 64 MiB stack: building and destroying a 20,000-deep
    /// value recurses in Swift's own value witnesses, which the test thread's stack can't
    /// take. The point is that the library itself doesn't recurse into it.
    static func onBigStack(_ body: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let thread = Thread { body(); done.resume() }
            thread.stackSize = 64 << 20
            thread.start()
        }
    }

    @Test func deepNestingIsRefusedWithoutCrashing() async throws {
        // Depth 20,000 used to overflow the stack in encodePayload and convert.
        await Self.onBigStack {
            #expect(throws: APNSClientError.jsonNestingTooDeep(limit: 64)) {
                try APNSNotification(items: [.customPayload("deep", Self.nestedArrays(20_000))])
            }
            var any: Any = 1
            for _ in 0..<20_000 { any = [any] }
            #expect(throws: APNSClientError.jsonNestingTooDeep(limit: 64)) { try APNSJSONValue(jsonObject: any) }
            let raw = String(repeating: "[", count: 20_000) + String(repeating: "]", count: 20_000)
            #expect(throws: (any Error).self) { try APNSNotification(raw: Data(#"{"aps":{},"x":\#(raw)}"#.utf8)) }
        }
        // The boundary: 63 levels under a top-level key (64 with the payload object) is fine.
        _ = try APNSNotification(items: [.customPayload("ok", Self.nestedArrays(63))])
        #expect(throws: APNSClientError.jsonNestingTooDeep(limit: 64)) {
            try APNSNotification(items: [.customPayload("deep", Self.nestedArrays(64))])
        }
        var sixtyFour: Any = 1
        for _ in 0..<64 { sixtyFour = [sixtyFour] }
        #expect(try APNSJSONValue(jsonObject: sixtyFour) == Self.nestedArrays(64))
        sixtyFour = [sixtyFour]
        #expect(throws: APNSClientError.jsonNestingTooDeep(limit: 64)) { try APNSJSONValue(jsonObject: sixtyFour) }
    }

    // MARK: APNSJSONValue

    @Test func unsignedValuesAboveIntMaxAreRefused() throws {
        #expect(throws: APNSClientError.self) { try APNSJSONValue(jsonObject: UInt64.max) }
        #expect(throws: APNSClientError.self) { try APNSJSONValue(jsonObject: NSNumber(value: UInt64.max)) }
        #expect(throws: APNSClientError.self) { try APNSJSONValue(jsonObject: UInt(Int.max) + 1) }
        #expect(try APNSJSONValue(jsonObject: UInt64(Int.max)) == .int(Int.max))
        #expect(try APNSJSONValue(jsonObject: NSNumber(value: UInt64(42))) == 42)
        // Whatever JSONSerialization makes of 2^64 - 1, it must not come out as -1.
        let parsed = try JSONSerialization.jsonObject(with: Data("[18446744073709551615]".utf8))
        if let value = try? APNSJSONValue(jsonObject: parsed) {
            #expect(value != [-1])
        }
    }

    @Test func jsonObjectConversionFromJSONSerialization() throws {
        let parsed = try JSONSerialization.jsonObject(with: Data(
            #"{"b":true,"f":false,"i":42,"d":1.5,"s":"x","n":null,"a":[1,"y"],"o":{"k":0}}"#.utf8))
        let value = try APNSJSONValue(jsonObject: parsed)
        #expect(value == [
            "b": true, "f": false, "i": 42, "d": 1.5, "s": "x", "n": nil, "a": [1, "y"], "o": ["k": 0],
        ])
    }

    @Test func jsonObjectConversionFromSwiftValues() throws {
        let dict: [String: Any] = ["i": 1, "b": true, "d": 2.25, "s": "str", "arr": [1, 2] as [Int],
                                   "opt": Optional<Int>.none as Any, "i64": Int64(7)]
        #expect(try APNSJSONValue(jsonObject: dict) == [
            "i": 1, "b": true, "d": 2.25, "s": "str", "arr": [1, 2], "opt": nil, "i64": 7,
        ])
    }

    @Test func jsonObjectConversionRefusesNonJSON() {
        #expect(throws: APNSClientError.self) { try APNSJSONValue(jsonObject: Date()) }
        #expect(throws: APNSClientError.self) { try APNSJSONValue(jsonObject: [1: "int key"]) }
        #expect(throws: APNSClientError.self) { try APNSJSONValue(jsonObject: Double.nan) }
    }

    @Test func jsonValueRoundTrips() throws {
        let value: APNSJSONValue = ["a": [1, 2.5, "s", true, nil], "o": ["x": ["y": false]]]
        let decoded = try JSONDecoder().decode(APNSJSONValue.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
    }

    // MARK: Validation

    @Test(arguments: invalidDeviceTokens)
    func invalidDeviceTokensAreRefused(_ token: String) {
        #expect(throws: APNSClientError.invalidDeviceToken) { try APNSValidation.deviceToken(token) }
    }

    @Test func validDeviceTokens() throws {
        try APNSValidation.deviceToken(token64)
        try APNSValidation.deviceToken(token64.uppercased())
        try APNSValidation.deviceToken(String(repeating: "0f", count: 100))
    }

    @Test(arguments: [
        "com.example.App", "com.example.App.voip", "com.example.App.complication",
        "com.example.App.pushkit.fileprovider", "com.example.App.push-type.liveactivity",
        "com.example.App.voip-ptt", "com.example.App.location-query",
        "com.apple.mgmt.External.7F3B4D8E-1111-2222-3333-444455556666", "App",
    ])
    func validTopics(_ topic: String) throws {
        try APNSValidation.topic(topic)
    }

    @Test(arguments: [
        "", "com.example.App\r\napns-priority: 10", "com.example.App\n", "com example", "com..example",
        ".com.example", "com.example.", "com/example", "com.exämple", "com.example_app", "a256",
    ] as [String])
    func invalidTopicsAreRefused(_ topic: String) {
        let topic = topic == "a256" ? String(repeating: "a", count: 256) : topic
        #expect(throws: APNSClientError.invalidTopic) { try APNSValidation.topic(topic) }
    }

    @Test func collapseIDLimits() throws {
        try APNSValidation.collapseID(String(repeating: "x", count: 64))
        try APNSValidation.collapseID("order-42:v2_(a)~!")
        #expect(throws: APNSClientError.invalidCollapseID) { try APNSValidation.collapseID(String(repeating: "x", count: 65)) }
        // The reviewer's cases: leading space, trailing space, bidi override + ZWJ.
        for bad in [" lead", "trail ", "a\u{202E}b\u{200D}",
                    "", "inner space", "é-collapse", "a\r\nb: c", "a\nb", "a\u{0}b", "a\u{7F}", "a\u{85}",
                    "a\u{2028}b", "tab\there"] {
            #expect(throws: APNSClientError.invalidCollapseID) { try APNSValidation.collapseID(bad) }
        }
    }

    @Test func expirationHeaderValues() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(try APNSExpiration.immediate.headerValue(now: now) == 0)
        #expect(try APNSExpiration.relative(3600).headerValue(now: now) == 1_800_003_600)
        #expect(try APNSExpiration.absolute(1_900_000_000).headerValue(now: now) == 1_900_000_000)
        #expect(throws: APNSClientError.invalidExpiration) { try APNSExpiration.relative(.max).headerValue(now: now) }
        #expect(throws: APNSClientError.invalidExpiration) { try APNSExpiration.relative(-1).headerValue(now: now) }
        #expect(throws: APNSClientError.invalidExpiration) { try APNSExpiration.absolute(-5).headerValue(now: now) }
    }

    // MARK: JWT

    @Test func jwtHasExactHeaderAndClaimsAndAValidSignature() throws {
        let key = P256.Signing.PrivateKey()
        let clock = TestClock()
        let creds = try credentials(key, clock: clock)
        let jwt = try decodeJWT(creds.token(), publicKey: key.publicKey)
        #expect(jwt.headerJSON == #"{"alg":"ES256","kid":"ABCDE12345"}"#)
        #expect(jwt.claimsJSON == #"{"iat":1800000000,"iss":"TEAM123456"}"#)
        #expect(jwt.signatureValid)
        // And not with another key.
        #expect(try !decodeJWT(creds.token(), publicKey: P256.Signing.PrivateKey().publicKey).signatureValid)
    }

    @Test func jwtPartsAreUnpaddedBase64URL() throws {
        let creds = try APNSCredentials(keyID: keyID, teamID: teamID, key: P256.Signing.PrivateKey())
        let parts = try creds.token().split(separator: ".", omittingEmptySubsequences: false)
        #expect(parts.count == 3)
        for part in parts {
            #expect(!part.isEmpty)
            #expect(!part.contains(where: { "+/=".contains($0) }))
        }
    }

    @Test(arguments: [
        "ABCDE1234", "ABCDE123456", #"ABCD","x":"1"#, "ABCDE1234\"", "ABCDE 1234", "ABCDÉ12345", "",
    ])
    func malformedKeyAndTeamIDsAreRefused(_ id: String) {
        let key = P256.Signing.PrivateKey()
        #expect(throws: APNSClientError.invalidKeyID) { try APNSCredentials(keyID: id, teamID: teamID, key: key) }
        #expect(throws: APNSClientError.invalidTeamID) { try APNSCredentials(keyID: keyID, teamID: id, key: key) }
        #expect(throws: APNSClientError.invalidKeyID) {
            try APNSClient(keyID: id, teamID: teamID, pemString: key.pemRepresentation)
        }
    }

    @Test func tokenIsCachedThenRefreshedAtFiftyMinutes() throws {
        let clock = TestClock()
        let creds = try credentials(clock: clock)
        let first = try creds.token()
        clock.advance(minutes: 49.9)
        #expect(try creds.token() == first)
        clock.advance(minutes: 0.2)
        let second = try creds.token()
        #expect(second != first)
        #expect(try creds.token() == second)
    }

    @Test func rejectedTokenIsReplacedOnlyAfterTwentyMinutes() throws {
        let clock = TestClock()
        let creds = try credentials(clock: clock)
        let first = try creds.token()
        clock.advance(minutes: 5)
        #expect(creds.reject(first) == false)       // too soon to mint again
        #expect(try creds.token() == first)
        clock.advance(minutes: 15)                  // 20 minutes old
        #expect(creds.reject(first) == true)
        let second = try creds.token()
        #expect(second != first)
        #expect(creds.reject(first) == true)        // stale token: already replaced
        #expect(try creds.token() == second)
    }

    @Test func wallClockStepsDontAffectTokenAge() throws {
        let clock = TestClock()
        let creds = try credentials(clock: clock)
        let first = try creds.token()
        // Backwards steps (repeated, as a misbehaving VM clock might): no new mints.
        for _ in 0..<20 { clock.stepWall(minutes: -1.1) }
        #expect(try creds.token() == first)
        clock.stepWall(minutes: -90)
        #expect(try creds.token() == first)
        // A forward wall step doesn't age the token either.
        clock.stepWall(minutes: 600)
        #expect(try creds.token() == first)
        // Real (monotonic) time does.
        clock.advance(minutes: 50)
        #expect(try creds.token() != first)
    }

    @Test func monotonicClockIsMonotonic() {
        let a = monotonicSeconds()
        let b = monotonicSeconds()
        #expect(a > 0 && b >= a)
    }

    // MARK: Redaction

    @Test func credentialsNeverPrintTheKey() throws {
        let key = P256.Signing.PrivateKey()
        let creds = try APNSCredentials(keyID: keyID, teamID: teamID, key: key)
        let token = try creds.token()
        var dumped = ""
        dump(creds, to: &dumped)
        for text in ["\(creds)", String(reflecting: creds), dumped] {
            #expect(!text.contains(token))
            #expect(!text.contains(String(token.split(separator: ".")[2])))
            #expect(!text.contains(key.rawRepresentation.base64EncodedString()))
            #expect(text.contains("<redacted>"))
        }
    }
}
