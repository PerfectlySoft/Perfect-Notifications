# Perfect-Notifications

<p align="center">
    <img src="https://img.shields.io/badge/Swift-6.2-orange.svg?style=flat" alt="Swift 6.2">
    <img src="https://img.shields.io/badge/Platforms-macOS%2012%2B-lightgray.svg?style=flat" alt="Platforms macOS 12+">
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache-lightgrey.svg?style=flat" alt="License Apache"></a>
</p>

APNs remote Notifications for Perfect. This package adds push notification support to your server. Send notifications to iOS/macOS devices.

**A from-scratch Swift 6 rewrite** of the original package. The public API (`APNSClient`) is a
completely different, modern async/await surface — it does not use the original
`NotificationPusher` class. No dependency on NIO, PerfectHTTP, or any other package here —
networking runs over Foundation's `URLSession` async API, with
[apple/swift-crypto](https://github.com/apple/swift-crypto) as the only external dependency, used
to sign ES256 APNs provider JWTs.

The pre-Swift-6 version of this package is preserved on the [`legacy`](../../tree/legacy) branch.

Building
--------

This is a Swift Package Manager based project targeting **Swift 6.2** (strict concurrency /
`.swiftLanguageMode(.v6)`), macOS 12+. No other platform is currently declared in `Package.swift`
(Linux support has not been verified).

Add this repository as a dependency in your `Package.swift` file:

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
.package(url: "https://github.com/PerfectlySoft/Perfect-Notifications.git", branch: "main")
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Overview
--------

This system runs on the server side. Typically at app launch, an Apple device will register with Apple's system for remote notifications. Doing so will return to the device an ID which can be used by external systems to address the device and send notifications through APNs.

When the device obtains its ID it will need to transmit it to **your** server. Your server will store this id and use it when sending notifications to one or more devices through APNs.

The client itself, `APNSClient`, is a `Sendable` struct with `async throws` send methods — there is no callback-based API and no separate "configuration registry" step; you construct one client per set of APNs credentials and call `send`/`sendAlert`/`sendBackground` directly.

Obtain APNs Auth Key
--------

To connect your server to Apple's push notification system you will first need to obtain an "APNs Auth Key". This key is used on your server to configure its APNs access. You can generate this key through your Apple developer account portal. Log in to your developer account and choose "Certificates, IDs &amp; Profiles" from the menu. Then, under "Keys", choose "All".

If you haven't already created and downloaded the auth key, click "+" to create a new one. Enter a name for the key and make sure you select **Apple Push Notifications service (APNs)**. This one key can be used for both development or production and can be used for any of your iOS/macOS apps.

Click "Continue", then "Confirm", then you will be given a chance to download the **private key**. You must download this key now and **save the file**. Also copy the "Key ID" shown in the same view. This will be a 10 character string.

Finally you will need to locate your developer team id. Click "Account" near the window's top. Select "Membership" in the menu. You will then be shown much of your personal information, including "Team ID". This is another 10 character string. Copy this value.

Server Configuration
------

To send notifications from your server your must have four pieces of information:

1. The private key (`.p8`) file which was downloaded, or its PEM contents
2. The 10 character key id
3. Your 10 character team id
4. An iOS/macOS app id ("topic")

Unlike the original Perfect-era API, there is no separate "add a named configuration, then look it up later" step — you construct an `APNSClient` directly with the key material, and it internally mints and caches (auto-rotating every 55 minutes, before Apple's 60-minute expiry) the ES256 JWT provider token via `APNSCredentials` and swift-crypto.

```swift
import PerfectNotifications

let apnsKeyIdentifier  = "AB90CD56XY"
let apnsTeamIdentifier = "YX65DC09BA"
let apnsPrivateKeyFilePath = "./APNsAuthKey_AB90CD56XY.p8"
let topic = "my.app.id"

let client = try APNSClient(
    keyID: apnsKeyIdentifier,
    teamID: apnsTeamIdentifier,
    privateKeyPath: apnsPrivateKeyFilePath,
    environment: .sandbox // .production for release builds
)

let notification = try APNSNotification(items: [
    .alertTitle("Hello!"),
    .sound("default")
])

let response = try await client.send(notification, to: deviceToken, topic: topic)
if response.isSuccess {
    print("sent — apns-id: \(response.apnsID ?? "?")")
} else if let err = response.error {
    print("rejected: \(err.reason)")
}
```

`APNSCredentials` can also be supplied a PEM string directly (`APNSClient(keyID:teamID:pemString:environment:)`) instead of a file path — useful when the key is loaded from an environment variable or secrets store.

Public API
----

The full public API surface follows:

```swift
public struct APNSClient: Sendable {
    public enum Environment: Sendable { case sandbox, production }

    /// Load the signing key from a `.p8` file on disk.
    public init(keyID: String, teamID: String, privateKeyPath: String,
                environment: Environment = .sandbox,
                urlSession: URLSession = .shared) throws

    /// Supply the `.p8` key as a PEM string.
    public init(keyID: String, teamID: String, pemString: String,
                environment: Environment = .sandbox,
                urlSession: URLSession = .shared) throws

    /// Send a notification to a single device token.
    public func send(
        _ notification: APNSNotification,
        to deviceToken: String,
        topic: String,
        pushType: APNSPushType = .alert,
        priority: Int? = nil,
        expiration: APNSExpiration? = nil,
        collapseID: String? = nil
    ) async throws -> APNSResponse

    /// Send the same notification to multiple device tokens (sequential).
    public func send(
        _ notification: APNSNotification,
        to deviceTokens: [String],
        topic: String,
        pushType: APNSPushType = .alert,
        priority: Int? = nil,
        expiration: APNSExpiration? = nil,
        collapseID: String? = nil
    ) async throws -> [APNSResponse]

    /// Build and send a simple alert in one call.
    @discardableResult
    public func sendAlert(
        to deviceToken: String,
        topic: String,
        title: String,
        body: String? = nil,
        subtitle: String? = nil,
        badge: Int? = nil,
        sound: String? = nil,
        category: String? = nil,
        threadId: String? = nil,
        interruptionLevel: APNSNotificationItem.InterruptionLevel? = nil,
        collapseID: String? = nil,
        mutableContent: Bool = false
    ) async throws -> APNSResponse

    /// Send a silent background push (`content-available: 1`, priority 5).
    @discardableResult
    public func sendBackground(
        to deviceToken: String,
        topic: String,
        customData: [APNSNotificationItem] = []
    ) async throws -> APNSResponse
}
```

The remaining structures, including `APNSNotificationItem`, follow:

```swift
/// Items that compose the `aps` dictionary and top-level custom keys of a push payload.
/// `@unchecked Sendable` because `.customPayload` accepts `Any` for JSON flexibility.
public enum APNSNotificationItem: @unchecked Sendable {
    case alertBody(String)
    case alertTitle(String)
    case alertSubtitle(String)
    case alertTitleLoc(String, [String]?)
    case alertActionLoc(String)
    case alertLoc(String, [String]?)
    case alertLaunchImage(String)
    case badge(Int)
    case sound(String)
    case contentAvailable
    case mutableContent
    case category(String)
    case threadId(String)
    case targetContentId(String)
    case interruptionLevel(InterruptionLevel)
    case relevanceScore(Double)
    case customPayload(String, Any)

    public enum InterruptionLevel: String, Sendable {
        case passive, active
        case timeSensitive = "time-sensitive"
        case critical
    }
}

/// A push notification payload ready to send.
public struct APNSNotification: Sendable {
    public init(items: [APNSNotificationItem]) throws
    /// Supply a raw pre-encoded JSON payload.
    public init(raw: Data)
    /// Encode an `Encodable` value as the entire payload (must include the `aps` key).
    public init<T: Encodable & Sendable>(encodable: T) throws
}

/// The type of push notification being sent (required by APNs since iOS 13).
public enum APNSPushType: String, Sendable, CaseIterable {
    case alert, background, voip, complication
    case fileProvider = "fileprovider"
    case mdm, location
    case liveActivity = "liveactivity"
    case pushToTalk    = "pushtotalk"

    /// Background must use priority 5; all others default to 10.
    public var defaultPriority: Int
}

public enum APNSPriority: Int, Sendable {
    case immediate  = 10
    case background = 5
}

/// When to discard an undeliverable notification.
public enum APNSExpiration: Sendable {
    case immediate
    case relative(Int)
    case absolute(Int)
}

/// The outcome of a single APNs send request.
public struct APNSResponse: Sendable {
    public let statusCode: Int
    public let apnsID: String?
    public let error: APNSResponseError?
    public var isSuccess: Bool { statusCode == 200 }
}

/// An error reason returned by the APNs gateway (e.g. BadDeviceToken, Unregistered, ExpiredProviderToken).
public struct APNSResponseError: Sendable, Equatable, CustomStringConvertible {
    public let reason: String
    public let timestamp: Int?
}
```

Additional Notes
----

APNs requests are made from your server to Apple's servers `api.sandbox.push.apple.com` (development) or `api.push.apple.com` (production) on port 443, via `URLSession`'s async `data(for:)`. `URLSession` handles HTTP/2 connection reuse internally, in accordance with Apple's recommended usage of APNs.

The package targets **Swift 6.2 with strict concurrency** enabled (`.swiftLanguageMode(.v6)` on both the library and test targets). `APNSClient`, `APNSNotification`, `APNSPushType`, `APNSResponse`, and `APNSResponseError` are plain `Sendable`; `APNSCredentials` and `APNSNotificationItem` are `@unchecked Sendable` (an `NSLock`-guarded JWT cache and an `Any`-typed payload case, respectively). No actors are used — `APNSCredentials` synchronizes its cached-token state with `NSLock`.

The `Perfect-NotificationsExample` project linked from the original PerfectlySoft repo targets the legacy callback-based `NotificationPusher` API and is **not** compatible with this fork's `APNSClient`; treat it as historical reference only, not a working example for this package.

## Further Information
For more information on the Perfect project, please visit [perfect.org](http://perfect.org).
