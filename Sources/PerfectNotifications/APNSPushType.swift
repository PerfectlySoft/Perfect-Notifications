import Foundation

/// The type of push notification being sent.
/// Required by APNs since iOS 13. Each value carries a default priority.
public enum APNSPushType: String, Sendable, CaseIterable {
    case alert
    case background
    case voip
    case complication
    case fileProvider  = "fileprovider"
    case mdm
    case location
    case liveActivity  = "liveactivity"
    case pushToTalk    = "pushtotalk"

    /// Default `apns-priority` for this type. Background must use 5; others use 10.
    public var defaultPriority: Int {
        self == .background ? 5 : 10
    }
}

/// Push notification priority.
public enum APNSPriority: Int, Sendable {
    /// Immediate delivery (10). Use for user-visible alerts.
    case immediate  = 10
    /// Power-friendly delivery (5). Required for background push.
    case background = 5
}

/// When to discard an undeliverable notification.
public enum APNSExpiration: Sendable {
    /// Discard immediately if the device is not reachable.
    case immediate
    /// Keep until this many seconds from now.
    case relative(Int)
    /// Keep until this absolute UTC epoch second.
    case absolute(Int)

    var headerValue: Int {
        switch self {
        case .immediate:       return 0
        case .relative(let s): return Int(Date().timeIntervalSince1970) + s
        case .absolute(let t): return t
        }
    }
}
