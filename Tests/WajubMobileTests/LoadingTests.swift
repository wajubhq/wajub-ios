import XCTest
@testable import WajubMobile

/// LD — loading, ended sessions, restore, readiness and language.
final class LoadingTests: XCTestCase {
    /// LD-01 loads session and sdk-config in parallel
    @MainActor func test_LD_01_loadsSessionAndSdkConfigInParallel() async {
        let harness = Harness()
        let gate = Gate()
        harness.transport.on("GET", "/pay/session", .gated(gate, .fixture("session-cm-aggregate")))
        harness.transport.on("GET", "/pay/sdk-config", .json(500, ["code": 500, "message": "boom"]))
        let controller = harness.makeController { $0.readyTimeout = 0 }
        controller.start()
        await waitUntil("sdk-config requested while the session is pending") {
            !harness.transport.requests("GET", "/pay/sdk-config").isEmpty
        }
        XCTAssertEqual(harness.transport.requests("GET", "/pay/session").count, 1)
        XCTAssertNil(controller.state, "the session has not answered yet")
        // sdk-config fails after its retries; then the session arrives.
        await harness.drive(until: "sdk-config retries done") { harness.transport.requests("GET", "/pay/sdk-config").count == 4 }
        gate.open()
        await waitUntil("ready") { controller.state != nil }
        XCTAssertEqual(controller.methods.map(\.id), ["mobile_money"], "Mobile Money without sdk-config; card hidden")
        XCTAssertEqual(controller.state, .collectingDetails)
        controller.hostGone()
    }

    /// LD-01 loads session and sdk-config in parallel
    @MainActor func test_LD_01_treatsAnUnknownStatusAsPending() async {
        let body = Fixtures.body("session-cm-aggregate").setting(["transaction", "status"], to: "on_hold")
        let harness = Harness(config: "sdk-config-card-kkiapay")
        harness.transport.on("GET", "/pay/session", .json(200, body))
        let controller = await harness.start()
        XCTAssertEqual(controller.state, .initiated)
        XCTAssertEqual(controller.methods.map(\.id), ["card", "mobile_money"], "sdk-config read: card offered")
        controller.hostGone()
    }

    /// LD-02 maps unknown sessions to session_not_found
    @MainActor func test_LD_02_mapsUnknownSessionsToSessionNotFound() async {
        for fixture in ["error-401-invalid-token", "error-401-missing-token", "error-403-not-a-payment-session"] {
            let harness = Harness(session: fixture)
            let controller = await harness.start()
            guard case .loadError(let error) = controller.screen else { return XCTFail(fixture) }
            XCTAssertEqual(error.code, WajubError.Code.sessionNotFound, fixture)
            XCTAssertEqual(error.type, .authenticationError)
            XCTAssertFalse(error.retryable)
            XCTAssertNil(controller.state, "no form")
            XCTAssertTrue(harness.recorder.ready.isEmpty)
            XCTAssertEqual(harness.recorder.loadErrors.map(\.code), [WajubError.Code.sessionNotFound])
            controller.close()
            XCTAssertEqual(controller.result, .failed(error: error, transaction: nil))
        }
    }

    /// LD-03 maps both 410s to session_terminal_expired
    @MainActor func test_LD_03_mapsBoth410sToSessionTerminalExpired() async {
        for fixture in ["error-410-session-terminal-expired", "error-410-session-expired"] {
            let harness = Harness(session: fixture)
            let controller = await harness.start()
            guard case .loadError(let error) = controller.screen else { return XCTFail(fixture) }
            XCTAssertEqual(error.code, WajubError.Code.sessionTerminalExpired, fixture)
            XCTAssertFalse(error.retryable)
            XCTAssertEqual(harness.recorder.loadErrors.first?.code, WajubError.Code.sessionTerminalExpired)
            controller.hostGone()
        }
    }

    /// LD-04 shows an already paid session as success
    @MainActor func test_LD_04_showsAnAlreadyPaidSessionAsSuccess() async {
        let harness = Harness(session: "session-terminal-succeeded")
        let controller = await harness.start()
        guard case .success(let payment) = controller.screen else { return XCTFail("no success screen") }
        XCTAssertEqual(payment.method, "unknown")
        XCTAssertEqual(payment.id, "trx_TerminalSucc0000000000")
        XCTAssertEqual(payment.receiptURL, "https://invoice.wajub.com/r/trx_TerminalSucc0000000000?s=SIGNATURE")
        XCTAssertNil(controller.mobileMoney, "no form")
        XCTAssertTrue(harness.recorder.loadErrors.isEmpty)
        XCTAssertEqual(harness.recorder.events, ["ready", "state:SUCCESS", "success"])
        // The success screen closes itself after 3 s.
        await harness.advance(by: 3)
        XCTAssertEqual(controller.result, .complete(payment: payment, transaction: controller.transaction))
        XCTAssertEqual(harness.recorder.events.last, "complete:complete")
        XCTAssertTrue(harness.transport.requests("GET", "/pay/sdk-config").count <= 1)
    }

    /// LD-05 reports ended sessions with Wajub.js codes
    @MainActor func test_LD_05_reportsEndedSessionsWithWajubJsCodes() async {
        let cases: [(String, CheckoutState, String)] = [
            ("session-terminal-failed", .failed, WajubError.Code.sessionTerminalFailed),
            ("session-terminal-cancelled", .cancelled, WajubError.Code.sessionTerminalCancelled),
            ("session-terminal-cancelled-after-cancel", .cancelled, WajubError.Code.sessionTerminalCancelled),
            ("session-terminal-expired", .expired, WajubError.Code.sessionTerminalExpired),
        ]
        for (fixture, state, code) in cases {
            let harness = Harness(session: fixture)
            let controller = await harness.start()
            XCTAssertEqual(controller.state, state, fixture)
            guard case .ended(let error, _) = controller.screen else { return XCTFail(fixture) }
            XCTAssertEqual(error.code, code)
            XCTAssertNil(controller.mobileMoney)
            XCTAssertEqual(harness.recorder.events, ["ready", "state:\(state.rawValue)", "loadError:\(code)"])
            controller.close()
            XCTAssertEqual(controller.result?.status, "failed")
            XCTAssertTrue(harness.transport.requests("POST", "/pay/cancel").isEmpty)
        }
    }

    /// LD-06 restores a pending approval
    @MainActor func test_LD_06_restoresAPendingApproval() async {
        for fixture in ["session-processing-mobile-money", "session-processing-mobile-money-live"] {
            let harness = Harness(session: fixture)
            harness.transport.answer("status-processing")
            let controller = await harness.start()
            XCTAssertEqual(controller.state, .approvalRequired, fixture)
            guard case .approval(let approval) = controller.screen else { return XCTFail(fixture) }
            XCTAssertEqual(approval.instruction, "Confirm the transaction on your phone. If no prompt appears, dial *126# to complete.")
            await harness.advance(by: 5)
            await waitUntil("watching") { harness.transport.requests("GET", "/pay/status").count == 1 }
            controller.close()
            XCTAssertEqual(controller.result, .processing(transaction: controller.transaction), "a dismiss during approval")
            XCTAssertTrue(harness.transport.requests("POST", "/pay/cancel").isEmpty)
        }
    }

    /// LD-07 offers retry on load failure
    @MainActor func test_LD_07_offersRetryOnLoadFailure() async {
        let harness = Harness()
        harness.transport.on("GET", "/pay/session", .failure(.network("offline")), .failure(.network("offline")),
                             .failure(.network("offline")), .failure(.network("offline")), .fixture("session-cm-aggregate"))
        let controller = harness.makeController { $0.readyTimeout = 0 }
        controller.start()
        await harness.drive(until: "load error") {
            if case .loadError = controller.screen { return true }
            return false
        }
        guard case .loadError(let error) = controller.screen else { return XCTFail("no load error") }
        XCTAssertEqual(error.code, WajubError.Code.loadError)
        XCTAssertTrue(error.retryable, "the error view shows Retry")
        XCTAssertEqual(error.type, .apiError)
        controller.retryLoad()
        await waitUntil("ready after retry") { controller.state == .collectingDetails }
        XCTAssertEqual(harness.transport.requests("GET", "/pay/session").count, 5)
        XCTAssertEqual(harness.recorder.ready.count, 1)
        controller.hostGone()
    }

    /// LD-08 raises ready_timeout
    @MainActor func test_LD_08_raisesReadyTimeout() async {
        let harness = Harness(config: "sdk-config-cm-stripe")
        let gate = Gate()
        harness.transport.on("GET", "/pay/session", .gated(gate, .fixture("session-cm-aggregate")))
        let controller = harness.makeController()
        XCTAssertEqual(controller.options.readyTimeout, 15_000)
        controller.start()
        await harness.advance(by: 15)
        guard case .loadError(let error) = controller.screen else { return XCTFail("no ready_timeout") }
        XCTAssertEqual(error.code, WajubError.Code.readyTimeout)
        XCTAssertEqual(error.type, .apiError)
        XCTAssertTrue(error.retryable)
        XCTAssertEqual(error.apiMessage, "Payment sheet not ready after 15000 ms")
        XCTAssertEqual(harness.recorder.loadErrors.map(\.code), [WajubError.Code.readyTimeout])
        // The data arrives while the error view shows: the sheet becomes ready.
        gate.open()
        await waitUntil("ready") { controller.state == .collectingDetails }
        XCTAssertEqual(harness.recorder.events.prefix(3), ["loadError:ready_timeout", "ready", "state:COLLECTING_DETAILS"])
        controller.hostGone()
    }

    /// LD-09 resolves the sheet language
    @MainActor func test_LD_09_resolvesTheSheetLanguage() async {
        XCTAssertEqual(WajubLanguage.resolve(option: "fr", session: "en", device: "en-US"), .fr)
        XCTAssertEqual(WajubLanguage.resolve(option: nil, session: "fr", device: "en-US"), .fr)
        XCTAssertEqual(WajubLanguage.resolve(option: nil, session: nil, device: "fr-SN"), .fr)
        XCTAssertEqual(WajubLanguage.resolve(option: nil, session: nil, device: "en-NG"), .en)
        XCTAssertEqual(WajubLanguage.resolve(option: "de", session: "fr", device: "fr-CM"), .en, "only fr and en")
        XCTAssertEqual(WajubLanguage.resolve(option: nil, session: nil, device: "pt-BR"), .en)

        let french = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        french.device = .test(languages: ["en-US"])
        let sessionLanguage = await french.start().language
        XCTAssertEqual(sessionLanguage, .fr, "the session's locale")
        french.controller.hostGone()

        let device = Harness(session: "session-ci-xof-wallets", config: "sdk-config-ci-wallets")
        device.device = .test(languages: ["en-US"])
        let deviceLanguage = await device.start().language
        XCTAssertEqual(deviceLanguage, .en, "no session locale: the device's")
        device.controller.hostGone()

        let option = Harness(session: "session-ci-xof-wallets", config: "sdk-config-ci-wallets")
        let optionLanguage = await option.start { $0.locale = "en" }.language
        XCTAssertEqual(optionLanguage, .en, "the option first")
        option.controller.hostGone()
    }
}
