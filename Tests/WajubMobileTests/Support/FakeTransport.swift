import Foundation
@testable import WajubMobile

extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// A gate a fake answer waits on until the test opens it.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let open = lock.locked { () -> Bool in
                if !isOpen { waiters.append(continuation) }
                return isOpen
            }
            if open { continuation.resume() }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let waiters = self.waiters
        self.waiters = []
        lock.unlock()
        waiters.forEach { $0.resume() }
    }
}

/// The fake HTTP layer: answers each `/pay/*` call with a fixture's `http_status` and `body`, or a scripted answer.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    enum Reply {
        case fixture(String)
        case json(Int, JSONValue, headers: [String: String] = [:])
        case failure(TransportError)
        /// Waits for the gate, then answers.
        indirect case gated(Gate, Reply)
    }

    struct Request {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data?
        var connectTimeout: TimeInterval
        var timeout: TimeInterval

        var json: JSONValue? { body.flatMap { try? JSONValue.parse($0) } }
        func header(_ name: String) -> String? {
            headers.first { $0.key.lowercased() == name.lowercased() }?.value
        }
    }

    private let lock = NSLock()
    private var replies: [String: [Reply]] = [:]
    private var recorded: [Request] = []

    /// Answers `method path` with these replies in turn; the last one repeats.
    func on(_ method: String, _ path: String, _ replies: Reply...) {
        on(method, path, replies: replies)
    }

    func on(_ method: String, _ path: String, replies: [Reply]) {
        lock.locked { self.replies["\(method) \(path)"] = replies }
    }

    /// Fixture shortcut: the endpoint comes from the fixture's `request`.
    func answer(_ fixtures: String...) {
        for fixture in fixtures {
            let request = Fixtures.envelope(fixture)["request"]
            on(request?["method"]?.string ?? "GET", request?["path"]?.string ?? "", .fixture(fixture))
        }
    }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func requests(_ method: String, _ path: String) -> [Request] {
        requests.filter { $0.method == method && $0.path == path }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let key = "\(request.method) \(request.url.path)"
        guard let reply = record(request) else {
            return HTTPResponse(status: 404, body: Data("{\"code\":404,\"status\":\"Not Found\",\"message\":\"no fake for \(key)\"}".utf8))
        }
        return try await respond(reply)
    }

    /// Records the request and takes its reply (the last one repeats).
    private func record(_ request: HTTPRequest) -> Reply? {
        lock.locked {
            recorded.append(Request(method: request.method, path: request.url.path, headers: request.headers, body: request.body,
                                    connectTimeout: request.connectTimeout, timeout: request.timeout))
            let key = "\(request.method) \(request.url.path)"
            var queue = replies[key] ?? []
            let reply = queue.first
            if queue.count > 1 {
                queue.removeFirst()
                replies[key] = queue
            }
            return reply
        }
    }

    private func respond(_ reply: Reply) async throws -> HTTPResponse {
        switch reply {
        case .fixture(let name):
            return HTTPResponse(status: Fixtures.status(name), headers: Fixtures.headers(name), body: Fixtures.body(name).serialized())
        case .json(let status, let body, let headers):
            return HTTPResponse(status: status, headers: headers, body: body.serialized())
        case .failure(let error):
            throw error
        case .gated(let gate, let next):
            await gate.wait()
            try Task.checkCancellation()
            return try await respond(next)
        }
    }
}
