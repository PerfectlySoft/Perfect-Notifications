import Foundation

/// The outcome of a single APNs send request.
public struct APNSResponse: Sendable {
    /// HTTP status code returned by APNs (200 = success).
    public let statusCode: Int
    /// The notification ID assigned by APNs (`apns-id` response header).
    public let apnsID: String?
    /// Non-nil when APNs rejected the notification.
    public let error: APNSResponseError?

    public var isSuccess: Bool { statusCode == 200 }
}

/// An error reason returned by the APNs gateway.
///
/// Common reason strings: `BadDeviceToken`, `DeviceTokenNotForTopic`, `Unregistered`,
/// `ExpiredToken`, `PayloadTooLarge`, `InvalidProviderToken`, `ExpiredProviderToken`,
/// `TooManyRequests`, `InternalServerError`, `ServiceUnavailable`.
public struct APNSResponseError: Sendable, Equatable, CustomStringConvertible {
    public let reason: String
    /// For `Unregistered`/`ExpiredToken` — epoch timestamp when the token became invalid.
    public let timestamp: Int?

    public var description: String {
        guard let ts = timestamp else { return reason }
        return "\(reason) (invalidated at \(ts))"
    }
}

// MARK: - Internal decoding

struct APNSErrorBody: Decodable {
    let reason: String
    let timestamp: Int?
}
