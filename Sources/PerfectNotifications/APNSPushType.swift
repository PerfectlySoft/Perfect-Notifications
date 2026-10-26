import Foundation

/// The type of push notification being sent (`apns-push-type`).
/// Required by APNs since iOS 13. Each value carries a default priority.
///
/// APNs also expects a matching topic suffix for some types: `.voip` → `<bundle>.voip`,
/// `.complication` → `<bundle>.complication`, `.fileProvider` → `<bundle>.pushkit.fileprovider`,
/// `.liveActivity` → `<bundle>.push-type.liveactivity`, `.location` → `<bundle>.location-query`,
/// `.pushToTalk` → `<bundle>.voip-ptt`. The client checks the topic's syntax, not the suffix;
/// APNs answers a mismatch with `DeviceTokenNotForTopic` or `TopicDisallowed`.
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

    /// Default `apns-priority` for this type: `.background` for background pushes
    /// (APNs requires it), `.immediate` for everything else.
    public var defaultPriority: APNSPriority {
        self == .background ? .background : .immediate
    }
}

/// Push notification priority (`apns-priority`).
public enum APNSPriority: Int, Sendable, CaseIterable {
    /// 10: deliver immediately. The default for everything but background pushes.
    case immediate  = 10
    /// 5: deliver based on the power considerations of the device. Required for
    /// `APNSPushType.background`; also valid for alerts that can wait.
    case background = 5
    /// 1: prioritize the device's power considerations over all other factors, and
    /// don't wake the device.
    case low = 1
}

/// When to discard an undeliverable notification (`apns-expiration`).
public enum APNSExpiration: Sendable, Equatable {
    /// Discard immediately if the device is not reachable (`apns-expiration: 0`).
    case immediate
    /// Keep until this many seconds from now. Must not be negative.
    case relative(Int)
    /// Keep until this absolute UTC epoch second. Must not be negative.
    case absolute(Int)

    /// The header value, or ``APNSClientError/invalidExpiration`` for a negative value
    /// or a relative value that overflows.
    func headerValue(now: Date) throws(APNSClientError) -> Int {
        switch self {
        case .immediate:
            return 0
        case .relative(let seconds):
            guard seconds >= 0 else { throw .invalidExpiration }
            let (sum, overflow) = Int(now.timeIntervalSince1970).addingReportingOverflow(seconds)
            guard !overflow else { throw .invalidExpiration }
            return sum
        case .absolute(let epoch):
            guard epoch >= 0 else { throw .invalidExpiration }
            return epoch
        }
    }
}
