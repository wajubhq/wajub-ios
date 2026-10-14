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
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
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

/// `URLSession`, one session per timeout class.
///
/// `URLSession` has no connect-only timeout: each request gets the call's whole timeout
/// (30 s or 60 s) both as its idle timeout and as its resource timeout, so the 10 s connect budget
/// of the contract is not enforced separately on Apple platforms.
final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [TimeInterval: URLSession] = [:]

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let session = session(timeout: request.timeout)
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, Error>) in
                let task = session.dataTask(with: urlRequest) { data, response, error in
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
                box.start(task)
            }
        } onCancel: {
            box.cancel()
        }
    }

    private func session(timeout: TimeInterval) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let session = sessions[timeout] { return session }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        #if canImport(Darwin)
        configuration.waitsForConnectivity = false
        #endif
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        sessions[timeout] = session
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

    /// Lets a cancellation that arrives before the task exists still cancel it.
    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false

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
