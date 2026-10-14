import Foundation

/// The polling schedule of README §13.2.
struct PollSchedule: Sendable {
    private let random: @Sendable () -> Double
    private var interval = Timing.pollInterval
    private(set) var lastChangeAt: Date
    private(set) var consecutiveErrors = 0
    private var lastStatus: TransactionStatus?
    private var retryAfter: TimeInterval?

    init(start: Date, random: @escaping @Sendable () -> Double) {
        lastChangeAt = start
        self.random = random
    }

    /// The delay before the next poll: 5 s, ×1.5 per poll up to 15 s after 2 minutes without a change,
    /// 15 s while the socket is connected; after errors `min(5 s × 2^n, 60 s) ± 20 %`; a 429's `Retry-After`.
    mutating func nextDelay(now: Date, socketConnected: Bool) -> TimeInterval {
        if let wait = retryAfter {
            retryAfter = nil
            return wait
        }
        if consecutiveErrors > 0 {
            let base = min(Timing.pollErrorBase * pow(2, Double(consecutiveErrors)), Timing.pollErrorMax)
            return base * (1 + Timing.pollErrorJitter * (2 * random() - 1))
        }
        if socketConnected { return Timing.pollWithSocket }
        if now.timeIntervalSince(lastChangeAt) >= Timing.pollSlowAfter {
            interval = min(interval * Timing.pollSlowFactor, Timing.pollMaxInterval)
        } else {
            interval = Timing.pollInterval
        }
        return interval
    }

    mutating func recordStatus(_ status: TransactionStatus, now: Date) {
        consecutiveErrors = 0
        if status != lastStatus {
            lastStatus = status
            lastChangeAt = now
            interval = Timing.pollInterval
        }
    }

    mutating func recordError() {
        consecutiveErrors += 1
    }

    mutating func recordRateLimit(retryAfter seconds: TimeInterval?) {
        if let seconds { retryAfter = seconds } else { consecutiveErrors += 1 }
    }
}

/// Watches the payment's status: polls `GET /pay/status` and listens on the realtime channel next to it,
/// until the checkout stops it (README §13).
@MainActor
final class StatusWatcher {
    private let client: WajubSession
    private let clock: WajubClock
    private let deadline: Date
    private var schedule: PollSchedule
    private var realtime: PusherClient?
    private var loop: Task<Void, Never>?
    private var stopped = false

    /// A status, from a poll or the socket.
    var onUpdate: ((StatusUpdate) -> Void)?
    /// A `GET /pay/status` refusal that ends the watch (401, 403, 404, 410).
    var onRefusal: ((APIAnswer) -> Void)?
    /// The overall cap is reached.
    var onCap: (() -> Void)?

    init(client: WajubSession, clock: WajubClock, random: @escaping @Sendable () -> Double, deadline: Date) {
        self.client = client
        self.clock = clock
        self.deadline = deadline
        schedule = PollSchedule(start: clock.now, random: random)
    }

    /// Starts the realtime client next to the polling (call before `start()`).
    func attach(realtime endpoint: RealtimeEndpoint, connect: @escaping (URL) -> WebSocketConnection) {
        let client = self.client
        realtime = PusherClient(
            endpoint: endpoint,
            authorize: { socketId, channel in try await client.broadcastingAuth(socketId: socketId, channelName: channel) },
            connect: connect, clock: clock,
            onEvent: { [weak self] data in
                guard let self, !self.stopped, let event = PaymentStatusUpdatedEvent(data: data) else { return }
                self.schedule.recordStatus(event.update.status, now: self.clock.now)
                self.onUpdate?(event.update)
            },
            onConnectedChange: { _ in })
    }

    var isRealtimeConnected: Bool { realtime?.isConnected ?? false }

    func start() {
        realtime?.start()
        restartLoop(pollFirst: false)
    }

    /// Polls at once (the payer came back from a browser or the app came to the foreground), then carries on.
    func pollNow() {
        guard !stopped else { return }
        restartLoop(pollFirst: true)
    }

    func stop() {
        stopped = true
        loop?.cancel()
        loop = nil
        realtime?.stop()
        realtime = nil
    }

    private func restartLoop(pollFirst: Bool) {
        loop?.cancel()
        loop = Task { [weak self] in
            guard let self else { return }
            if pollFirst { await self.poll() }
            await self.run()
        }
    }

    private func run() async {
        while !stopped && !Task.isCancelled {
            let delay = schedule.nextDelay(now: clock.now, socketConnected: isRealtimeConnected)
            do {
                try await clock.sleep(seconds: delay)
            } catch {
                return
            }
            guard !stopped && !Task.isCancelled else { return }
            if clock.now >= deadline {
                stop()
                onCap?()
                return
            }
            await poll()
        }
    }

    private func poll() async {
        let answer: APIAnswer
        do {
            answer = try await client.send(.status, policy: .noRetry)
        } catch is CancellationError {
            return
        } catch {
            schedule.recordError()
            return
        }
        guard !stopped && !Task.isCancelled else { return }
        switch answer.status {
        case 200...299:
            let update = StatusResponse(json: answer.body ?? .null).transaction
            // An empty answer is no information: poll again on schedule.
            guard update.isInformative else { return }
            schedule.recordStatus(update.status, now: clock.now)
            onUpdate?(update)
        case 429:
            let retryAfter = answer.body?["retry_after"]?.double
                ?? answer.header("Retry-After").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            schedule.recordRateLimit(retryAfter: retryAfter)
        case 401, 403, 404, 410:
            stop()
            onRefusal?(answer)
        default:
            schedule.recordError()
        }
    }
}
