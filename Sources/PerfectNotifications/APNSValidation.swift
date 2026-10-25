import Foundation

/// Client-side checks on everything that goes into the request line, the headers or
/// the JWT. APNs would reject most bad values itself, but an unchecked device token or
/// topic could change the request path or add headers, so they are refused before any
/// request is built.
enum APNSValidation {

    /// Device tokens are hex. They are 32 bytes (64 hex digits) today; Apple says not to
    /// hard-code the length, so up to 100 bytes (200 hex digits) is accepted.
    static let deviceTokenHexLength = 64...200

    /// `apns-collapse-id` must not exceed 64 bytes.
    static let maxCollapseIDBytes = 64

    /// The deepest JSON nesting accepted in payloads (APNs payloads are a few levels deep;
    /// the cap keeps recursive encoding and conversion off the end of the stack).
    static let maxJSONDepth = 64

    /// Payload limits: 4 KB for regular pushes, 5 KB for VoIP.
    static func payloadLimit(for pushType: APNSPushType) -> Int {
        pushType == .voip ? 5120 : 4096
    }

    static func deviceToken(_ token: String) throws(APNSClientError) {
        let bytes = token.utf8
        guard deviceTokenHexLength.contains(bytes.count), bytes.count % 2 == 0,
              bytes.allSatisfy(isHexDigit) else {
            throw .invalidDeviceToken
        }
    }

    /// A bundle ID, optionally with an APNs suffix (`.voip`, `.complication`,
    /// `.pushkit.fileprovider`, `.push-type.liveactivity`, `.voip-ptt`, `.location-query`),
    /// or an MDM topic: dot-separated, non-empty segments of ASCII letters, digits and `-`.
    static func topic(_ topic: String) throws(APNSClientError) {
        let bytes = topic.utf8
        guard (1...255).contains(bytes.count),
              bytes.allSatisfy({ isAlphanumeric($0) || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: ".") }),
              !topic.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty)
        else {
            throw .invalidTopic
        }
    }

    /// 1–64 printable ASCII characters, `!` (0x21) through `~` (0x7E). Apple only documents
    /// the 64-byte limit; spaces and non-ASCII are refused to stay on the safe side.
    static func collapseID(_ id: String) throws(APNSClientError) {
        let bytes = id.utf8
        guard (1...maxCollapseIDBytes).contains(bytes.count),
              bytes.allSatisfy({ (0x21...0x7E).contains($0) }) else {
            throw .invalidCollapseID
        }
    }

    /// Apple key IDs and team IDs are 10 ASCII letters or digits.
    static func isTenCharacterID(_ s: String) -> Bool {
        s.utf8.count == 10 && s.utf8.allSatisfy(isAlphanumeric)
    }

    /// A host name or IPv4 address for ``APNSClient/Environment/custom(host:port:)``.
    static func host(_ host: String, port: Int) throws(APNSClientError) {
        let bytes = host.utf8
        guard (1...253).contains(bytes.count), (1...65535).contains(port),
              bytes.allSatisfy({ isAlphanumeric($0) || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: ".") }),
              !host.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty)
        else {
            throw .invalidHost
        }
    }

    private static func isHexDigit(_ b: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(b)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(b)
    }

    private static func isAlphanumeric(_ b: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(b)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(b)
    }
}
