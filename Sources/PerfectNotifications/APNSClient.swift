import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An error raised by the client itself, before or instead of an APNs response.
/// APNs rejections are not errors: they come back as an ``APNSResponse`` with
/// ``APNSResponse/error`` set.
public enum APNSClientError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The device token is not 64–200 hex digits of even length.
    case invalidDeviceToken
    /// The topic is not a bundle ID (dot-separated ASCII letters, digits and `-`).
    case invalidTopic
    /// The collapse ID is empty, longer than 64 bytes, or contains a control character.
    case invalidCollapseID
    /// The priority isn't allowed for the push type (background pushes must use `.background`).
    case invalidPriority(APNSPriority, pushType: APNSPushType)
    /// A negative expiration, or a relative one that overflows.
    case invalidExpiration
    /// The key ID is not 10 ASCII letters or digits.
    case invalidKeyID
    /// The team ID is not 10 ASCII letters or digits.
    case invalidTeamID
    /// A ``APNSClient/Environment/custom(host:port:)`` host or port is malformed.
    case invalidHost
    /// The request timeout is not a positive, finite number of seconds.
    case invalidTimeout
    /// The payload exceeds the APNs limit for the push type (4096 bytes, 5120 for VoIP).
    case payloadTooLarge(size: Int, limit: Int)
    /// A custom payload used the reserved `aps` key.
    case reservedPayloadKey(String)
    /// ``APNSJSONValue/init(jsonObject:)`` met a value it can't represent.
    case invalidJSONValue(String)
    /// Signing the provider token failed.
    case tokenSigningFailed
    /// The request did not complete within the client's timeout.
    case timedOut
    /// The response body exceeded the client's limit (16 KiB; APNs bodies are under 1 KiB).
    case responseTooLarge(limit: Int)
    /// The request failed below HTTP (DNS, TCP, TLS). The string is the underlying error's
    /// description; it never contains the provider token.
    case network(String)
    /// The response was not HTTP.
    case invalidResponse

    public var description: String {
        switch self {
        case .invalidDeviceToken: return "invalid device token (expected 64-200 hex digits)"
        case .invalidTopic: return "invalid apns-topic"
        case .invalidCollapseID: return "invalid apns-collapse-id (1-64 bytes, no control characters)"
        case .invalidPriority(let p, let t): return "priority \(p.rawValue) is not allowed for push type \(t.rawValue)"
        case .invalidExpiration: return "invalid apns-expiration"
        case .invalidKeyID: return "invalid key ID (expected 10 letters or digits)"
        case .invalidTeamID: return "invalid team ID (expected 10 letters or digits)"
        case .invalidHost: return "invalid custom host or port"
        case .invalidTimeout: return "invalid timeout"
        case .payloadTooLarge(let size, let limit): return "payload is \(size) bytes; the limit is \(limit)"
        case .reservedPayloadKey(let k): return "custom payload key \"\(k)\" is reserved"
        case .invalidJSONValue(let t): return "not a JSON value: \(t)"
        case .tokenSigningFailed: return "signing the provider token failed"
        case .timedOut: return "request timed out"
        case .responseTooLarge(let limit): return "response body exceeded \(limit) bytes"
        case .network(let s): return "network error: \(s)"
        case .invalidResponse: return "response was not HTTP"
        }
    }
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
///
/// The client is a value type that shares one credentials object, so copies share the
/// cached provider token. Create one client per signing key and reuse it: `URLSession`
/// keeps the HTTP/2 connection open and multiplexes requests over it, as Apple asks.
public struct APNSClient: Sendable {

    // MARK: Environment

    public enum Environment: Sendable, Equatable {
        case sandbox
        case production
        /// A local or staging APNs mock (`https://host:port`). The provider token is sent
        /// to this host, so only point it at a server you control.
        case custom(host: String, port: Int)

        var authority: String {
            switch self {
            case .sandbox:    return "api.sandbox.push.apple.com"
            case .production: return "api.push.apple.com"
            case .custom(let host, let port): return port == 443 ? host : "\(host):\(port)"
            }
        }
    }

    /// The default whole-request timeout, in seconds.
    public static let defaultTimeout: TimeInterval = 30
    /// The largest response body the client reads. APNs error bodies are a few dozen bytes.
    static let maxResponseBodySize = 16 * 1024

    // MARK: Properties

    private let credentials: APNSCredentials
    public let environment: Environment
    /// The whole-request deadline, in seconds, covering connect, send and response.
    public let timeout: TimeInterval
    private let urlSession: URLSession

    // MARK: Init

    /// Load the signing key from a `.p8` file on disk.
    ///
    /// - Parameters:
    ///   - keyID: The 10-character key ID from the `.p8` filename (e.g. `ABCDE12345`).
    ///   - teamID: Your 10-character Apple Developer Team ID.
    ///   - privateKeyPath: Path to the `.p8` private key file.
    ///   - environment: `.sandbox` (default) or `.production`.
    ///   - urlSession: Custom session for testing or certificate pinning.
    ///   - timeout: Whole-request deadline in seconds (default 30).
    /// - Throws: ``APNSClientError/invalidKeyID``, ``APNSClientError/invalidTeamID``,
    ///   ``APNSClientError/invalidHost``, ``APNSClientError/invalidTimeout``, a file error,
    ///   or a swift-crypto error for a key that isn't a P-256 PEM.
    public init(keyID: String, teamID: String, privateKeyPath: String,
                environment: Environment = .sandbox,
                urlSession: URLSession = .shared,
                timeout: TimeInterval = APNSClient.defaultTimeout) throws {
        try Self.validate(environment: environment, timeout: timeout)
        self.credentials = try APNSCredentials(keyID: keyID, teamID: teamID, privateKeyPath: privateKeyPath)
        self.environment = environment
        self.urlSession  = urlSession
        self.timeout     = timeout
    }

    /// Supply the `.p8` key as a PEM string (useful when loading from env vars or config).
    public init(keyID: String, teamID: String, pemString: String,
                environment: Environment = .sandbox,
                urlSession: URLSession = .shared,
                timeout: TimeInterval = APNSClient.defaultTimeout) throws {
        try Self.validate(environment: environment, timeout: timeout)
        self.credentials = try APNSCredentials(keyID: keyID, teamID: teamID, pemString: pemString)
        self.environment = environment
        self.urlSession  = urlSession
        self.timeout     = timeout
    }

    init(credentials: APNSCredentials, environment: Environment, urlSession: URLSession,
         timeout: TimeInterval = APNSClient.defaultTimeout) throws {
        try Self.validate(environment: environment, timeout: timeout)
        self.credentials = credentials
        self.environment = environment
        self.urlSession  = urlSession
        self.timeout     = timeout
    }

    private static func validate(environment: Environment, timeout: TimeInterval) throws(APNSClientError) {
        if case .custom(let host, let port) = environment { try APNSValidation.host(host, port: port) }
        guard timeout.isFinite, timeout > 0 else { throw .invalidTimeout }
    }

    // MARK: - Send

    /// Send a notification to a single device token.
    ///
    /// An `ExpiredProviderToken` rejection is retried once with a fresh token, unless the
    /// current token is less than 20 minutes old (Apple's limit on token updates).
    ///
    /// - Parameters:
    ///   - notification: The payload to send.
    ///   - deviceToken: The hex device token registered by the app.
    ///   - topic: Bundle ID of the app (`com.example.App`), or `com.example.App.voip` for VoIP.
    ///   - pushType: Defaults to `.alert`. Must be `.background` for silent pushes.
    ///   - priority: `apns-priority`. Defaults to ``APNSPushType/defaultPriority``.
    ///   - expiration: When to discard an undeliverable notification.
    ///   - collapseID: Coalesces pending undelivered notifications with the same ID (≤ 64 bytes).
    /// - Returns: The APNs response; a rejection is a response with ``APNSResponse/error`` set.
    /// - Throws: ``APNSClientError`` for invalid input, network failures and timeouts;
    ///   `CancellationError` if the task is cancelled.
    public func send(
        _ notification: APNSNotification,
        to deviceToken: String,
        topic: String,
        pushType: APNSPushType = .alert,
        priority: APNSPriority? = nil,
        expiration: APNSExpiration? = nil,
        collapseID: String? = nil
    ) async throws -> APNSResponse {
        let prepared = try prepare(notification, topic: topic, pushType: pushType,
                                   priority: priority, expiration: expiration, collapseID: collapseID)
        return try await deliver(prepared, to: deviceToken)
    }

    /// Send the same notification to several device tokens, one after another.
    ///
    /// Returns one ``APNSBatchResult`` per token, in order. A token that fails (invalid
    /// token, network error, timeout) gets a `.failure` and the rest are still sent.
    /// Problems shared by every token (topic, priority, payload size, …) throw before
    /// anything is sent, and cancellation throws `CancellationError`.
    public func send(
        _ notification: APNSNotification,
        to deviceTokens: [String],
        topic: String,
        pushType: APNSPushType = .alert,
        priority: APNSPriority? = nil,
        expiration: APNSExpiration? = nil,
        collapseID: String? = nil
    ) async throws -> [APNSBatchResult] {
        let prepared = try prepare(notification, topic: topic, pushType: pushType,
                                   priority: priority, expiration: expiration, collapseID: collapseID)
        var results = [APNSBatchResult]()
        results.reserveCapacity(deviceTokens.count)
        for token in deviceTokens {
            try Task.checkCancellation()
            let result: Result<APNSResponse, APNSClientError>
            do {
                result = .success(try await deliver(prepared, to: token))
            } catch let error as APNSClientError {
                result = .failure(error)
            }
            results.append(APNSBatchResult(deviceToken: token, result: result))
        }
        return results
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
                              pushType: .background, priority: .background)
    }

    // MARK: - Request pipeline

    struct PreparedRequest: Sendable {
        let body: Data
        let headers: [(String, String)]
    }

    func prepare(_ notification: APNSNotification, topic: String, pushType: APNSPushType,
                 priority: APNSPriority?, expiration: APNSExpiration?,
                 collapseID: String?) throws(APNSClientError) -> PreparedRequest {
        try APNSValidation.topic(topic)
        let priority = priority ?? pushType.defaultPriority
        if pushType == .background && priority != .background {
            throw .invalidPriority(priority, pushType: pushType)
        }
        let limit = APNSValidation.payloadLimit(for: pushType)
        guard notification.payload.count <= limit else {
            throw .payloadTooLarge(size: notification.payload.count, limit: limit)
        }
        var headers: [(String, String)] = [
            ("content-type", "application/json"),
            ("apns-topic", topic),
            ("apns-push-type", pushType.rawValue),
            ("apns-priority", String(priority.rawValue)),
        ]
        if let expiration {
            headers.append(("apns-expiration", String(try expiration.headerValue(now: Date()))))
        }
        if let collapseID {
            try APNSValidation.collapseID(collapseID)
            headers.append(("apns-collapse-id", collapseID))
        }
        return PreparedRequest(body: notification.payload, headers: headers)
    }

    /// Validates the token, sends, and handles provider-token rejections.
    /// Throws only ``APNSClientError`` or `CancellationError`.
    func deliver(_ prepared: PreparedRequest, to deviceToken: String) async throws -> APNSResponse {
        try APNSValidation.deviceToken(deviceToken)
        // The token is validated hex, so it can't change the path.
        guard let url = URL(string: "https://\(environment.authority)/3/device/\(deviceToken)") else {
            throw APNSClientError.invalidDeviceToken
        }
        var jwt = try providerToken()
        var response = try await perform(prepared, url: url, jwt: jwt)

        switch response.error?.knownReason {
        case .expiredProviderToken?:
            // Retry once, but only if a new token can be minted without exceeding
            // Apple's one-update-per-20-minutes limit.
            if credentials.reject(jwt) {
                jwt = try providerToken()
                response = try await perform(prepared, url: url, jwt: jwt)
                if response.error?.knownReason == .expiredProviderToken
                    || response.error?.knownReason == .invalidProviderToken {
                    _ = credentials.reject(jwt)
                }
            }
        case .invalidProviderToken?:
            // A new token from the same key is unlikely to help; don't retry, but don't
            // keep reusing a rejected token past the 20-minute floor either.
            _ = credentials.reject(jwt)
        default:
            // TooManyProviderTokenUpdates: keep the current token. The credentials never
            // mint more than once per 20 minutes on their own.
            break
        }
        return response
    }

    private func providerToken() throws(APNSClientError) -> String {
        do { return try credentials.token() } catch { throw .tokenSigningFailed }
    }

    private func perform(_ prepared: PreparedRequest, url: URL, jwt: String) async throws -> APNSResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = prepared.body
        request.timeoutInterval = timeout
        for (name, value) in prepared.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")

        let session = urlSession
        let request_ = request
        let (data, http) = try await withDeadline(seconds: timeout) {
            try await Self.load(request_, session: session)
        }

        let apnsID = http.value(forHTTPHeaderField: "apns-id")
        let uniqueID = http.value(forHTTPHeaderField: "apns-unique-id")
        guard http.statusCode != 200 else {
            return APNSResponse(statusCode: 200, apnsID: apnsID, apnsUniqueID: uniqueID, error: nil)
        }
        var error: APNSResponseError?
        if !data.isEmpty, let body = try? JSONDecoder().decode(APNSErrorBody.self, from: data) {
            error = APNSResponseError(reason: body.reason, timestamp: body.timestamp)
        }
        return APNSResponse(statusCode: http.statusCode, apnsID: apnsID, apnsUniqueID: uniqueID, error: error)
    }

    /// Loads the response, reading at most ``maxResponseBodySize`` bytes of body.
    private static func load(_ request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let limit = maxResponseBodySize
        do {
            #if canImport(FoundationNetworking)
            // corelibs Foundation has no streaming `bytes(for:)`, and keeps reading a body
            // after its task is cancelled, so the size is checked once the body is in.
            // The whole-request deadline still bounds how long that can take.
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APNSClientError.invalidResponse }
            guard data.count <= limit else { throw APNSClientError.responseTooLarge(limit: limit) }
            return (data, http)
            #else
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                bytes.task.cancel()
                throw APNSClientError.invalidResponse
            }
            if http.expectedContentLength > Int64(limit) {
                bytes.task.cancel()
                throw APNSClientError.responseTooLarge(limit: limit)
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit {
                    bytes.task.cancel()
                    throw APNSClientError.responseTooLarge(limit: limit)
                }
            }
            return (data, http)
            #endif
        } catch let error as APNSClientError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .timedOut { throw APNSClientError.timedOut }
            if error.code == .cancelled && Task.isCancelled { throw CancellationError() }
            throw APNSClientError.network("URLError \(error.code.rawValue): \(error.localizedDescription)")
        } catch {
            throw APNSClientError.network(error.localizedDescription)
        }
    }
}

// MARK: - Redaction

extension APNSClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "APNSClient(environment: \(environment), keyID: \(credentials.keyID), teamID: \(credentials.teamID), timeout: \(timeout))"
    }
    public var debugDescription: String { description }
    /// Shows the environment, IDs and timeout only: never the key or the provider token.
    public var customMirror: Mirror {
        Mirror(self, children: [
            "environment": environment,
            "keyID": credentials.keyID,
            "teamID": credentials.teamID,
            "timeout": timeout,
        ], displayStyle: .struct)
    }
}

// MARK: - Deadline

/// Runs `operation` with a deadline. Returns as soon as the operation finishes, the
/// deadline passes (``APNSClientError/timedOut``) or the calling task is cancelled
/// (`CancellationError`), even if the operation ignores cancellation; the operation is
/// cancelled in the latter two cases.
func withDeadline<T: Sendable>(
    seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = DeadlineRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            let work = Task {
                do { race.finish(.success(try await operation())) }
                catch { race.finish(.failure(error)) }
            }
            let nanos = UInt64(min(seconds, 86_400) * 1_000_000_000)
            let timer = Task {
                try? await Task.sleep(nanoseconds: nanos)
                if !Task.isCancelled { race.finish(.failure(APNSClientError.timedOut)) }
            }
            race.start(continuation, tasks: [work, timer])
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

private final class DeadlineRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var tasks: [Task<Void, Never>] = []
    private var pending: Result<T, any Error>?
    private var done = false

    func start(_ continuation: CheckedContinuation<T, any Error>, tasks: [Task<Void, Never>]) {
        let early: Result<T, any Error>? = lock.withLock {
            if let pending = self.pending { self.done = true; return pending }
            self.continuation = continuation
            self.tasks = tasks
            return nil
        }
        if let early {
            continuation.resume(with: early)
            Self.cancel(tasks)
        }
    }

    func finish(_ result: Result<T, any Error>) {
        let (continuation, tasks): (CheckedContinuation<T, any Error>?, [Task<Void, Never>]) = lock.withLock {
            guard !done else { return (nil, []) }
            guard let c = self.continuation else {
                // Not started yet (cancelled before the continuation existed): remember the
                // first result for start().
                if pending == nil { pending = result }
                return (nil, [])
            }
            done = true
            self.continuation = nil
            defer { self.tasks = [] }
            return (c, self.tasks)
        }
        continuation?.resume(with: result)
        Self.cancel(tasks)
    }

    /// Cancels off the cooperative pool, after the caller has been resumed. On Linux,
    /// cancelling a `URLSession` data task from its async API sometimes blocks the
    /// cancelling thread indefinitely (seen in about 1 run in 20 against a server that
    /// never answers); the caller must not wait for that, and it must not pin a
    /// Swift-concurrency thread.
    private static func cancel(_ tasks: [Task<Void, Never>]) {
        guard !tasks.isEmpty else { return }
        DispatchQueue.global().async { tasks.forEach { $0.cancel() } }
    }
}
