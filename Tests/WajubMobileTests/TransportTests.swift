import XCTest
@testable import WajubMobile

/// A clock whose sleeps return at once (and are recorded).
final class ImmediateClock: WajubClock, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []
    var now: Date { Date(timeIntervalSince1970: 1_791_968_400) }
    var sleeps: [TimeInterval] { lock.locked { recorded } }

    func sleep(seconds: TimeInterval) async throws {
        record(seconds)
        try Task.checkCancellation()
    }

    private func record(_ seconds: TimeInterval) {
        lock.locked { recorded.append(seconds) }
    }
}

/// TR — headers, device signals, timeouts, retries and idempotency.
final class TransportTests: XCTestCase {
    private func client(_ transport: FakeTransport, clock: WajubClock = ImmediateClock(),
                        store: InstallIDStore = MemoryInstallIDStore()) -> WajubSession {
        WajubSession(sessionToken: "test_token", baseURL: URL(string: "https://api.test.wajub")!, transport: transport, clock: clock,
                     device: .test(store: store), random: { 0.5 }, language: .en)
    }

    private var processBody: JSONValue {
        ["channel": "cm.mobile", "data": ["phone": "+237670000000", "country": "CM"]]
    }

    /// TR-01 sends the common headers
    func test_TR_01_sendsTheCommonHeaders() async throws {
        let transport = FakeTransport()
        transport.answer("session-cm-aggregate", "cancel-200")
        let session = client(transport)
        _ = try await session.session()
        _ = try await session.cancel()
        for request in transport.requests {
            XCTAssertEqual(request.header("Authorization"), "Bearer test_token")
            XCTAssertEqual(request.header("Accept"), "application/json")
            XCTAssertEqual(request.header("Accept-Language"), "fr-CM, fr;q=0.9, en;q=0.8")
            XCTAssertNotNil(UUID(uuidString: request.header("X-Request-Id") ?? ""))
            XCTAssertEqual(request.header("X-Wajub-Client"), "wajub-ios/1.0.0 (ios 18.1)")
        }
        XCTAssertNil(transport.requests[0].header("Content-Type"), "a GET has no body")
        XCTAssertNotEqual(transport.requests[0].header("X-Request-Id"), transport.requests[1].header("X-Request-Id"))

        _ = await session.process(channel: "cm.mobile", data: ["phone": "+237670000000"])
        XCTAssertEqual(transport.requests("POST", "/pay/process").first?.header("Content-Type"), "application/json")
    }

    /// TR-02 suffixes the user agent
    func test_TR_02_suffixesTheUserAgent() async throws {
        let transport = FakeTransport()
        transport.answer("session-cm-aggregate")
        _ = try await client(transport).session()
        XCTAssertEqual(transport.requests[0].header("User-Agent"), "ShopApp/2.3 wajub-ios/1.0.0 (ios 18.1)")
        XCTAssertTrue(DeviceEnvironment.test().userAgent.hasSuffix(DeviceEnvironment.test().clientIdentifier))
    }

    /// TR-03 sends device signals
    func test_TR_03_sendsDeviceSignals() async throws {
        let transport = FakeTransport()
        transport.answer("process-processing-mobile-money-sandbox")
        let store = MemoryInstallIDStore()
        _ = await client(transport, store: store).process(channel: "cm.mobile", data: ["phone": "+237670000000"])
        _ = await client(transport, store: store).process(channel: "cm.mobile", data: ["phone": "+237670000000"])
        let signals = transport.requests("POST", "/pay/process").map { $0.json?["data"]?["_client"] }
        let reference = Fixtures.envelope("process-processing-mobile-money-sandbox")["request"]?["body"]?["data"]?["_client"]
        let first = try XCTUnwrap(signals[0])
        XCTAssertEqual(Set(first.object?.keys.map { $0 } ?? []), Set((reference?.object?.keys.map { $0 } ?? []) + ["client"]))
        XCTAssertEqual(first["timezone"]?.string, "Africa/Douala")
        XCTAssertEqual(first["language"]?.string, "fr-CM")
        XCTAssertEqual(first["screen"]?.string, "1080x2400")
        XCTAssertEqual(first["color_depth"]?.int, 24)
        XCTAssertEqual(first["client"]?.string, "wajub-ios/1.0.0 (ios 18.1)")
        let fingerprint = try XCTUnwrap(first["fingerprint"]?.string)
        XCTAssertTrue((16...64).contains(fingerprint.count))
        XCTAssertTrue(fingerprint.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(signals[1]?["fingerprint"]?.string, fingerprint, "two SDK instances on the same install")
    }

    /// TR-04 keeps a stable install fingerprint
    func test_TR_04_keepsAStableInstallFingerprint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wajub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("install-id")
        let first = InstallFingerprint.value(store: FileInstallIDStore(fileURL: file))
        // A restart: a new store reading the same file.
        let second = InstallFingerprint.value(store: FileInstallIDStore(fileURL: file))
        XCTAssertEqual(first, second)
        let id = try String(contentsOf: file, encoding: .utf8)
        XCTAssertNotNil(UUID(uuidString: id), "a random UUID, not a hardware or advertising id")
        XCTAssertEqual(first, Digest.sha256Hex("device:" + id))
        let other = InstallFingerprint.value(store: FileInstallIDStore(fileURL: directory.appendingPathComponent("other")))
        XCTAssertNotEqual(first, other)
    }

    /// TR-05 applies per-call timeouts
    func test_TR_05_appliesPerCallTimeouts() async throws {
        let transport = FakeTransport()
        let session = client(transport)
        let calls: [(Endpoint, TimeInterval)] = [
            (.session, 30), (.sdkConfig, 30), (.status, 30), (.cancel, 30), (.resend(.otp), 30), (.threeDSSend, 30),
            (.broadcastingAuth, 30), (.process, 60), (.clientSession, 60), (.clientSessionComplete, 60),
            (.verify(.otp), 60), (.verify(.address), 60), (.threeDSVerify, 60),
        ]
        for (endpoint, timeout) in calls {
            _ = try await session.send(endpoint, body: endpoint.method == "POST" ? JSONValue.object([:]) : nil, policy: .noRetry)
            let request = try XCTUnwrap(transport.requests.last)
            XCTAssertEqual(request.path, endpoint.path)
            XCTAssertEqual(request.connectTimeout, 10, endpoint.path)
            XCTAssertEqual(request.timeout, timeout, endpoint.path)
        }
    }

    /// TR-06 retries process with the same idempotency key
    @MainActor func test_TR_06_retriesProcessWithTheSameIdempotencyKey() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/pay/process", .failure(.timeout), .json(503, ["code": 503]), .fixture("process-processing-mobile-money-sandbox"))
        let clock = ImmediateClock()
        let session = client(transport, clock: clock)
        let answer = try await session.send(.process, body: processBody, idempotencyKey: "5f0c2b1e-8d4a-4c3b-9e7f-1a2b3c4d5e6f")
        XCTAssertEqual(answer.status, 202)
        let requests = transport.requests("POST", "/pay/process")
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(Set(requests.map(\.body)).count, 1, "the identical body")
        XCTAssertEqual(Set(requests.compactMap { $0.header("Idempotency-Key") }), ["5f0c2b1e-8d4a-4c3b-9e7f-1a2b3c4d5e6f"])
        XCTAssertEqual(Set(requests.compactMap { $0.header("X-Request-Id") }).count, 3)
        XCTAssertEqual(clock.sleeps, [1, 2])

        // The API replays the cached answer for the same key and payload.
        let replay = PaymentAnswer.classify(APIAnswer(status: Fixtures.status("process-idempotent-replay"),
                                                      body: Fixtures.body("process-idempotent-replay")),
                                            mobileMoney: true, allowsClientSession: false)
        guard case .processing(.approval, _) = replay else { return XCTFail("replay is the same approval") }

        // A new press of Pay after a definitive answer uses a new key.
        let harness = await Harness.mobileMoney(answers: "process-failed-402")
        harness.controller.submitMobileMoney()
        await waitUntil("failed") { harness.controller.state == .failed }
        harness.controller.tryAgain()
        harness.transport.answer("process-processing-mobile-money-sandbox")
        harness.controller.submitMobileMoney()
        await waitUntil("second process") { harness.transport.requests("POST", "/pay/process").count == 2 }
        let keys = harness.transport.requests("POST", "/pay/process").compactMap { $0.header("Idempotency-Key") }
        XCTAssertEqual(keys.count, 2)
        XCTAssertNotEqual(keys[0], keys[1])
        harness.controller.hostGone()
    }

    /// TR-07 does not retry non-retryable posts
    func test_TR_07_doesNotRetryNonRetryablePosts() async throws {
        for fixture in ["process-failed-402", "process-422-validation", "error-500-production"] {
            let transport = FakeTransport()
            transport.on("POST", "/pay/process", .fixture(fixture))
            _ = try await client(transport).send(.process, body: processBody, idempotencyKey: "key")
            XCTAssertEqual(transport.requests.count, 1, fixture)
        }
        for reply: FakeTransport.Reply in [.fixture("otp-verify-invalid"), .failure(.timeout), .json(503, [:])] {
            let transport = FakeTransport()
            transport.on("POST", "/pay/otp/verify", reply)
            _ = try? await client(transport).send(.verify(.otp), body: ["otp_id": "prc_1", "code": "000000"])
            XCTAssertEqual(transport.requests.count, 1)
        }
    }

    /// TR-08 retries idempotent reads
    func test_TR_08_retriesIdempotentReads() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/pay/session", .json(503, [:]), .json(503, [:]), .fixture("session-cm-aggregate"))
        let clock = ImmediateClock()
        let session = try await client(transport, clock: clock).session()
        XCTAssertEqual(session.transaction.id, "trx_PVrU8x2kQ1mNa7Lb3cDe")
        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertEqual(clock.sleeps, [1, 2])

        for status in [408, 500, 502, 504] {
            let transport = FakeTransport()
            transport.on("GET", "/pay/status", .json(status, [:]))
            _ = try? await client(transport).status()
            XCTAssertEqual(transport.requests.count, 4, "\(status): three retries")
        }
        let network = FakeTransport()
        network.on("GET", "/pay/sdk-config", .failure(.network("offline")), .failure(.timeout), .fixture("sdk-config-cm-stripe"))
        _ = try await client(network).sdkConfig()
        XCTAssertEqual(network.requests.count, 3)

        let shortWait = FakeTransport()
        shortWait.on("GET", "/pay/session", .json(429, [:], headers: ["Retry-After": "2"]), .fixture("session-cm-aggregate"))
        let waitClock = ImmediateClock()
        _ = try await client(shortWait, clock: waitClock).session()
        XCTAssertEqual(waitClock.sleeps, [2])

        let longWait = FakeTransport()
        longWait.on("GET", "/pay/session", .json(429, ["retry_after": 300], headers: ["Retry-After": "300"]))
        do {
            _ = try await client(longWait).session()
            XCTFail("a long Retry-After is not waited for")
        } catch let error as WajubError {
            XCTAssertEqual(error.code, WajubError.Code.rateLimited)
            XCTAssertEqual(longWait.requests.count, 1)
        }

        // Backoff: min(1 s × 2^n, 10 s) ± 30 %.
        let jitter = WajubSession(sessionToken: "t", baseURL: WajubSDK.apiURL, transport: transport, clock: clock, device: .test(),
                                  random: { 1 }, language: .en)
        XCTAssertEqual(jitter.backoff(0), 1.3, accuracy: 0.0001)
        XCTAssertEqual(jitter.backoff(5), 13, accuracy: 0.0001)
    }

    /// TR-09 treats an unanswered process as pending
    @MainActor func test_TR_09_treatsAnUnansweredProcessAsPending() async {
        let harness = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        harness.transport.on("POST", "/pay/process", .failure(.timeout))
        harness.transport.on("GET", "/pay/status", .fixture("status-processing"), .fixture("status-succeeded"))
        let controller = await harness.start()
        controller.setPhone("670000000")
        controller.submitMobileMoney()
        await harness.drive(until: "pending") { controller.state == .pending }
        XCTAssertEqual(harness.transport.requests("POST", "/pay/process").count, 3)
        XCTAssertFalse(harness.recorder.states.contains(.failed))
        XCTAssertTrue(harness.recorder.errors.isEmpty)
        await harness.drive(until: "success") { controller.state == .success }
        XCTAssertEqual(harness.transport.requests("GET", "/pay/status").count, 2)
        controller.close()
        XCTAssertEqual(controller.result?.status, "complete")
    }

    /// TR-10 defaults to the production api
    func test_TR_10_defaultsToTheProductionApi() {
        XCTAssertEqual(WajubSDK.apiURL.absoluteString, "https://api.wajub.com")
        XCTAssertEqual(WajubSession(sessionToken: "t").baseURL, WajubSDK.apiURL)
    }
}

extension Harness {
    /// A Mobile Money form on `session-cm-aggregate`, a valid number typed, with these answers.
    static func mobileMoney(locale: String? = nil, answers fixtures: String...) async -> Harness {
        let harness = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        for fixture in fixtures { harness.transport.answer(fixture) }
        let controller = await harness.start { $0.locale = locale }
        controller.setPhone("670000000")
        return harness
    }
}
