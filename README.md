# Perfect-Notifications

<p align="center">
    <img src="https://img.shields.io/badge/Swift-6.2%2B-orange.svg?style=flat" alt="Swift 6.2+">
    <img src="https://img.shields.io/badge/Platforms-macOS%2012%2B%20%7C%20Linux-lightgray.svg?style=flat" alt="Platforms macOS 12+ | Linux">
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache-lightgrey.svg?style=flat" alt="License Apache"></a>
</p>

An Apple Push Notification service (APNs) provider client for Swift servers. It sends
notifications over the APNs HTTP/2 provider API with token-based (`.p8` key, ES256 JWT)
authentication, using Foundation's `URLSession`. The only dependency is
[apple/swift-crypto](https://github.com/apple/swift-crypto), for the JWT signature.

6.0.0 is a Swift 6 rewrite with a new async API. The 5.x code (`NotificationPusher`, on
Perfect-Net) is on the [`legacy`](../../tree/legacy) branch; see [Migrating from 5.x](#migrating-from-5x).

## Installation

```swift
.package(url: "https://github.com/PerfectlySoft/Perfect-Notifications.git", from: "6.0.0"),
```

and add `.product(name: "PerfectNotifications", package: "Perfect-Notifications")` to your target.

## Requirements

- Swift 6.2 or later (`swift-tools-version: 6.2`, Swift 6 language mode).
- macOS 12 or later, or Linux. CI covers Swift 6.2 and 6.4 on Ubuntu 24.04 and Xcode 26.0.1
  and 26.6 on macOS, debug and release, with warnings as errors.
- On Linux, `URLSession` comes from `FoundationNetworking`, which uses the system libcurl.
  APNs needs HTTP/2, so libcurl must be built with nghttp2. Ubuntu's `libcurl4` is, and the
  official `swift:*-noble` images have it.
- swift-crypto `4.0.0..<5.0.0`.

iOS, tvOS and watchOS aren't supported targets: a provider runs on a server, and must not ship
its signing key inside an app.

## Quick start

```swift
import PerfectNotifications

let client = try APNSClient(
    keyID: "ABCDE12345",                       // from the .p8 file name
    teamID: "TEAM123456",                      // Apple Developer → Membership
    privateKeyPath: "/etc/myapp/AuthKey_ABCDE12345.p8",
    environment: .sandbox                      // .production for App Store / TestFlight builds
)

let notification = try APNSNotification(items: [
    .alertTitle("Order ready"),
    .alertBody("Your order is ready for pickup."),
    .sound("default"),
    .badge(1),
    .customPayload("orderID", "ORD-123"),
])

let response = try await client.send(notification,
                                     to: deviceToken,          // hex string from the device
                                     topic: "com.example.App") // your bundle ID
if response.isSuccess {
    print("sent, apns-id \(response.apnsID ?? "?")")
} else if let error = response.error {
    switch error.knownReason {
    case .unregistered?, .badDeviceToken?:
        // Stop sending to this token.
        print("drop token (invalid since \(error.invalidatedAt.map { "\($0)" } ?? "?"))")
    default:
        print("rejected: \(error.reason)")
    }
}
```

Create one client per signing key and keep it: `URLSession` keeps the HTTP/2 connection to APNs
open and multiplexes concurrent sends over it, as Apple asks. `APNSClient` is a `Sendable`
struct, so it can be shared across tasks; copies share the cached provider token.

`APNSClient(keyID:teamID:pemString:)` takes the key's PEM text instead of a path, for keys
loaded from a secrets store.

### Getting the key

In the Apple Developer portal, under Certificates, IDs & Profiles → Keys, create a key with
**Apple Push Notifications service (APNs)** enabled and download the `.p8` file (it can only be
downloaded once). The 10-character key ID is shown with the key, and the 10-character team ID is
under Membership. One key works for every app in the team, in both environments.

## Sending

```swift
func send(_ notification: APNSNotification, to deviceToken: String, topic: String,
          pushType: APNSPushType = .alert, priority: APNSPriority? = nil,
          expiration: APNSExpiration? = nil, collapseID: String? = nil) async throws -> APNSResponse
```

- **Push type** (`apns-push-type`): `.alert`, `.background`, `.voip`, `.complication`,
  `.fileProvider`, `.mdm`, `.location`, `.liveActivity`, `.pushToTalk`. Several need a topic
  suffix: `com.example.App.voip`, `.complication`, `.pushkit.fileprovider`,
  `.push-type.liveactivity`, `.location-query`, `.voip-ptt`.
- **Priority** (`apns-priority`): `.immediate` (10, the default), `.background` (5: delivery
  that respects the device's power state) and `.low` (1: never wakes the device). Background
  pushes must use `.background`, which is their default.
- **Expiration** (`apns-expiration`): `.immediate` (deliver once or drop), `.relative(seconds)`
  or `.absolute(epochSeconds)`.
- **Collapse ID** (`apns-collapse-id`): up to 64 bytes; newer notifications with the same ID
  replace older ones on the device.
- `sendAlert(to:topic:title:body:...)` and `sendBackground(to:topic:customData:)` cover the
  common cases.

### Payloads

`APNSNotificationItem` builds the `aps` dictionary (`.alertTitle`, `.alertBody`,
`.alertSubtitle`, the `-loc` keys, `.badge`, `.sound`, `.contentAvailable`, `.mutableContent`,
`.category`, `.threadId`, `.targetContentId`, `.interruptionLevel`, `.relevanceScore`) and
custom top-level keys with `.customPayload(key, value)`.

Custom values are `APNSJSONValue`, a `Sendable` JSON enum. Literals convert directly:

```swift
.customPayload("orderID", "ORD-123")
.customPayload("amount", 49)
.customPayload("flags", ["new": true, "ids": [1, 2, 3]])
.customPayload("orderID", .string(order.id))           // a variable: name the case
.customPayload("legacy", try APNSJSONValue(jsonObject: someAnyDictionary))
```

`APNSNotification(raw:)` sends JSON bytes as is, and `APNSNotification(encodable:)` encodes
your own `Encodable` payload (it must contain `aps`). The payload limit is checked before sending:
4096 bytes, or 5120 for VoIP.

### Several devices

```swift
let results = try await client.send(notification, to: tokens, topic: "com.example.App")
for r in results {
    switch r.result {
    case .success(let response) where response.isSuccess: break
    case .success(let response): print(r.deviceToken, "rejected:", response.error?.reason ?? "\(response.statusCode)")
    case .failure(let error):    print(r.deviceToken, "not sent:", error)
    }
}
```

Tokens are sent one after another. Each gets its own result: a bad token or a network error
for one token doesn't stop the rest. Problems shared by every token (topic, priority, payload
size) throw before anything is sent. For concurrency, call `send(_:to:topic:)` from a task group;
the requests share one HTTP/2 connection.

### Responses and errors

An APNs rejection is not a Swift error: it's an `APNSResponse` with `statusCode` and
`error.reason` (`"BadDeviceToken"`, `"Unregistered"`, …; `error.knownReason` maps it onto
`APNSErrorReason`). For HTTP 410, `error.timestamp` is when APNs last confirmed the token was
invalid, in **milliseconds** since the epoch, and `error.invalidatedAt` is the same as a `Date`.
`apnsID` and, in the sandbox, `apnsUniqueID` come from the response headers.

`APNSClientError` is thrown for everything the client catches itself: invalid input (device
token, topic, collapse ID, priority, expiration, key or team ID, payload size), `.timedOut`,
`.responseTooLarge`, `.network(...)`. Cancelling the calling task throws `CancellationError`
promptly.

### Provider tokens

The client signs a JWT with your key and reuses it for 50 minutes (Apple accepts one for up to
60). Apple refuses token updates more often than once every 20 minutes
(`TooManyProviderTokenUpdates`), so the client never mints a new token sooner than that.
After an `ExpiredProviderToken` rejection, it mints a new token and retries once if the old one is
at least 20 minutes old. After `InvalidProviderToken` it doesn't retry (a new token from the same
key won't help) but stops reusing the rejected token once 20 minutes have passed. Each
`APNSClient` created from a key has its own token, so share one client rather than creating many
for the same key.

### Timeouts

`APNSClient(..., timeout: 30)` sets a whole-request deadline in seconds (default 30), covering
connect, send and response. Past it, `send` throws `APNSClientError.timedOut`.

## Security notes

- **Inputs are validated before a request is built.** Device tokens must be 64–200 hex digits of
  even length, so a token can't add path segments, a query or a fragment (`../`, `?`, `#`).
  Topics must be bundle-ID syntax; collapse IDs are limited to 64 bytes with no control
  characters; key and team IDs must be 10 ASCII letters or digits. No header value can contain
  CR, LF or another control character. The JWT is built with `JSONEncoder`.
- **Secrets stay out of logs.** `"\(client)"`, `String(reflecting:)`, `dump(client)` and `Mirror`
  show the environment, key ID, team ID and timeout, but never the private key or the provider
  token. `APNSClientError.network` carries the transport error's description, which never
  includes request headers.
- **Response bodies are capped at 16 KiB** (APNs sends a few dozen bytes). On macOS the body is
  streamed and the request is cancelled as soon as it passes the cap. On Linux, see below.
- **Keep the `.p8` key out of source control**, and readable only by the server's user.
- `Environment.custom(host:port:)` points the client at a mock APNs server for staging or tests.
  The provider token is sent there, so only use a host you control.

## Linux

Verified on swift:6.2-noble and swift:6.4-noble, arm64 and x86_64: `URLSession` negotiates HTTP/2
with ALPN `h2` against an HTTP/2-only server, reuses one connection, and multiplexes 20
concurrent sends over it. Two corelibs Foundation limitations shape the Linux behaviour:

- **No streaming body read.** corelibs `URLSession` buffers a response body completely, and
  keeps reading after the task is cancelled. The 16 KiB cap is checked once the body is in,
  and the deadline returns control on time, but a malicious endpoint that streams an endless
  body can grow the process's memory until the transfer ends. Reaching that needs a server
  that passes TLS verification for `api.push.apple.com` (or your custom host). In a local test,
  memory reached 6 GB within the 5-second deadline and was released afterwards.
- **Cancelling a corelibs data task can block.** About 1 run in 20 against a server that never
  answered, cancelling the task blocked the cancelling thread indefinitely. The client resumes
  the caller first, then cancels on a Dispatch thread, so `send` still returns at the deadline.

If those matter for your deployment, run the provider on macOS, or put an HTTP/2 proxy you trust
in front of it.

## Testing

The test suite is hermetic: requests go to a `URLProtocol` stub that records them (path,
headers, body, JWT signature checked with swift-crypto) and returns scripted responses. Nothing
contacts APNs. To test your own code, pass a `URLSession` whose configuration's `protocolClasses`
includes such a stub, or point `Environment.custom(host:port:)` at a local mock server.

## Migrating from 5.x

5.x registered named configurations on `NotificationPusher` and delivered results to callbacks.
6.0 has one `APNSClient` per key and `async` sends.

| 5.x | 6.0 |
|---|---|
| `NotificationPusher.addConfigurationAPNS(name:production:keyId:teamId:privateKeyPath:)` | `let client = try APNSClient(keyID:teamID:privateKeyPath:environment:)` with `.sandbox` or `.production` |
| `NotificationPusher(apnsTopic:expiration:priority:collapseId:)` | `topic:`, `expiration:`, `priority:`, `collapseID:` parameters of `send` |
| `pushAPNS(configurationName:deviceToken:notificationItems:callback:)` | `try await client.send(APNSNotification(items: ...), to: token, topic: ...)` |
| `pushAPNS(configurationName:deviceTokens:notificationItems:callback:)` | `try await client.send(..., to: tokens, topic: ...)` → `[APNSBatchResult]` |
| `NotificationResponse` (`status`, `body`) | `APNSResponse` (`statusCode`, `apnsID`, `apnsUniqueID`, `error`) |
| `.customPayload(String, Any)` | `.customPayload(String, APNSJSONValue)`: literals work as before; wrap variables (`.string(x)`) or use `APNSJSONValue(jsonObject:)` |
| Perfect-Net / Perfect-Thread | `URLSession` and swift-crypto |

`APNSNotificationItem`'s other cases keep their names. New: `.alertSubtitle`, `.mutableContent`,
`.targetContentId`, `.interruptionLevel`, `.relevanceScore`.

### From the pre-release `main` (Swift 6 rewrite before 6.0.0)

- `priority:` is an `APNSPriority?` (`.immediate`, `.background`, `.low`) instead of an `Int?`,
  and `APNSPushType.defaultPriority` returns an `APNSPriority`. A background push with any other
  priority throws `.invalidPriority`.
- `.customPayload` takes an `APNSJSONValue`, and `APNSNotificationItem` is properly `Sendable`
  (and `Equatable`). A custom `aps` key throws `.reservedPayloadKey`.
- The multi-token `send` returns `[APNSBatchResult]` (token plus `Result`) instead of
  `[APNSResponse]`, and no longer throws away every result when one token fails.
- `APNSResponseError.timestamp` is an `Int64?` of milliseconds (it was documented as seconds).
- Key IDs and team IDs must be 10 letters or digits; device tokens, topics, collapse IDs and
  expirations are validated; payloads over the limit throw `.payloadTooLarge`.
- `APNSClientError` has new cases (exhaustive `switch`es need updating), and the `init`s take a
  `timeout:`. `APNSExpiration` is `Equatable`, `APNSNotification.payload` is public.
- swift-crypto is `4.0.0..<5.0.0` (was `from: "3.0.0"`, which meant 3.x only and couldn't
  resolve next to Perfect-SMTP 6).
