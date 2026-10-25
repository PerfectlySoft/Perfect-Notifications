import Foundation

/// Items that compose the `aps` dictionary and top-level custom keys of a push payload.
public enum APNSNotificationItem: Sendable, Equatable {
    // MARK: Alert
    /// Main body text of the alert banner.
    case alertBody(String)
    /// Bold title line of the alert banner.
    case alertTitle(String)
    /// Subtitle line below the title.
    case alertSubtitle(String)
    /// Localizable title key + optional format args.
    case alertTitleLoc(String, [String]?)
    /// Localizable action button key.
    case alertActionLoc(String)
    /// Localizable body key + optional format args.
    case alertLoc(String, [String]?)
    /// Launch image filename to display when the app opens from the notification.
    case alertLaunchImage(String)

    // MARK: APS
    /// App badge count. Pass `0` to clear the badge.
    case badge(Int)
    /// Sound name, or `"default"` for the system sound.
    case sound(String)
    /// Signals a silent background refresh (content-available: 1). Pair with `.background` push type.
    case contentAvailable
    /// Triggers a Notification Service Extension for end-to-end encryption or media attachment.
    case mutableContent
    /// Notification category identifier (for actionable notifications).
    case category(String)
    /// Groups notifications by topic in Notification Center.
    case threadId(String)
    /// Deep-link target content identifier (navigates the app to specific content).
    case targetContentId(String)
    /// How the notification interrupts the user.
    case interruptionLevel(InterruptionLevel)
    /// 0.0–1.0. Higher values surface the notification more prominently in summaries.
    case relevanceScore(Double)

    // MARK: Custom
    /// A top-level JSON key/value pair outside the `aps` dictionary. The key `aps` is
    /// reserved and makes ``APNSNotification/init(items:)`` throw.
    ///
    /// Literals work directly: `.customPayload("orderId", "ORD-123")`, `.customPayload("n", 49)`.
    case customPayload(String, APNSJSONValue)

    public enum InterruptionLevel: String, Sendable {
        case passive
        case active
        case timeSensitive = "time-sensitive"
        case critical
    }
}

/// A push notification payload ready to send.
///
/// The size limit (4096 bytes, or 5120 for VoIP) depends on the push type, so it is
/// checked when the notification is sent.
public struct APNSNotification: Sendable, Equatable {
    /// The encoded JSON payload.
    public let payload: Data

    /// Build from notification items (recommended for standard alerts).
    ///
    /// - Throws: ``APNSClientError/reservedPayloadKey(_:)`` for a custom `aps` key, or an
    ///   `EncodingError` for a non-finite number.
    public init(items: [APNSNotificationItem]) throws {
        self.payload = try APNSNotificationItem.encodePayload(items)
    }

    /// Supply a raw pre-encoded JSON payload. It is sent as is.
    public init(raw: Data) {
        self.payload = raw
    }

    /// Encode an `Encodable` value as the entire payload (must include the `aps` key).
    public init<T: Encodable & Sendable>(encodable: T) throws {
        self.payload = try JSONEncoder().encode(encodable)
    }
}

// MARK: - Payload encoding

extension APNSNotificationItem {
    static func encodePayload(_ items: [APNSNotificationItem]) throws -> Data {
        var top   = [String: APNSJSONValue]()
        var aps   = [String: APNSJSONValue]()
        var alert = [String: APNSJSONValue]()
        var alertBody: String?

        for item in items {
            switch item {
            case .alertBody(let s):        alertBody = s
            case .alertTitle(let s):       alert["title"] = .string(s)
            case .alertSubtitle(let s):    alert["subtitle"] = .string(s)
            case .alertTitleLoc(let s, let a):
                alert["title-loc-key"] = .string(s)
                if let args = a { alert["title-loc-args"] = .array(args.map(APNSJSONValue.string)) }
            case .alertActionLoc(let s):   alert["action-loc-key"] = .string(s)
            case .alertLoc(let s, let a):
                alert["loc-key"] = .string(s)
                if let args = a { alert["loc-args"] = .array(args.map(APNSJSONValue.string)) }
            case .alertLaunchImage(let s): alert["launch-image"] = .string(s)
            case .badge(let i):            aps["badge"] = .int(i)
            case .sound(let s):            aps["sound"] = .string(s)
            case .contentAvailable:        aps["content-available"] = 1
            case .mutableContent:          aps["mutable-content"] = 1
            case .category(let s):         aps["category"] = .string(s)
            case .threadId(let s):         aps["thread-id"] = .string(s)
            case .targetContentId(let s):  aps["target-content-id"] = .string(s)
            case .interruptionLevel(let l): aps["interruption-level"] = .string(l.rawValue)
            case .relevanceScore(let d):   aps["relevance-score"] = .double(d)
            case .customPayload(let k, let v):
                guard k != "aps" else { throw APNSClientError.reservedPayloadKey(k) }
                top[k] = v
            }
        }

        if let body = alertBody {
            if alert.isEmpty { aps["alert"] = .string(body) }
            else { alert["body"] = .string(body); aps["alert"] = .object(alert) }
        } else if !alert.isEmpty {
            aps["alert"] = .object(alert)
        }

        top["aps"] = .object(aps)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(top)
    }
}
