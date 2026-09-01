import Foundation

/// Error thrown when a request cannot reach the APNs gateway (not a gateway rejection).
public enum APNSClientError: Error, Sendable {
    case network(String)
    case invalidResponse
}

/// A Swift 6 client for the APNs HTTP/2 provider API (token-based auth).
///
/// ```swift
/// let client = try APNSClient(
///     keyID:          "ABCDE12345",
///     teamID:         "TEAM123456",
///     privateKeyPath: "/path/to/AuthKey_ABCDE12345.p8",
///     environment:    .sandbox
/// )
///
/// let notification = try APNSNotification(items: [
///     .alertTitle("Order Ready"),
///     .alertBody("Your order is ready for pickup."),
///     .badge(1)
/// ])
///
/// let response = try await client.send(notification,
///                                      to: deviceToken,
///                                      topic: "com.example.ScrubsApp")
/// if response.isSuccess {
///     print("sent — apns-id: \(response.apnsID ?? "?")")
/// } else if let err = response.error {
///     print("rejected: \(err.reason)")
/// }
/// ```
public struct APNSClient: Sendable {

    // MARK: Environment

    public enum Environment: Sendable {
        case sandbox
        case production

        var host: String {
            switch self {
            case .sandbox:    return "api.sandbox.push.apple.com"
            case .production: return "api.push.apple.com"
            }
        }
    }

    // MARK: Properties

    private let credentials: APNSCredentials
    private let environment: Environment
    private let urlSession: URLSession

    // MARK: Init

    /// Load the signing key from a `.p8` file on disk.
    ///
    /// - Parameters:
    ///   - keyID: The 10-character key ID from the `.p8` filename (e.g. `ABCDE12345`).
    ///   - teamID: Your Apple Developer Team ID.
    ///   - privateKeyPath: Path to the `.p8` private key file.
    ///   - environment: `.sandbox` (default) or `.production`.
    ///   - urlSession: Custom session for testing or certificate pinning.
    public init(keyID: String, teamID: String, privateKeyPath: String,
                environment: Environment = .sandbox,
                urlSession: URLSession = .shared) throws {
        self.credentials = try APNSCredentials(keyID: keyID, teamID: teamID, privateKeyPath: privateKeyPath)
        self.environment = environment
        self.urlSession  = urlSession
    }

    /// Supply the `.p8` key as a PEM string (useful when loading from env vars or config).
    public init(keyID: String, teamID: String, pemString: String,
                environment: Environment = .sandbox,
                urlSession: URLSession = .shared) throws {
        self.credentials = try APNSCredentials(keyID: keyID, teamID: teamID, pemString: pemString)
        self.environment = environment
        self.urlSession  = urlSession
    }

    // MARK: - Send

    /// Send a notification to a single device token.
    ///
    /// - Parameters:
    ///   - notification: The payload to send.
    ///   - deviceToken: The hex device token string registered by the app.
    ///   - topic: Bundle ID of the app (`com.example.App`), or `com.example.App.voip` for VoIP.
    ///   - pushType: Defaults to `.alert`. Must be `.background` for silent pushes.
    ///   - priority: `apns-priority`. Defaults to ``APNSPushType/defaultPriority``.
    ///   - expiration: When to discard an undeliverable notification.
    ///   - collapseID: Coalesces pending undelivered notifications with the same ID.
    public func send(
        _ notification: APNSNotification,
        to deviceToken: String,
        topic: String,
        pushType: APNSPushType = .alert,
        priority: Int? = nil,
        expiration: APNSExpiration? = nil,
        collapseID: String? = nil
    ) async throws -> APNSResponse {
        let url = URL(string: "https://\(environment.host)/3/device/\(deviceToken)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody   = notification.payload
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(topic,                 forHTTPHeaderField: "apns-topic")
        request.setValue(pushType.rawValue,     forHTTPHeaderField: "apns-push-type")
        request.setValue("\(priority ?? pushType.defaultPriority)", forHTTPHeaderField: "apns-priority")

        let jwt = try credentials.token()
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")

        if let exp = expiration {
            request.setValue("\(exp.headerValue)", forHTTPHeaderField: "apns-expiration")
        }
        if let cid = collapseID {
            request.setValue(cid, forHTTPHeaderField: "apns-collapse-id")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw APNSClientError.network("\(error)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw APNSClientError.invalidResponse
        }

        let apnsID = http.value(forHTTPHeaderField: "apns-id")

        guard http.statusCode != 200 else {
            return APNSResponse(statusCode: 200, apnsID: apnsID, error: nil)
        }

        if !data.isEmpty, let body = try? JSONDecoder().decode(APNSErrorBody.self, from: data) {
            let err = APNSResponseError(reason: body.reason, timestamp: body.timestamp)
            return APNSResponse(statusCode: http.statusCode, apnsID: apnsID, error: err)
        }
        return APNSResponse(statusCode: http.statusCode, apnsID: apnsID, error: nil)
    }

    /// Send the same notification to multiple device tokens (sequential).
    /// Returns one ``APNSResponse`` per token, in the same order.
    public func send(
        _ notification: APNSNotification,
        to deviceTokens: [String],
        topic: String,
        pushType: APNSPushType = .alert,
        priority: Int? = nil,
        expiration: APNSExpiration? = nil,
        collapseID: String? = nil
    ) async throws -> [APNSResponse] {
        var responses = [APNSResponse]()
        responses.reserveCapacity(deviceTokens.count)
        for token in deviceTokens {
            let r = try await send(notification, to: token, topic: topic,
                                   pushType: pushType, priority: priority,
                                   expiration: expiration, collapseID: collapseID)
            responses.append(r)
        }
        return responses
    }

    // MARK: - Convenience helpers

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
    ) async throws -> APNSResponse {
        var items: [APNSNotificationItem] = [.alertTitle(title)]
        if let body              { items.append(.alertBody(body)) }
        if let subtitle          { items.append(.alertSubtitle(subtitle)) }
        if let badge             { items.append(.badge(badge)) }
        if let sound             { items.append(.sound(sound)) }
        if let category          { items.append(.category(category)) }
        if let threadId          { items.append(.threadId(threadId)) }
        if let interruptionLevel { items.append(.interruptionLevel(interruptionLevel)) }
        if mutableContent        { items.append(.mutableContent) }
        let notification = try APNSNotification(items: items)
        return try await send(notification, to: deviceToken, topic: topic,
                              pushType: .alert, collapseID: collapseID)
    }

    /// Send a silent background push (`content-available: 1`, priority 5).
    @discardableResult
    public func sendBackground(
        to deviceToken: String,
        topic: String,
        customData: [APNSNotificationItem] = []
    ) async throws -> APNSResponse {
        var items = customData
        items.append(.contentAvailable)
        let notification = try APNSNotification(items: items)
        return try await send(notification, to: deviceToken, topic: topic,
                              pushType: .background, priority: 5)
    }
}
