import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The client's HTTP transport: a `URLSession` driven through delegate callbacks.
///
/// It is built from the caller's session's configuration (so protocol classes, proxies and
/// TLS settings carry over), with its own delegate, because:
///
/// - **Redirects must not be followed.** APNs never redirects, and following one would
///   send the provider token to another origin. corelibs Foundation ignores per-task
///   delegates, so only a session delegate can refuse a redirect on Linux.
/// - **Cancellation must not go through Swift task cancellation.** On Linux, cancelling a
///   `Task` that awaits `URLSession.data(for:)` calls `URLSessionTask.cancel()` from the
///   cancellation handler, with the task's status lock held, and `cancel()` waits for the
///   session's work queue. If that queue is at that moment resuming the same task's
///   continuation (which needs the status lock), both block, and every concurrency thread
///   that touches the session follows. Here the deadline and caller cancellation resume
///   our own continuation and then cancel the `URLSessionTask` on a Dispatch thread, with
///   no lock held.
/// - **The body cap is enforced as data arrives**, on both platforms.
///
/// Authentication challenges are forwarded to the caller's session delegate, so a custom
/// trust evaluation (certificate pinning, a private CA in tests) keeps working.
final class APNSTransport: Sendable {
    private let session: URLSession
    private let delegate: SessionDelegate

    init(basedOn given: URLSession, maxBodySize: Int) {
        delegate = SessionDelegate(forwardingTo: given, maxBodySize: maxBodySize)
        session = URLSession(configuration: given.configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        // The session retains its delegate until it is invalidated.
        session.finishTasksAndInvalidate()
    }

    /// Sends `request`, returning the body (at most `maxBodySize` bytes) and the response.
    ///
    /// Returns, throws ``APNSClientError/timedOut`` at the deadline, or throws
    /// `CancellationError` when the calling task is cancelled, without waiting for
    /// `URLSession` to wind the transfer down.
    func send(_ request: URLRequest, deadline seconds: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        let flight = InFlight(limit: delegate.maxBodySize)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>) in
                guard flight.attach(continuation) else { return }   // cancelled before we started
                let task = session.dataTask(with: request)
                delegate.register(flight, for: task)
                let timer = DispatchWorkItem { flight.finish(.failure(APNSClientError.timedOut)) }
                guard flight.start(task: task, timer: timer) else { delegate.unregister(task); return }
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
                task.resume()
            }
        } onCancel: {
            // Never resume or cancel from inside the cancellation handler: it runs with
            // the task's status lock held.
            DispatchQueue.global().async { flight.finish(.failure(CancellationError())) }
        }
    }
}

// MARK: - One request

private final class InFlight: @unchecked Sendable {
    let limit: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>?
    private var pending: Result<(Data, HTTPURLResponse), any Error>?
    private var task: URLSessionTask?
    private var timer: DispatchWorkItem?
    private var done = false
    private var data = Data()
    private var response: HTTPURLResponse?

    init(limit: Int) { self.limit = limit }

    /// Returns `false` if the request already finished (it was cancelled first); the
    /// continuation has then been resumed.
    func attach(_ c: CheckedContinuation<(Data, HTTPURLResponse), any Error>) -> Bool {
        let early: Result<(Data, HTTPURLResponse), any Error>? = lock.withLock {
            if let pending { return pending }
            continuation = c
            return nil
        }
        if let early { c.resume(with: early); return false }
        return true
    }

    /// Returns `false` if the request finished in the meantime.
    func start(task: URLSessionTask, timer: DispatchWorkItem) -> Bool {
        lock.withLock {
            guard !done else { return false }
            self.task = task
            self.timer = timer
            return true
        }
    }

    func received(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else {
            finish(.failure(APNSClientError.invalidResponse))
            return false
        }
        if http.expectedContentLength > Int64(limit) {
            finish(.failure(APNSClientError.responseTooLarge(limit: limit)))
            return false
        }
        lock.withLock { self.response = http }
        return true
    }

    func received(_ chunk: Data) {
        let over: Bool = lock.withLock {
            guard !done else { return false }     // ignore anything after the end
            data.append(chunk)
            return data.count > limit
        }
        if over { finish(.failure(APNSClientError.responseTooLarge(limit: limit))) }
    }

    func completed(error: (any Error)?) {
        if let error {
            if let urlError = error as? URLError {
                if urlError.code == .timedOut { finish(.failure(APNSClientError.timedOut)); return }
                if urlError.code == .cancelled { finish(.failure(APNSClientError.network("cancelled"))); return }
                finish(.failure(APNSClientError.network("URLError \(urlError.code.rawValue): \(urlError.localizedDescription)")))
            } else {
                finish(.failure(APNSClientError.network(error.localizedDescription)))
            }
            return
        }
        let result: Result<(Data, HTTPURLResponse), any Error> = lock.withLock {
            guard let response else { return .failure(APNSClientError.invalidResponse) }
            return .success((data, response))
        }
        finish(result)
    }

    /// Resolves the request once: resumes the caller, then cancels the transfer (off the
    /// caller's thread) if it is still running.
    func finish(_ result: Result<(Data, HTTPURLResponse), any Error>) {
        let (c, task, timer): (CheckedContinuation<(Data, HTTPURLResponse), any Error>?, URLSessionTask?, DispatchWorkItem?) = lock.withLock {
            guard !done else { return (nil, nil, nil) }
            done = true
            data = Data()
            guard let c = continuation else {
                pending = result      // not attached yet
                return (nil, nil, nil)
            }
            continuation = nil
            defer { self.task = nil; self.timer = nil }
            return (c, self.task, self.timer)
        }
        c?.resume(with: result)
        timer?.cancel()
        if let task, case .failure = result {
            DispatchQueue.global().async { task.cancel() }
        }
    }
}

// MARK: - Session delegate

private final class SessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let maxBodySize: Int
    /// The caller's session, passed to its delegate when forwarding challenges.
    private let callerSession: URLSession
    private let lock = NSLock()
    private var flights: [Int: InFlight] = [:]

    init(forwardingTo callerSession: URLSession, maxBodySize: Int) {
        self.callerSession = callerSession
        self.maxBodySize = maxBodySize
    }

    func register(_ flight: InFlight, for task: URLSessionTask) {
        lock.withLock { flights[task.taskIdentifier] = flight }
    }

    func unregister(_ task: URLSessionTask) {
        _ = lock.withLock { flights.removeValue(forKey: task.taskIdentifier) }
    }

    private func flight(_ task: URLSessionTask) -> InFlight? {
        lock.withLock { flights[task.taskIdentifier] }
    }

    // MARK: Data

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let keep = flight(dataTask)?.received(response) ?? false
        completionHandler(keep ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        flight(dataTask)?.received(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let f = lock.withLock { flights.removeValue(forKey: task.taskIdentifier) }
        f?.completed(error: error)
    }

    // MARK: Redirects: never followed

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    // MARK: Challenges: forwarded to the caller's delegate

    #if canImport(FoundationNetworking)
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let forward = callerSession.delegate as? URLSessionTaskDelegate {
            forward.urlSession(callerSession, task: task, didReceive: challenge, completionHandler: completionHandler)
        } else if let forward = callerSession.delegate {
            forward.urlSession(callerSession, didReceive: challenge, completionHandler: completionHandler)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
    #else
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let forward = callerSession.delegate
        if (forward as? URLSessionTaskDelegate)?.urlSession?(callerSession, task: task, didReceive: challenge,
                                                             completionHandler: completionHandler) != nil {
            return
        }
        if forward?.urlSession?(callerSession, didReceive: challenge, completionHandler: completionHandler) != nil {
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
    #endif
}
