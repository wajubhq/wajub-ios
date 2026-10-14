import XCTest
@testable import WajubMobile

/// CF — payer confirmation steps and the sandbox 3-D Secure code; CS — client sessions.
final class ConfirmationTests: XCTestCase {
    /// A Paystack-like card payment whose `/pay/process` answers `fixture`.
    @MainActor private func stepHarness(_ fixture: String) async -> Harness {
        let harness = Harness(session: "session-cm-aggregate", config: "sdk-config-card-kkiapay")
        harness.transport.answer(fixture, "status-processing")
        let controller = await harness.start()
        controller.selectMethod("card")
        controller.submitCard()
        return harness
    }

    private static let steps: [(fixture: String, kind: ConfirmStepKind, state: CheckoutState, fields: [String: String])] = [
        ("process-requires-otp", .otp, .otpRequired, ["code": "123456"]),
        ("process-requires-pin", .pin, .pinRequired, ["pin": "1234"]),
        ("process-requires-phone", .phone, .phoneRequired, ["phone": "08012345678"]),
        ("process-requires-birthday", .birthday, .birthdayRequired, ["birthday": "1990-04-21"]),
        ("process-requires-address", .address, .addressRequired,
         ["address": "12 Admiralty Way", "city": "Lagos", "state": "Lagos", "zip_code": "101233"]),
    ]

    /// CF-01 opens each confirmation step
    @MainActor func test_CF_01_opensEachConfirmationStep() async throws {
        for step in ConfirmationTests.steps {
            let harness = await stepHarness(step.fixture)
            let controller = harness.controller!
            await waitUntil("\(step.kind) screen") { controller.state == step.state }
            guard case .step(let screen) = controller.screen else { return XCTFail(step.fixture) }
            XCTAssertEqual(screen.kind, step.kind)
            XCTAssertEqual(screen.id, "prc_7hQm2LxV9pR4sT1wYb3N")
            XCTAssertEqual(screen.hint, Fixtures.body(step.fixture)[step.kind == .otp ? "otp_masked_contact" : "\(step.kind.rawValue)_instruction"]?.string)
            harness.transport.on("POST", "/pay/\(step.kind.rawValue)/verify", .fixture("otp-verify-success"))
            controller.submitStep(step.fields)
            XCTAssertEqual(controller.state, .verifying)
            await waitUntil("verified") { controller.state == .pending }
            let request = try XCTUnwrap(harness.transport.requests("POST", "/pay/\(step.kind.rawValue)/verify").first)
            var expected = step.fields.mapValues(JSONValue.string)
            expected[step.kind.idKey] = "prc_7hQm2LxV9pR4sT1wYb3N"
            XCTAssertEqual(request.json, .object(expected))
            controller.hostGone()
        }
    }

    /// CF-02 reads the transaction after a step
    @MainActor func test_CF_02_readsTheTransactionAfterAStep() async {
        let successes = ["otp-verify-success", "pin-verify-success", "phone-verify-success", "birthday-verify-success", "address-verify-success"]
        for (step, success) in zip(ConfirmationTests.steps, successes) {
            let harness = await stepHarness(step.fixture)
            harness.transport.answer(success, "status-processing")
            await waitUntil("step") { harness.controller.state == step.state }
            harness.controller.submitStep(step.fields)
            await waitUntil("pending: the transaction is still processing") { harness.controller.state == .pending }
            await harness.advance(by: 5)
            XCTAssertFalse(harness.transport.requests("GET", "/pay/status").isEmpty, "watching")
            harness.controller.hostGone()
        }
        let paid = Fixtures.body("otp-verify-success").setting(["transaction", "status"], to: "succeeded")
        let harness = await stepHarness("process-requires-otp")
        harness.transport.on("POST", "/pay/otp/verify", .json(200, paid))
        await waitUntil("otp") { harness.controller.state == .otpRequired }
        harness.controller.submitStep(["code": "123456"])
        await waitUntil("success") { harness.controller.state == .success }
        harness.controller.hostGone()
    }

    /// CF-03 handles step refusals
    @MainActor func test_CF_03_handlesStepRefusals() async {
        for (fixture, verify, step) in [("otp-verify-invalid", "otp", ConfirmationTests.steps[0]), ("pin-verify-invalid", "pin", ConfirmationTests.steps[1])] {
            let harness = await stepHarness(step.fixture)
            harness.transport.answer(fixture)
            await waitUntil("step") { harness.controller.state == step.state }
            harness.controller.submitStep(step.fields)
            await waitUntil("back on the step") { harness.controller.state == step.state && !harness.transport.requests("POST", "/pay/\(verify)/verify").isEmpty }
            guard case .step(let screen) = harness.controller.screen else { return XCTFail(fixture) }
            XCTAssertEqual(screen.attemptsRemaining, 2)
            XCTAssertEqual(screen.error?.code, "invalid_\(verify)")
            XCTAssertEqual(screen.error?.message, verify == "otp" ? "Code incorrect. Encore 2 essais." : "Code PIN incorrect. Encore 2 essais.")
            harness.controller.hostGone()
        }
        for (fixture, code) in [("otp-verify-max-attempts", WajubError.Code.maxAttemptsExceeded), ("otp-verify-expired", WajubError.Code.otpExpired)] {
            let harness = await stepHarness("process-requires-otp")
            harness.transport.answer(fixture)
            await waitUntil("otp") { harness.controller.state == .otpRequired }
            harness.controller.submitStep(["code": "123456"])
            await waitUntil("failed") { harness.controller.state == .failed }
            guard case .failed(let error) = harness.controller.screen else { return XCTFail(fixture) }
            XCTAssertEqual(error.code, code)
            XCTAssertTrue(error.retryable, "back to the methods")
            harness.controller.tryAgain()
            XCTAssertEqual(harness.controller.state, .initiated, "the payer starts again from the method list")
            harness.controller.hostGone()
        }
    }

    /// CF-04 shows step validation errors
    @MainActor func test_CF_04_showsStepValidationErrors() async {
        let address = await stepHarness("process-requires-address")
        address.transport.answer("address-verify-422-missing-fields")
        await waitUntil("address") { address.controller.state == .addressRequired }
        address.controller.submitStep(["address": "12 Admiralty Way", "city": "-", "state": "-", "zip_code": "-"])
        await waitUntil("errors") { !address.controller.fieldErrors.isEmpty }
        XCTAssertEqual(Set(address.controller.fieldErrors.keys), ["city", "state", "zip_code"])
        XCTAssertEqual(address.controller.state, .addressRequired)
        address.controller.hostGone()

        let birthday = await stepHarness("process-requires-birthday")
        birthday.transport.answer("birthday-verify-422-format")
        await waitUntil("birthday") { birthday.controller.state == .birthdayRequired }
        birthday.controller.submitStep(["birthday": "21/04/1990"])
        XCTAssertEqual(birthday.controller.fieldErrors["birthday"]?.code, WajubError.Code.validationError, "checked before sending")
        XCTAssertTrue(birthday.transport.requests("POST", "/pay/birthday/verify").isEmpty)
        birthday.controller.submitStep(["birthday": "1990-04-21"])
        await waitUntil("server errors") { birthday.controller.fieldErrors["birthday"]?.httpStatus == 422 }
        XCTAssertEqual(birthday.controller.state, .birthdayRequired)
        birthday.controller.hostGone()
    }

    /// CF-05 resends after the countdown
    @MainActor func test_CF_05_resendsAfterTheCountdown() async throws {
        let harness = await stepHarness("process-requires-otp")
        harness.transport.answer("otp-resend-200")
        await waitUntil("otp") { harness.controller.state == .otpRequired }
        harness.controller.resendStepCode()
        await settle()
        XCTAssertTrue(harness.transport.requests("POST", "/pay/otp/resend").isEmpty, "not before 60 s")
        await harness.clock.advance(by: 60)
        harness.controller.resendStepCode()
        await waitUntil("resent") { harness.transport.requests("POST", "/pay/otp/resend").count == 1 }
        XCTAssertEqual(harness.transport.requests("POST", "/pay/otp/resend")[0].json, ["otp_id": "prc_7hQm2LxV9pR4sT1wYb3N"])
        guard case .step(let screen) = harness.controller.screen else { return XCTFail("left the step") }
        XCTAssertEqual(screen.resendAvailableAt, harness.clock.now.addingTimeInterval(60), "the countdown restarts")
        harness.controller.hostGone()
    }

    /// CF-06 handles the sandbox 3ds code
    @MainActor func test_CF_06_handlesTheSandbox3dsCode() async throws {
        func threeDS() async -> Harness {
            let harness = Harness(session: "session-sandbox-cm")
            harness.transport.answer("process-requires-3ds-sandbox", "status-processing")
            let controller = await harness.start()
            controller.selectMethod("card")
            for (field, value) in ["card.number": "4000056655665556", "card_holder": "Awa Ngono", "expiry_month": "12", "expiry_year": "30", "cvv": "123"] {
                controller.setCardField(field, value)
            }
            controller.submitCard()
            await waitUntil("3DS") { controller.state == .threeDSRequired }
            return harness
        }

        // A wrong code answered 500 (today's API bug) or 422 retryable: same screen.
        for fixture in ["3ds-verify-500-invalid-code-api-bug", "3ds-verify-422-invalid-code"] {
            let harness = await threeDS()
            harness.transport.answer(fixture)
            harness.controller.submitThreeDSCode("000000")
            await waitUntil("wrong code") {
                if case .threeDS(let screen) = harness.controller.screen { return screen.error != nil }
                return false
            }
            guard case .threeDS(let screen) = harness.controller.screen else { return XCTFail(fixture) }
            XCTAssertEqual(screen.error?.code, WajubError.Code.invalidCode)
            XCTAssertEqual(harness.controller.state, .threeDSRequired)
            harness.controller.hostGone()
        }

        // Accepted: VERIFYING, then the status decides.
        let accepted = await threeDS()
        accepted.transport.answer("3ds-verify-202", "status-succeeded")
        accepted.controller.submitThreeDSCode("123456")
        await waitUntil("verifying") { accepted.recorder.states.contains(.verifying) }
        await waitUntil("success") { accepted.controller.state == .success }
        let verify = try XCTUnwrap(accepted.transport.requests("POST", "/pay/3ds/verify").first)
        XCTAssertEqual(verify.json, ["three_ds_id": "5f0c2b1e-8d4a-4c3b-9e7f-1a2b3c4d5e6f", "code": "123456"])
        accepted.controller.hostGone()

        // A refusal that is not retryable ends the attempt.
        let refused = await threeDS()
        let rejected = Fixtures.body("3ds-verify-422-invalid-code").setting(["error"], to: ["code": "3ds_rejected", "message": "No", "retryable": false])
        refused.transport.on("POST", "/pay/3ds/verify", .json(422, rejected))
        refused.controller.submitThreeDSCode("123456")
        await waitUntil("failed") { refused.controller.state == .failed }
        guard case .failed(let error) = refused.controller.screen else { return XCTFail("not failed") }
        XCTAssertEqual(error.code, WajubError.Code.threeDSRejected)
        refused.controller.hostGone()

        // A new code, then the timeout.
        let timeout = await threeDS()
        timeout.transport.answer("3ds-send-200")
        await timeout.clock.advance(by: 60)
        timeout.controller.resendThreeDSCode()
        await waitUntil("sent") { timeout.transport.requests("POST", "/pay/3ds/send").count == 1 }
        XCTAssertEqual(timeout.transport.requests("POST", "/pay/3ds/send")[0].json, ["three_ds_id": "5f0c2b1e-8d4a-4c3b-9e7f-1a2b3c4d5e6f"])
        timeout.transport.on("GET", "/pay/status", .fixture("status-processing"))
        await timeout.drive(until: "3ds_timeout") { timeout.controller.state == .failed }
        guard case .failed(let expired) = timeout.controller.screen else { return XCTFail("no timeout") }
        XCTAssertEqual(expired.code, WajubError.Code.threeDSTimeout)
        XCTAssertGreaterThanOrEqual(timeout.clock.now.timeIntervalSince(Date(timeIntervalSince1970: 1_791_968_400)), 600)
        timeout.controller.hostGone()
    }

    // MARK: Client sessions

    @MainActor private func clientSession(_ start: String, config: String = "sdk-config-card-paystack") async -> Harness {
        let harness = Harness(session: "session-cm-aggregate", config: config)
        harness.transport.answer(start, "status-processing")
        let controller = await harness.start()
        controller.selectMethod("card")
        controller.submitCard()
        return harness
    }

    /// CS-01 opens a client session
    @MainActor func test_CS_01_opensAClientSession() async throws {
        for fixture in ["client-session-start-202", "client-session-start-202-flutterwave", "client-session-start-reserved"] {
            let harness = await clientSession(fixture)
            await waitUntil("pending") { harness.controller.state == .pending && !harness.browser.opened.isEmpty }
            let request = try XCTUnwrap(harness.transport.requests("POST", "/pay/client-session").first?.json)
            XCTAssertEqual(request, ["channel": "card", "email": "awa.ngono@example.com"], "never inline")
            let url = Fixtures.body(fixture)["client_session"]?["hosted_url"]?.string
            XCTAssertEqual(harness.recorder.redirects, [url].compactMap { $0 })
            XCTAssertEqual(harness.browser.opened.first?.url.absoluteString, url)
            XCTAssertEqual(harness.browser.opened.first?.mode, .inApp)
            XCTAssertEqual(harness.recorder.started, [PaymentStartedEvent(method: "card", channel: "card")])
            await harness.advance(by: 5)
            XCTAssertFalse(harness.transport.requests("GET", "/pay/status").isEmpty, "watching")
            harness.controller.hostGone()
        }
    }

    /// CS-02 completes a client session
    @MainActor func test_CS_02_completesAClientSession() async throws {
        let paid = await clientSession("client-session-start-202")
        paid.transport.answer("client-session-complete-200")
        await waitUntil("browser") { !paid.browser.opened.isEmpty }
        paid.browser.close()
        await waitUntil("success") { paid.controller.state == .success }
        XCTAssertEqual(paid.transport.requests("POST", "/pay/client-session/complete").first?.json,
                       ["client_session_id": "prc_7hQm2LxV9pR4sT1wYb3N"])
        paid.controller.hostGone()

        let waiting = await clientSession("client-session-start-202")
        waiting.transport.answer("client-session-complete-202", "status-processing")
        await waitUntil("browser") { !waiting.browser.opened.isEmpty }
        waiting.browser.close()
        await waitUntil("polled") { !waiting.transport.requests("GET", "/pay/status").isEmpty }
        XCTAssertEqual(waiting.controller.state, .pending)
        waiting.controller.hostGone()

        for (fixture, code) in [("client-session-complete-402", "failed"), ("client-session-complete-422-expired", WajubError.Code.clientSessionExpired)] {
            let harness = await clientSession("client-session-start-202")
            harness.transport.answer(fixture)
            await waitUntil("browser") { !harness.browser.opened.isEmpty }
            harness.browser.close()
            await waitUntil("failed") { harness.controller.state == .failed }
            guard case .failed(let error) = harness.controller.screen else { return XCTFail(fixture) }
            XCTAssertEqual(error.code, code)
            XCTAssertTrue(error.retryable)
            // Starting again replaces the dead session.
            harness.controller.tryAgain()
            harness.controller.submitCard()
            await waitUntil("restarted") { harness.transport.requests("POST", "/pay/client-session").count == 2 }
            XCTAssertEqual(harness.transport.requests("POST", "/pay/client-session")[1].json?["restart"], true)
            harness.controller.hostGone()
        }
    }

    /// CS-02 completes a client session
    @MainActor func test_CS_02_waitsForThePageToCloseBeforeCompleting() async throws {
        // The payer leaves for their bank's app while the provider page is still open in the sheet.
        let harness = await clientSession("client-session-start-202")
        await waitUntil("browser") { !harness.browser.opened.isEmpty }
        harness.transport.on("GET", "/pay/status", .fixture("status-pending-attempt-refused"), .fixture("status-succeeded"))
        harness.transport.answer("client-session-complete-402")
        harness.controller.appWillEnterForeground()
        await waitUntil("polled") { harness.transport.requests("GET", "/pay/status").count == 1 }
        XCTAssertTrue(harness.transport.requests("POST", "/pay/client-session/complete").isEmpty, "never while the page is in front")
        XCTAssertEqual(harness.controller.state, .pending, "a refused try on the open page is not the end")
        await harness.advance(by: 5)
        XCTAssertEqual(harness.controller.state, .success, "the payment made on the page wins")
        harness.controller.hostGone()

        // The page closed: /complete is on its way when a poll still reads the refused try (the API has
        // not verified the session yet). The provider's verdict decides, and the payment wins.
        let verifying = await clientSession("client-session-start-202")
        verifying.transport.on("GET", "/pay/status", .fixture("status-pending-attempt-refused"))
        let completeGate = Gate()
        verifying.transport.on("POST", "/pay/client-session/complete", .gated(completeGate, .fixture("client-session-complete-200")))
        await waitUntil("browser") { !verifying.browser.opened.isEmpty }
        verifying.browser.close()
        await waitUntil("complete sent") { verifying.transport.requests("POST", "/pay/client-session/complete").count == 1 }
        await verifying.advance(by: 5)
        XCTAssertEqual(verifying.controller.state, .pending, "a refused try seen by the watch is not the verdict")
        XCTAssertTrue(verifying.recorder.errors.isEmpty)
        completeGate.open()
        await waitUntil("paid") { verifying.controller.state == .success }
        XCTAssertEqual(verifying.recorder.successes.count, 1)
        verifying.controller.close()
        XCTAssertEqual(verifying.controller.result?.status, "complete")

        // Every return from the browser completes, while the session is open.
        let returns = await clientSession("client-session-start-202")
        returns.transport.answer("client-session-complete-202")
        await waitUntil("browser") { !returns.browser.opened.isEmpty }
        returns.browser.close()
        await waitUntil("completed") { returns.transport.requests("POST", "/pay/client-session/complete").count == 1 }
        returns.controller.continuePayment()
        await waitUntil("reopened") { returns.browser.opened.count == 2 }
        returns.browser.close()
        await waitUntil("completed again") { returns.transport.requests("POST", "/pay/client-session/complete").count == 2 }
        XCTAssertEqual(returns.controller.state, .pending)

        // A failure leaves nothing to continue.
        returns.transport.answer("client-session-complete-402")
        returns.controller.continuePayment()
        await waitUntil("reopened") { returns.browser.opened.count == 3 }
        returns.browser.close()
        await waitUntil("failed") { returns.controller.state == .failed }
        returns.controller.continuePayment()
        await settle()
        XCTAssertEqual(returns.browser.opened.count, 3, "no Continue payment after a failure")
        returns.controller.hostGone()
    }

    /// CS-03 reports client sessions unavailable in sandbox
    @MainActor func test_CS_03_reportsClientSessionsUnavailableInSandbox() async {
        let harness = await clientSession("client-session-422-sandbox")
        await waitUntil("failed") { harness.controller.state == .failed }
        guard case .failed(let error) = harness.controller.screen else { return XCTFail("not failed") }
        XCTAssertEqual(error.code, WajubError.Code.clientSessionUnavailable)
        XCTAssertFalse(error.retryable)
        XCTAssertEqual(harness.transport.requests("POST", "/pay/client-session").count, 1, "not retried")
        harness.controller.hostGone()
    }
}
