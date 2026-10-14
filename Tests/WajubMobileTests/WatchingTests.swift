import XCTest
@testable import WajubMobile

/// WT — polling, realtime and the decisions they lead to.
final class WatchingTests: XCTestCase {
    /// WT-01 polls on schedule
    func test_WT_01_pollsOnSchedule() {
        let start = Date(timeIntervalSince1970: 1_791_968_400)
        var schedule = PollSchedule(start: start, random: { 0.5 })
        var now = start
        var delays: [TimeInterval] = []
        // 5 s while the status keeps changing… then unchanged for 2 minutes: ×1.5 per poll up to 15 s.
        schedule.recordStatus(.processing, now: now)
        while now.timeIntervalSince(start) < 200 {
            let delay = schedule.nextDelay(now: now, socketConnected: false)
            delays.append(delay)
            now = now.addingTimeInterval(delay)
            schedule.recordStatus(.processing, now: now)
        }
        XCTAssertEqual(Array(delays.prefix(24)), Array(repeating: 5, count: 24))
        XCTAssertEqual(Array(delays.dropFirst(24).prefix(4)), [7.5, 11.25, 15, 15])
        // A change resets to 5 s.
        schedule.recordStatus(.pending, now: now)
        XCTAssertEqual(schedule.nextDelay(now: now, socketConnected: false), 5)
        // With the socket connected: 15 s.
        XCTAssertEqual(schedule.nextDelay(now: now, socketConnected: true), 15)
        // Errors: min(5 s × 2^n, 60 s), n = consecutive failures, reset on success.
        var errors: [TimeInterval] = []
        for _ in 0..<5 {
            schedule.recordError()
            errors.append(schedule.nextDelay(now: now, socketConnected: false))
        }
        XCTAssertEqual(errors, [10, 20, 40, 60, 60])
        schedule.recordStatus(.processing, now: now)
        XCTAssertEqual(schedule.nextDelay(now: now, socketConnected: false), 5)
        // ± 20 % jitter on the error backoff.
        var jittered = PollSchedule(start: start, random: { 1 })
        jittered.recordError()
        XCTAssertEqual(jittered.nextDelay(now: start, socketConnected: false), 12, accuracy: 0.0001)
        // A 429 waits its Retry-After.
        schedule.recordRateLimit(retryAfter: 42)
        XCTAssertEqual(schedule.nextDelay(now: now, socketConnected: false), 42)
    }

    /// WT-01 polls on schedule
    @MainActor func test_WT_01_capsTheWatchAndResolvesProcessing() async {
        let harness = await Harness.mobileMoney(answers: "process-processing-mobile-money-live", "status-processing")
        harness.controller.submitMobileMoney()
        await waitUntil("approval") { harness.controller.state == .approvalRequired }
        await harness.drive(until: "cap", maxSteps: 200) {
            if case .pending(let pending) = harness.controller.screen { return pending.capReached }
            return false
        }
        let elapsed = harness.clock.now.timeIntervalSince(Date(timeIntervalSince1970: 1_791_968_400))
        XCTAssertGreaterThanOrEqual(elapsed, 900)
        XCTAssertLessThan(elapsed, 900 + 16)
        let polls = harness.transport.requests("GET", "/pay/status").count
        await harness.clock.advance(by: 120)
        XCTAssertEqual(harness.transport.requests("GET", "/pay/status").count, polls, "stopped at the cap")
        XCTAssertEqual(harness.controller.strings.pendingCapBody, "Paiement en cours — vous serez notifié.")
        // Back in the app after the cap: one look at the status.
        harness.controller.appWillEnterForeground()
        await waitUntil("checked once") { harness.transport.requests("GET", "/pay/status").count == polls + 1 }
        harness.controller.close()
        XCTAssertEqual(harness.controller.result?.status, "processing")
    }

    @MainActor private func approving(_ status: [FakeTransport.Reply], process: String = "process-processing-mobile-money-sandbox") async -> Harness {
        let harness = await Harness.mobileMoney(answers: process)
        harness.transport.on("GET", "/pay/status", replies: status)
        harness.controller.submitMobileMoney()
        await waitUntil("approval") { harness.controller.state == .approvalRequired }
        return harness
    }

    /// WT-02 decides on status
    @MainActor func test_WT_02_decidesOnStatus() async {
        let paid = await approving([.fixture("status-succeeded")])
        await paid.advance(by: 5)
        XCTAssertEqual(paid.controller.state, .success)
        paid.controller.hostGone()

        for fixture in ["status-pending-attempt-refused", "status-pending-attempt-refused-live"] {
            let refused = await approving([.fixture(fixture)])
            await refused.advance(by: 5)
            guard case .failed(let error) = refused.controller.screen else { return XCTFail(fixture) }
            XCTAssertEqual(error.code, "insufficient_funds")
            XCTAssertEqual(error.declineCode, "insufficient_funds")
            XCTAssertTrue(error.retryable)
            XCTAssertEqual(error.apiMessage, "This payment could not be completed. Try again or use another payment method.")
            refused.controller.hostGone()
        }

        let failed = await approving([.json(200, ["transaction": ["reference": "trx", "status": "failed"]])])
        await failed.advance(by: 5)
        guard case .failed(let failure) = failed.controller.screen else { return XCTFail("failed") }
        XCTAssertEqual(failure.code, WajubError.Code.paymentFailed)
        XCTAssertFalse(failure.retryable)
        failed.controller.hostGone()

        let cancelled = await approving([.json(200, ["transaction": ["reference": "trx", "status": "cancelled"]])])
        await cancelled.advance(by: 5)
        XCTAssertEqual(cancelled.controller.state, .cancelled)
        XCTAssertEqual(cancelled.recorder.errors.map(\.code), [WajubError.Code.paymentCancelled])
        cancelled.controller.close()
        guard case .failed(let error, _)? = cancelled.controller.result else { return XCTFail("cancelled status resolves failed") }
        XCTAssertEqual(error.code, WajubError.Code.paymentCancelled)

        let expired = await approving([.json(200, ["transaction": ["reference": "trx", "status": "expired"]])])
        await expired.advance(by: 5)
        guard case .expired(let expiry) = expired.controller.screen else { return XCTFail("expired") }
        XCTAssertEqual(expiry.code, WajubError.Code.sessionExpired)
        expired.controller.hostGone()

        let gone = await approving([.fixture("error-410-session-terminal-expired")])
        await gone.advance(by: 5)
        guard case .expired(let goneError) = gone.controller.screen else { return XCTFail("410") }
        XCTAssertEqual(goneError.code, WajubError.Code.sessionTerminalExpired)
        gone.controller.hostGone()

        let unknown = await approving([.fixture("error-401-invalid-token")])
        await unknown.advance(by: 5)
        guard case .failed(let unknownError) = unknown.controller.screen else { return XCTFail("401") }
        XCTAssertEqual(unknownError.code, WajubError.Code.sessionNotFound)
        unknown.controller.hostGone()

        // A `pending` before this attempt was seen processing is the previous attempt's leftover.
        let leftover = await Harness.mobileMoney(answers: "process-409-payment-in-progress")
        leftover.transport.on("GET", "/pay/status", .fixture("status-pending-attempt-refused"), .fixture("status-processing"),
                              .json(200, ["transaction": ["reference": "trx", "status": "pending"]]))
        leftover.controller.submitMobileMoney()
        await waitUntil("pending") { leftover.controller.state == .pending }
        await leftover.advance(by: 5)
        XCTAssertEqual(leftover.controller.state, .pending, "ignored")
        await leftover.advance(by: 5)
        XCTAssertEqual(leftover.controller.state, .pending, "processing: continue")
        await leftover.advance(by: 5)
        guard case .failed(let ended) = leftover.controller.screen else { return XCTFail("attempt ended") }
        XCTAssertEqual(ended.code, WajubError.Code.paymentAttemptEnded)
        XCTAssertTrue(ended.retryable)
        leftover.controller.hostGone()
    }

    /// WT-02 decides on status
    @MainActor func test_WT_02_readsAnEmptyAnswerAsNoInformation() async {
        // An empty /pay/status, then a realtime frame without a status, say nothing: keep watching.
        let harness = await approving([.json(200, [:]), .json(200, ["transaction": [:]]), .fixture("status-succeeded")],
                                      process: "process-processing-mobile-money-live")
        harness.transport.answer("broadcasting-auth-200")
        await harness.advance(by: 5)
        await harness.advance(by: 5)
        XCTAssertEqual(harness.controller.state, .approvalRequired, "never read as pending, never a failure")
        XCTAssertTrue(harness.recorder.errors.isEmpty)
        await waitUntil("socket") { harness.sockets.count == 1 }
        let socket = harness.sockets[0]
        socket.push(["event": "pusher:connection_established", "data": .string("{\"socket_id\":\"1.2\"}")])
        await waitUntil("subscribed") { socket.sentFrames.contains { $0["event"]?.string == "pusher:subscribe" } }
        socket.push(["event": "PaymentStatusUpdated", "channel": "private-payment.trx_PVrU8x2kQ1mNa7Lb3cDe",
                     "data": .string("{\"status_label\":\"Pending\",\"error_code\":\"insufficient_funds\"}")])
        await settle()
        XCTAssertEqual(harness.controller.state, .approvalRequired)
        await harness.advance(by: 15)
        XCTAssertEqual(harness.controller.state, .success)
        harness.controller.hostGone()
    }

    /// WT-03 subscribes to the payment channel
    @MainActor func test_WT_03_subscribesToThePaymentChannel() async throws {
        let harness = await approving([.fixture("status-processing")], process: "process-processing-mobile-money-live")
        harness.transport.answer("broadcasting-auth-200")
        await waitUntil("socket") { harness.sockets.count == 1 }
        let socket = harness.sockets[0]
        XCTAssertEqual(socket.url.absoluteString,
                       "wss://ws.wajub.com:443/app/wajub-app-key?protocol=7&client=wajub-ios&version=1.0.0&flash=false")
        socket.push(["event": "pusher:connection_established", "data": .string("{\"socket_id\":\"123456.7890123\",\"activity_timeout\":120}")])
        await waitUntil("subscribed") { socket.sentFrames.contains { $0["event"]?.string == "pusher:subscribe" } }
        let auth = try XCTUnwrap(harness.transport.requests("POST", "/pay/broadcasting/auth").first)
        XCTAssertEqual(auth.json, ["socket_id": "123456.7890123", "channel_name": "private-payment.trx_PVrU8x2kQ1mNa7Lb3cDe"])
        XCTAssertEqual(auth.header("Authorization"), "Bearer test_token")
        let subscribe = try XCTUnwrap(socket.sentFrames.first { $0["event"]?.string == "pusher:subscribe" })
        XCTAssertEqual(subscribe["data"], ["auth": "wajub-app-key:SIGNATURE", "channel": "private-payment.trx_PVrU8x2kQ1mNa7Lb3cDe"])
        socket.push(["event": "pusher_internal:subscription_succeeded", "channel": "private-payment.trx_PVrU8x2kQ1mNa7Lb3cDe", "data": "{}"])
        await settle()
        // Connected: polling slows to 15 s.
        await harness.advance(by: 15)
        XCTAssertTrue(harness.clock.sleeps.contains(15))
        socket.push(["event": "pusher:ping", "data": "{}"])
        await waitUntil("pong") { socket.sentFrames.contains { $0["event"]?.string == "pusher:pong" } }
        socket.push(["event": "PaymentStatusUpdated", "channel": "private-payment.trx_PVrU8x2kQ1mNa7Lb3cDe",
                     "data": .string(Fixtures.body("realtime-payment-status-updated-succeeded").jsonString)])
        await waitUntil("success from the socket") { harness.controller.state == .success }
        await waitUntil("socket closed") { socket.isClosed }
        harness.controller.hostGone()

        // Hosted Pusher, and an override.
        let session = Fixtures.session("session-ci-xof-wallets")
        let pusher = try XCTUnwrap(RealtimeEndpoint(echo: session.echo, override: nil, transactionId: session.transaction.id))
        XCTAssertEqual(pusher.url?.absoluteString,
                       "wss://ws-eu.pusher.com:443/app/pusher-app-key?protocol=7&client=wajub-ios&version=1.0.0&flash=false")
        let reverb = Fixtures.session("session-cm-aggregate")
        let custom = try XCTUnwrap(RealtimeEndpoint(echo: reverb.echo, override: RealtimeOptions(host: "reverb.shop.example", port: 8080, tls: false),
                                                    transactionId: reverb.transaction.id))
        XCTAssertEqual(custom.url?.absoluteString,
                       "ws://reverb.shop.example:8080/app/wajub-app-key?protocol=7&client=wajub-ios&version=1.0.0&flash=false")
        XCTAssertEqual(custom.channel, "private-payment.trx_PVrU8x2kQ1mNa7Lb3cDe")
    }

    /// WT-04 falls back to polling
    @MainActor func test_WT_04_fallsBackToPolling() async {
        let sandbox = Fixtures.session("session-sandbox-cm")
        XCTAssertNil(RealtimeEndpoint(echo: sandbox.echo, override: nil, transactionId: sandbox.transaction.id), "key: null")
        XCTAssertNil(RealtimeEndpoint(echo: nil, override: nil, transactionId: "trx"), "no echo")
        let live = Fixtures.session("session-cm-aggregate")
        XCTAssertNil(RealtimeEndpoint(echo: live.echo, override: RealtimeOptions(enabled: false), transactionId: live.transaction.id))

        let harness = Harness(session: "session-sandbox-cm")
        harness.transport.answer("process-processing-mobile-money-sandbox", "status-processing")
        let controller = await harness.start()
        controller.selectMethod("mobile_money")
        controller.setPhone("670000000")
        controller.submitMobileMoney()
        await waitUntil("approval") { controller.state == .approvalRequired }
        await harness.advance(by: 5)
        await harness.advance(by: 5)
        XCTAssertTrue(harness.sockets.isEmpty)
        XCTAssertEqual(harness.transport.requests("GET", "/pay/status").count, 2, "every 5 s")
        controller.hostGone()

        // A socket that never connects: polling stays at 5 s.
        let silent = await approving([.fixture("status-processing")], process: "process-processing-mobile-money-live")
        await waitUntil("socket") { silent.sockets.count == 1 }
        for _ in 0..<3 { await silent.advance(by: 5) }
        XCTAssertEqual(silent.transport.requests("GET", "/pay/status").count, 3)
        silent.controller.hostGone()
    }

    /// WT-05 decides on realtime events
    @MainActor func test_WT_05_decidesOnRealtimeEvents() async {
        let cases: [(String, CheckoutState)] = [
            ("realtime-payment-status-updated-succeeded", .success),
            ("realtime-payment-status-updated-failed", .failed),
            ("realtime-payment-status-updated-refused", .failed),
            ("realtime-payment-status-updated-processing", .approvalRequired),
        ]
        for (fixture, state) in cases {
            for asString in [true, false] {
                let harness = await approving([.fixture("status-processing")], process: "process-processing-mobile-money-live")
                harness.transport.answer("broadcasting-auth-200")
                await waitUntil("socket") { harness.sockets.count == 1 }
                let socket = harness.sockets[0]
                socket.push(["event": "pusher:connection_established", "data": .string("{\"socket_id\":\"1.2\"}")])
                await waitUntil("subscribed") { socket.sentFrames.contains { $0["event"]?.string == "pusher:subscribe" } }
                let data = Fixtures.body(fixture)
                socket.push(["event": "PaymentStatusUpdated", "channel": "private-payment.trx_PVrU8x2kQ1mNa7Lb3cDe",
                             "data": asString ? .string(data.jsonString) : data])
                await settle()
                XCTAssertEqual(harness.controller.state, state, "\(fixture) as \(asString ? "a string" : "an object")")
                if fixture.hasSuffix("refused"), case .failed(let error) = harness.controller.screen {
                    XCTAssertEqual(error.code, "insufficient_funds")
                }
                harness.controller.hostGone()
            }
        }
        // An event on another channel is ignored.
        let other = await approving([.fixture("status-processing")], process: "process-processing-mobile-money-live")
        other.transport.answer("broadcasting-auth-200")
        await waitUntil("socket") { other.sockets.count == 1 }
        other.sockets[0].push(["event": "PaymentStatusUpdated", "channel": "private-payment.trx_SomeoneElse",
                               "data": Fixtures.body("realtime-payment-status-updated-succeeded")])
        await settle()
        XCTAssertEqual(other.controller.state, .approvalRequired)
        other.controller.hostGone()
    }

    /// WT-06 stops watching on close
    @MainActor func test_WT_06_stopsWatchingOnClose() async {
        for close in ["dismiss", "hostGone"] {
            let harness = await approving([.fixture("status-processing")], process: "process-processing-mobile-money-live")
            await waitUntil("socket") { harness.sockets.count == 1 }
            await harness.advance(by: 5)
            let polls = harness.transport.requests("GET", "/pay/status").count
            XCTAssertEqual(polls, 1)
            if close == "dismiss" { harness.controller.dismiss() } else { harness.controller.hostGone() }
            XCTAssertEqual(harness.controller.result?.status, "processing")
            await harness.clock.advance(by: 120)
            await settle()
            XCTAssertEqual(harness.transport.requests("GET", "/pay/status").count, polls, close)
            XCTAssertTrue(harness.sockets[0].isClosed, close)
            XCTAssertEqual(harness.clock.sleeperCount, 0, "nothing left running")
        }
    }
}
