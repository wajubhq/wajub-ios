import Foundation
import XCTest
@testable import WajubMobile

/// A virtual clock: sleepers wait until the test advances time.
final class TestClock: WajubClock, @unchecked Sendable {
    private let lock = NSLock()
    /// 2026-10-14T09:00:00Z: before the fixtures' `expires_at` (09:30).
    private var current = Date(timeIntervalSince1970: 1_791_968_400)
    private var sleepers: [(id: UUID, deadline: Date, continuation: CheckedContinuation<Void, Error>)] = []
    private var recordedSleeps: [TimeInterval] = []

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Every duration a sleeper asked for, in order.
    var sleeps: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSleeps
    }

    var sleeperCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleepers.count
    }

    /// Whether a sleeper is due within `seconds` from now.
    func hasSleeper(dueWithin seconds: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let limit = current.addingTimeInterval(seconds)
        return sleepers.contains { $0.deadline <= limit }
    }

    /// The earliest sleeper's remaining time.
    var nextWake: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return sleepers.map { $0.deadline.timeIntervalSince(current) }.min()
    }

    func sleep(seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                register(id: id, seconds: seconds, continuation: continuation)
            }
        } onCancel: {
            cancel(id: id)
        }
    }

    private func register(id: UUID, seconds: TimeInterval, continuation: CheckedContinuation<Void, Error>) {
        let cancelled = lock.locked { () -> Bool in
            recordedSleeps.append(seconds)
            if Task.isCancelled { return true }
            sleepers.append((id, current.addingTimeInterval(max(seconds, 0)), continuation))
            return false
        }
        if cancelled { continuation.resume(throwing: CancellationError()) }
    }

    private func cancel(id: UUID) {
        let sleeper = lock.locked { () -> (id: UUID, deadline: Date, continuation: CheckedContinuation<Void, Error>)? in
            guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
            return sleepers.remove(at: index)
        }
        sleeper?.continuation.resume(throwing: CancellationError())
    }

    /// Moves time forward, waking every sleeper that is due, earliest first.
    func advance(by seconds: TimeInterval) async {
        let target = lock.locked { current.addingTimeInterval(seconds) }
        while let sleeper = nextDue(before: target) {
            sleeper.resume()
            await settle()
        }
    }

    /// Removes the earliest sleeper due by `target` and moves time to it; at the end, moves time to `target`.
    private func nextDue(before target: Date) -> CheckedContinuation<Void, Error>? {
        lock.locked {
            guard let index = sleepers.indices.filter({ sleepers[$0].deadline <= target })
                .min(by: { sleepers[$0].deadline < sleepers[$1].deadline }) else {
                current = max(current, target)
                return nil
            }
            let sleeper = sleepers.remove(at: index)
            current = max(current, sleeper.deadline)
            return sleeper.continuation
        }
    }
}

/// Lets the tasks the code under test started run for a while.
func settle() async {
    for _ in 0..<20 {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

/// Waits (real time, bounded) until `condition` holds.
@MainActor
func waitUntil(_ message: @autoclosure () -> String = "condition", timeout: TimeInterval = 3,
               file: StaticString = #filePath, line: UInt = #line, _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("timed out waiting for \(message())", file: file, line: line)
            return
        }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

/// An in-memory install id store.
final class MemoryInstallIDStore: InstallIDStore, @unchecked Sendable {
    private let lock = NSLock()
    private var id: String?

    func read() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return id
    }

    func write(_ id: String) {
        lock.lock()
        self.id = id
        lock.unlock()
    }
}

extension DeviceEnvironment {
    static func test(languages: [String] = ["fr-CM", "en"], store: InstallIDStore = MemoryInstallIDStore()) -> DeviceEnvironment {
        DeviceEnvironment(platform: "ios", osVersion: "18.1", preferredLanguages: languages, timeZone: "Africa/Douala",
                          appUserAgent: "ShopApp/2.3", screen: { "1080x2400" }, installIDStore: store)
    }
}

/// A browser that records what it was asked to open.
@MainActor
final class FakeBrowser: BrowserOpening {
    var opened: [(url: URL, mode: BrowserMode)] = []
    var canOpen = true
    var onClose: (@MainActor @Sendable () -> Void)?

    func open(_ url: URL, mode: BrowserMode, onClose: @escaping @MainActor @Sendable () -> Void) async -> Bool {
        opened.append((url, mode))
        self.onClose = onClose
        return canOpen
    }

    /// The payer closes the in-app browser.
    func close() {
        onClose?()
    }
}

@MainActor
final class FakePresenter: CheckoutPresenting {
    var presented: [CheckoutController] = []
    var dismissed: [CheckoutController] = []

    /// Holds the dismissal's end until the test releases it.
    var holdsDismissal = false
    private var pendingCompletion: (@MainActor @Sendable () -> Void)?

    func present(_ controller: CheckoutController) { presented.append(controller) }

    func dismiss(_ controller: CheckoutController, completion: @escaping @MainActor @Sendable () -> Void) {
        dismissed.append(controller)
        if holdsDismissal { pendingCompletion = completion } else { completion() }
    }

    /// The sheet is gone.
    func finishDismissal() {
        pendingCompletion?()
        pendingCompletion = nil
    }
}

/// A WebSocket whose frames the test pushes.
final class FakeWebSocket: WebSocketConnection, @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var inbox: [String] = []
    private var waiter: CheckedContinuation<String, Error>?
    private var closed = false
    private(set) var sent: [String] = []

    init(url: URL) {
        self.url = url
    }

    func send(_ text: String) async throws {
        append(text)
    }

    private func append(_ text: String) {
        lock.locked { sent.append(text) }
    }

    var sentFrames: [JSONValue] {
        lock.locked { sent.compactMap { try? JSONValue.parse($0) } }
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            take(continuation)
        }
    }

    private func take(_ continuation: CheckedContinuation<String, Error>) {
        enum Next { case closed, text(String), wait }
        let next = lock.locked { () -> Next in
            if closed { return .closed }
            if !inbox.isEmpty { return .text(inbox.removeFirst()) }
            waiter = continuation
            return .wait
        }
        switch next {
        case .closed: continuation.resume(throwing: TransportError.network("closed"))
        case .text(let text): continuation.resume(returning: text)
        case .wait: break
        }
    }

    func push(_ frame: JSONValue) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: frame.jsonString)
        } else {
            inbox.append(frame.jsonString)
            lock.unlock()
        }
    }

    func close() {
        lock.lock()
        closed = true
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(throwing: TransportError.network("closed"))
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }
}

/// Records every callback, in order.
@MainActor
final class CallbackRecorder {
    var events: [String] = []
    var states: [CheckoutState] = []
    var ready: [ReadyEvent] = []
    var loadErrors: [WajubError] = []
    var errors: [WajubError] = []
    var started: [PaymentStartedEvent] = []
    var redirects: [String] = []
    var successes: [PaymentSuccess] = []
    var cancels: [CancelEvent] = []
    var completions: [CheckoutResult] = []

    var callbacks: CheckoutCallbacks {
        CheckoutCallbacks(
            onReady: { [unowned self] in self.ready.append($0); self.events.append("ready") },
            onStateChange: { [unowned self] in self.states.append($0.state); self.events.append("state:\($0.state.rawValue)") },
            onLoadError: { [unowned self] in self.loadErrors.append($0); self.events.append("loadError:\($0.code)") },
            onPaymentStarted: { [unowned self] in self.started.append($0); self.events.append("started") },
            onRedirect: { [unowned self] in self.redirects.append($0.url); self.events.append("redirect") },
            onSuccess: { [unowned self] in self.successes.append($0); self.events.append("success") },
            onError: { [unowned self] in self.errors.append($0); self.events.append("error:\($0.code)") },
            onCancel: { [unowned self] in self.cancels.append($0); self.events.append("cancel:\($0.reason.rawValue)") },
            onComplete: { [unowned self] in self.completions.append($0); self.events.append("complete:\($0.status)") })
    }
}

/// A controller wired to fakes.
@MainActor
final class Harness {
    let transport = FakeTransport()
    let clock = TestClock()
    let browser = FakeBrowser()
    let recorder = CallbackRecorder()
    var sockets: [FakeWebSocket] = []
    var device = DeviceEnvironment.test()
    var collector: CardCollector?
    private(set) var controller: CheckoutController!

    init(session: String? = nil, config: String? = nil) {
        transport.clock = clock
        if let session { transport.on("GET", "/pay/session", .fixture(session)) }
        if let config { transport.on("GET", "/pay/sdk-config", .fixture(config)) }
        else { transport.on("GET", "/pay/sdk-config", .fixture("sdk-config-sandbox")) }
    }

    var client: WajubSession {
        WajubSession(sessionToken: "test_token", baseURL: URL(string: "https://api.test.wajub")!, transport: transport, clock: clock,
                     device: device, random: { 0.5 }, language: .en)
    }

    func makeController(_ configure: (inout PresentOptions) -> Void = { _ in }) -> CheckoutController {
        var options = PresentOptions(sessionToken: "test_token", callbacks: recorder.callbacks, cardCollector: collector)
        configure(&options)
        controller = CheckoutController(options: options, client: client, browser: browser, connectWebSocket: { [unowned self] url in
            let socket = FakeWebSocket(url: url)
            self.sockets.append(socket)
            return socket
        })
        return controller
    }

    /// Starts a controller and waits until it is ready (or shows a load error).
    @discardableResult
    func start(_ configure: (inout PresentOptions) -> Void = { _ in }) async -> CheckoutController {
        let controller = makeController(configure)
        controller.start()
        await waitUntil("ready") {
            if controller.state != nil { return true }
            if case .loadError = controller.screen { return true }
            return false
        }
        return controller
    }

    /// Waits until something sleeps on the clock with a deadline within `seconds`, then moves time forward.
    func advance(by seconds: TimeInterval, file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil("a sleeper due within \(seconds) s", file: file, line: line) { self.clock.hasSleeper(dueWithin: seconds) }
        await clock.advance(by: seconds)
        await settle()
    }

    /// Advances to each next wake-up until `condition` holds.
    func drive(until message: String = "condition", maxSteps: Int = 400, file: StaticString = #filePath, line: UInt = #line,
               _ condition: @MainActor () -> Bool) async {
        for _ in 0..<maxSteps {
            await settle()
            if condition() { return }
            if let wake = clock.nextWake { await clock.advance(by: max(wake, 0)) }
        }
        await settle()
        if !condition() { XCTFail("never reached \(message)", file: file, line: line) }
    }

    func processBodies() -> [JSONValue] {
        transport.requests("POST", "/pay/process").compactMap(\.json)
    }
}
