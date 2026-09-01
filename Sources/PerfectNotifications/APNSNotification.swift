import Foundation

/// Items that compose the `aps` dictionary and top-level custom keys of a push payload.
///
/// - Note: `@unchecked Sendable` because ``customPayload(_:_:)`` accepts `Any` for
///   JSON flexibility. In practice only JSON-compatible types (String, Int, Double,
///   Bool, [String: Any], [Any]) should be used.
public enum APNSNotificationItem: @unchecked Sendable {
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
    /// A top-level JSON key/value pair outside the `aps` dictionary.
    case customPayload(String, Any)

    public enum InterruptionLevel: String, Sendable {
        case passive
        case active
        case timeSensitive = "time-sensitive"
        case critical
    }
}

/// A push notification payload ready to send.
public struct APNSNotification: Sendable {
    let payload: Data

    /// Build from notification items (recommended for standard alerts).
    public init(items: [APNSNotificationItem]) throws {
        self.payload = try APNSNotificationItem.encodePayload(items)
    }

    /// Supply a raw pre-encoded JSON payload.
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
        var top   = [String: Any]()
        var aps   = [String: Any]()
        var alert = [String: Any]()
        var alertBody: String?
        var hasAlertDict = false

        for item in items {
            switch item {
            case .alertBody(let s):   alertBody = s
            case .alertTitle(let s):  alert["title"] = s;       hasAlertDict = true
            case .alertSubtitle(let s): alert["subtitle"] = s;  hasAlertDict = true
            case .alertTitleLoc(let s, let a):
                alert["title-loc-key"] = s
                if let args = a { alert["title-loc-args"] = args }
                hasAlertDict = true
            case .alertActionLoc(let s):
                alert["action-loc-key"] = s;                    hasAlertDict = true
            case .alertLoc(let s, let a):
                alert["loc-key"] = s
                if let args = a { alert["loc-args"] = args }
                hasAlertDict = true
            case .alertLaunchImage(let s):
                alert["launch-image"] = s;                      hasAlertDict = true
            case .badge(let i):          aps["badge"] = i
            case .sound(let s):          aps["sound"] = s
            case .contentAvailable:      aps["content-available"] = 1
            case .mutableContent:        aps["mutable-content"] = 1
            case .category(let s):       aps["category"] = s
            case .threadId(let s):       aps["thread-id"] = s
            case .targetContentId(let s):aps["target-content-id"] = s
            case .interruptionLevel(let l): aps["interruption-level"] = l.rawValue
            case .relevanceScore(let d): aps["relevance-score"] = d
            case .customPayload(let k, let v): top[k] = v
            }
        }

        if let body = alertBody {
            if hasAlertDict { alert["body"] = body; aps["alert"] = alert }
            else             { aps["alert"] = body }
        } else if hasAlertDict {
            aps["alert"] = alert
        }

        top["aps"] = aps
        return try JSONSerialization.data(withJSONObject: top)
    }
}
