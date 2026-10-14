import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A text WebSocket. The SDK uses `URLSessionWebSocketTask`; tests use a fake.
protocol WebSocketConnection: AnyObject, Sendable {
    func send(_ text: String) async throws
    /// The next text frame; throws when the socket closes.
    func receive() async throws -> String
    func close()
}

/// `URLSessionWebSocketTask`, wrapped.
final class URLSessionWebSocket: WebSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(url: URL) {
        task = URLSession.shared.webSocketTask(with: url)
        task.resume()
    }

    func send(_ text: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.send(.string(text)) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            task.receive { result in
                switch result {
                case .success(.string(let text)): continuation.resume(returning: text)
                case .success(.data(let data)): continuation.resume(returning: String(decoding: data, as: UTF8.self))
                case .success: continuation.resume(returning: "")
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

/// Where the realtime socket connects (README §13.3).
struct RealtimeEndpoint: Equatable, Sendable {
    var host: String
    var port: Int
    var tls: Bool
    var key: String
    /// `private-payment.trx_…`.
    var channel: String

    /// `echo` (and `PresentOptions.realtime`); `nil` when realtime cannot run: no `echo`, no `key`,
    /// no host, or turned off.
    init?(echo: EchoConfig?, override: RealtimeOptions?, transactionId: String) {
        if override?.enabled == false { return nil }
        guard let echo, let key = echo.key, !transactionId.isEmpty else { return nil }
        var tls = true
        var host = echo.wsHost ?? ""
        if host.lowercased().hasPrefix("wss://") {
            host.removeFirst(6)
        } else if host.lowercased().hasPrefix("ws://") {
            host.removeFirst(5)
            tls = false
        }
        host = host.split(separator: "/").first.map(String.init) ?? host
        if let overrideHost = override?.host, !overrideHost.isEmpty { host = overrideHost }
        if let overrideTLS = override?.tls { tls = overrideTLS }
        guard !host.isEmpty else { return nil }
        self.host = host
        self.tls = tls
        port = override?.port ?? echo.wsPort ?? (tls ? 443 : 80)
        self.key = key
        channel = echo.channelPrefix + transactionId
    }

    var url: URL? {
        var components = URLComponents()
        components.scheme = tls ? "wss" : "ws"
        components.host = host
        components.port = port
        components.path = "/app/\(key)"
        components.queryItems = [
            URLQueryItem(name: "protocol", value: "7"),
            URLQueryItem(name: "client", value: "wajub-\(WajubSDK.name)"),
            URLQueryItem(name: "version", value: WajubSDK.version),
            URLQueryItem(name: "flash", value: "false"),
        ]
        return components.url
    }
}

/// A minimal Pusher-protocol client (Pusher, Reverb and Soketi) for one private channel and one event.
@MainActor
final class PusherClient {
    static let event = "PaymentStatusUpdated"

    private let endpoint: RealtimeEndpoint
    private let authorize: (_ socketId: String, _ channel: String) async throws -> String
    private let connect: (URL) -> WebSocketConnection
    private let clock: WajubClock
    private let onEvent: (JSONValue) -> Void
    private let onConnectedChange: (Bool) -> Void

    private var task: Task<Void, Never>?
    private var socket: WebSocketConnection?
    private(set) var isConnected = false

    init(endpoint: RealtimeEndpoint, authorize: @escaping (String, String) async throws -> String,
         connect: @escaping (URL) -> WebSocketConnection, clock: WajubClock,
         onEvent: @escaping (JSONValue) -> Void, onConnectedChange: @escaping (Bool) -> Void) {
        self.endpoint = endpoint
        self.authorize = authorize
        self.connect = connect
        self.clock = clock
        self.onEvent = onEvent
        self.onConnectedChange = onConnectedChange
    }

    func start() {
        guard task == nil, let url = endpoint.url else { return }
        task = Task { [weak self] in await self?.run(url: url) }
    }

    func stop() {
        task?.cancel()
        task = nil
        socket?.close()
        socket = nil
        setConnected(false)
    }

    private func run(url: URL) async {
        var failures = 0
        while !Task.isCancelled {
            let socket = connect(url)
            self.socket = socket
            let outcome = await session(socket)
            socket.close()
            setConnected(false)
            if outcome == .fatal || Task.isCancelled { return }
            if outcome == .subscribed { failures = 0 }
            failures += 1
            // Reconnect with backoff: 1, 2, 4, … 30 s.
            do {
                try await clock.sleep(seconds: min(pow(2, Double(failures - 1)), 30))
            } catch {
                return
            }
        }
    }

    private enum SessionOutcome {
        /// Closed after the subscription worked: reconnect at once with a fresh backoff.
        case subscribed
        case failed
        /// A `pusher:error` 4000–4099: do not reconnect.
        case fatal
    }

    private func session(_ socket: WebSocketConnection) async -> SessionOutcome {
        var subscribed = false
        while !Task.isCancelled {
            let text: String
            do {
                text = try await socket.receive()
            } catch {
                return subscribed ? .subscribed : .failed
            }
            guard let frame = try? JSONValue.parse(text), let event = frame["event"]?.string else { continue }
            let data = PusherClient.payload(frame["data"])
            switch event {
            case "pusher:connection_established":
                guard let socketId = data["socket_id"]?.nonEmptyString else { return .failed }
                do {
                    let auth = try await authorize(socketId, endpoint.channel)
                    let subscribe: JSONValue = ["event": "pusher:subscribe",
                                                "data": ["auth": .string(auth), "channel": .string(endpoint.channel)]]
                    try await socket.send(subscribe.jsonString)
                } catch {
                    return .failed
                }
            case "pusher_internal:subscription_succeeded":
                if frame["channel"]?.string == endpoint.channel {
                    subscribed = true
                    setConnected(true)
                }
            case "pusher:ping":
                let pong: JSONValue = ["event": "pusher:pong", "data": [:]]
                try? await socket.send(pong.jsonString)
            case "pusher:error":
                if let code = data["code"]?.int, (4000...4099).contains(code) { return .fatal }
            case PusherClient.event, "." + PusherClient.event:
                if frame["channel"]?.string == endpoint.channel { onEvent(frame["data"] ?? .null) }
            default:
                break
            }
        }
        return .fatal
    }

    private func setConnected(_ connected: Bool) {
        guard connected != isConnected else { return }
        isConnected = connected
        onConnectedChange(connected)
    }

    /// Pusher sends `data` as a JSON string.
    static func payload(_ data: JSONValue?) -> JSONValue {
        if case .string(let text)? = data, let parsed = try? JSONValue.parse(text) { return parsed }
        return data ?? .null
    }
}
