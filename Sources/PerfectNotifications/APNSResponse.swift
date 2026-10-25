import Foundation

/// The outcome of a single APNs send request.
public struct APNSResponse: Sendable, Equatable {
    /// HTTP status code returned by APNs (200 = success).
    public let statusCode: Int
    /// The notification ID (`apns-id` response header).
    public let apnsID: String?
    /// The `apns-unique-id` response header. APNs only sends it in the sandbox environment;
    /// it identifies the notification in the Push Notifications Console delivery log.
    public let apnsUniqueID: String?
    /// Non-nil when APNs rejected the notification and said why.
    public let error: APNSResponseError?

    public var isSuccess: Bool { statusCode == 200 }
}

/// An error reason returned by the APNs gateway.
public struct APNSResponseError: Sendable, Equatable, CustomStringConvertible {
    /// The `reason` string, such as `BadDeviceToken`. See ``APNSErrorReason`` for the known values.
    public let reason: String
    /// For HTTP 410 (`Unregistered`, `ExpiredToken`): the last time APNs confirmed that the
    /// device token was no longer valid for the topic, in **milliseconds** since the epoch.
    public let timestamp: Int64?

    /// ``reason`` as a known value, or `nil` for a reason this version doesn't know.
    public var knownReason: APNSErrorReason? { APNSErrorReason(rawValue: reason) }

    /// ``timestamp`` as a `Date`.
    public var invalidatedAt: Date? {
        timestamp.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }

    public var description: String {
        guard let ts = timestamp else { return reason }
        return "\(reason) (invalidated at \(ts) ms)"
    }
}

/// The `reason` values APNs documents (from Apple's "Handling notification responses from
/// APNs"), grouped by HTTP status. APNs may add reasons; ``APNSResponseError/reason``
/// always carries the raw string.
public enum APNSErrorReason: String, Sendable, CaseIterable {
    // 400
    case badCollapseID = "BadCollapseId"
    case badDeviceToken = "BadDeviceToken"
    case badExpirationDate = "BadExpirationDate"
    case badMessageID = "BadMessageId"
    case badPriority = "BadPriority"
    case badTopic = "BadTopic"
    case deviceTokenNotForTopic = "DeviceTokenNotForTopic"
    case duplicateHeaders = "DuplicateHeaders"
    case idleTimeout = "IdleTimeout"
    case invalidPushType = "InvalidPushType"
    case missingDeviceToken = "MissingDeviceToken"
    case missingTopic = "MissingTopic"
    case payloadEmpty = "PayloadEmpty"
    case topicDisallowed = "TopicDisallowed"
    // 403
    case badCertificate = "BadCertificate"
    case badCertificateEnvironment = "BadCertificateEnvironment"
    case expiredProviderToken = "ExpiredProviderToken"
    case forbidden = "Forbidden"
    case invalidProviderToken = "InvalidProviderToken"
    case missingProviderToken = "MissingProviderToken"
    case unrelatedKeyIDInToken = "UnrelatedKeyIdInToken"
    case badEnvironmentKeyInToken = "BadEnvironmentKeyInToken"
    // 404, 405
    case badPath = "BadPath"
    case methodNotAllowed = "MethodNotAllowed"
    // 410
    case expiredToken = "ExpiredToken"
    case unregistered = "Unregistered"
    // 413
    case payloadTooLarge = "PayloadTooLarge"
    // 429
    case tooManyProviderTokenUpdates = "TooManyProviderTokenUpdates"
    case tooManyRequests = "TooManyRequests"
    // 500, 503
    case internalServerError = "InternalServerError"
    case serviceUnavailable = "ServiceUnavailable"
    case shutdown = "Shutdown"
}

/// The per-token outcome of sending one notification to several device tokens.
public struct APNSBatchResult: Sendable, Equatable {
    public let deviceToken: String
    /// The APNs response (which may itself be a rejection), or the client error that
    /// stopped this token's request: an invalid token, a network failure, a timeout, or
    /// ``APNSClientError/cancelled`` for tokens reached after the batch was cancelled.
    public let result: Result<APNSResponse, APNSClientError>
}

// MARK: - Internal decoding

struct APNSErrorBody: Decodable {
    let reason: String
    let timestamp: Int64?
}
