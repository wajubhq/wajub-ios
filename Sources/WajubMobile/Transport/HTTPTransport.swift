import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One HTTP request, with the two timeouts of the contract (README §2.4).
struct HTTPRequest: Sendable {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data?
    var connectTimeout: TimeInterval
    var timeout: TimeInterval
}

/// One HTTP answer. Header names are matched case-insensitively.
struct HTTPResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data

    init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
    }
}

/// A request that got no HTTP answer.
enum TransportError: Error, Equatable, Sendable {
    case network(String)
    case timeout
    case cancelled
}

/// Sends HTTP requests. The SDK uses `URLSessionTransport`; tests use a fake.
protocol HTTPTransport: Sendable {
    /// Whether `send` calls `connected` for this request. The connect timeout applies only then:
    /// a transport that cannot tell is given the whole-call timeout alone.
    func reportsConnection(for request: HTTPRequest) -> Bool

    /// Sends `request`. Calls `connected` once the connection to the server is up, when
    /// `reportsConnection(for:)` says so; the caller enforces `request.connectTimeout` and `request.timeout`.
    func send(_ request: HTTPRequest, connected: @escaping @Sendable () -> Void) async throws -> HTTPResponse
}

/// An HTTP answer with its body read as JSON (when it is JSON).
struct APIAnswer: Sendable {
    var status: Int
    var headers: [String: String]
    var body: JSONValue?

    init(status: Int, headers: [String: String] = [:], body: JSONValue?) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
    }

    init(_ response: HTTPResponse) {
        status = response.status
        headers = response.headers
        body = response.body.isEmpty ? nil : try? JSONValue.parse(response.body)
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    var isSuccess: Bool { (200...299).contains(status) }
}

/// `URLSession`.
///
/// `URLSession` reports no connection event: a request with a body counts as connected once its body
/// starts flowing (the TCP and TLS handshakes are done). A request without a body cannot be told
/// apart from a slow answer, so only its whole-call timeout applies. `WajubSession` measures the
/// contract's timeouts; URLSession's own are a backstop a few seconds longer.
final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private static let backstop: TimeInterval = 5
    private let progress = ProgressDelegate()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Timing.paymentRequestTimeout + URLSessionTransport.backstop
        configuration.timeoutIntervalForResource = Timing.paymentRequestTimeout + URLSessionTransport.backstop
        #if canImport(Darwin)
        configuration.waitsForConnectivity = false
        #endif
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: progress, delegateQueue: nil)
    }()
    private let lock = NSLock()
    private var created = false

    deinit {
        // A session with a delegate lives until it is invalidated: let running tasks finish, then go.
        lock.lock()
        let created = self.created
        lock.unlock()
        if created { session.finishTasksAndInvalidate() }
    }

    func reportsConnection(for request: HTTPRequest) -> Bool {
        request.body?.isEmpty == false
    }

    func send(_ request: HTTPRequest, connected: @escaping @Sendable () -> Void) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout + URLSessionTransport.backstop)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let session = currentSession()
        let progress = self.progress
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, Error>) in
                let task = session.dataTask(with: urlRequest) { data, response, error in
                    // With a completion handler the delegate hears of no completion: forget the task here.
                    if let identifier = box.identifier { progress.forget(identifier) }
                    if let error {
                        continuation.resume(throwing: URLSessionTransport.map(error))
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        continuation.resume(throwing: TransportError.network("not an HTTP response"))
                        return
                    }
                    var headers: [String: String] = [:]
                    for (name, value) in http.allHeaderFields {
                        headers[String(describing: name)] = String(describing: value)
                    }
                    continuation.resume(returning: HTTPResponse(status: http.statusCode, headers: headers, body: data ?? Data()))
                }
                progress.watch(task, connected: connected)
                box.start(task)
            }
        } onCancel: {
            box.cancel()
        }
    }

    private func currentSession() -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        created = true
        return session
    }

    private static func map(_ error: Error) -> TransportError {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return .network(nsError.localizedDescription) }
        switch nsError.code {
        case NSURLErrorTimedOut: return .timeout
        case NSURLErrorCancelled: return .cancelled
        default: return .network(nsError.localizedDescription)
        }
    }

    /// Reports a task's connection once its body starts flowing.
    private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var callbacks: [Int: @Sendable () -> Void] = [:]

        func watch(_ task: URLSessionTask, connected: @escaping @Sendable () -> Void) {
            lock.lock()
            callbacks[task.taskIdentifier] = connected
            lock.unlock()
        }

        func forget(_ identifier: Int) {
            lock.lock()
            callbacks.removeValue(forKey: identifier)
            lock.unlock()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                        totalBytesExpectedToSend: Int64) {
            lock.lock()
            let connected = callbacks.removeValue(forKey: task.taskIdentifier)
            lock.unlock()
            connected?()
        }
    }

    /// Lets a cancellation that arrives before the task exists still cancel it.
    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false

        var identifier: Int? {
            lock.lock()
            defer { lock.unlock() }
            return task?.taskIdentifier
        }

        func start(_ task: URLSessionDataTask) {
            lock.lock()
            self.task = task
            let cancelled = self.cancelled
            lock.unlock()
            task.resume()
            if cancelled { task.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }
}
