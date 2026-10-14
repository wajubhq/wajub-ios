import XCTest
@testable import WajubMobile

/// CN — cancel and dismiss; ST — states, callbacks and results.
final class LifecycleTests: XCTestCase {
    /// CN-01 cancels on request
    @MainActor func test_CN_01_cancelsOnRequest() async {
        let harness = Harness(session: "session-ci-xof-wallets", config: "sdk-config-ci-wallets")
        harness.transport.answer("cancel-200")
        let controller = await harness.start()
        XCTAssertTrue(controller.canCancelPayment)
        controller.cancelPayment()
        await waitUntil("closed") { controller.result != nil }
        XCTAssertEqual(harness.transport.requests("POST", "/pay/cancel").count, 1)
        let redirect = "https://shop.example.com/payment/return?reference=trx_CancelMe0000000000000&status=cancelled&trxref=CMD-4172"
        XCTAssertEqual(controller.result, .cancelled(reason: .payerCancelled, redirectURL: redirect))
        XCTAssertEqual(Array(harness.recorder.events.suffix(3)), ["state:CANCELLED", "cancel:payer_cancelled", "complete:cancelled"])
        XCTAssertEqual(harness.recorder.cancels, [CancelEvent(reason: .payerCancelled, redirectURL: redirect)])
        XCTAssertFalse(harness.recorder.states.contains(.processing), "cancelling is not PROCESSING")
    }

    /// CN-01 cancels on request
    @MainActor func test_CN_01_finishesTheCancelWhateverHappensMeanwhile() async {
        let harness = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        let gate = Gate()
        harness.transport.on("POST", "/pay/cancel", .gated(gate, .fixture("cancel-200")))
        harness.transport.answer("process-processing-mobile-money-sandbox")
        let controller = await harness.start()
        controller.setPhone("670000000")
        controller.cancelPayment()
        XCTAssertTrue(controller.isCancelling)
        XCTAssertFalse(controller.canCancelPayment)
        // Pay and a dismiss while the cancel runs change nothing.
        controller.submitMobileMoney()
        controller.dismiss()
        await settle()
        XCTAssertTrue(harness.processBodies().isEmpty, "no payment while cancelling")
        XCTAssertNil(controller.result)
        gate.open()
        await waitUntil("closed") { controller.result != nil }
        XCTAssertEqual(harness.transport.requests("POST", "/pay/cancel").count, 1, "one cancel, sent to its end")
        guard case .cancelled(let reason, let redirect)? = controller.result else { return XCTFail("not cancelled") }
        XCTAssertEqual(reason, .payerCancelled)
        XCTAssertNotNil(redirect, "redirect_url kept")

        // The same while the X's own cancel runs.
        let closing = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        let closingGate = Gate()
        closing.transport.on("POST", "/pay/cancel", .gated(closingGate, .fixture("cancel-200")))
        closing.transport.answer("process-processing-mobile-money-sandbox")
        let closingController = await closing.start()
        closingController.setPhone("670000000")
        closingController.close()
        await waitUntil("cancel sent") { closing.transport.requests("POST", "/pay/cancel").count == 1 }
        XCTAssertTrue(closingController.isCancelling, "the X and Pay wait")
        XCTAssertTrue(closingController.isWorking)
        XCTAssertFalse(closingController.canCancelPayment)
        closingController.submitMobileMoney()
        await settle()
        XCTAssertTrue(closing.processBodies().isEmpty, "nothing paid while the dismiss cancel runs")
        XCTAssertTrue(closing.recorder.started.isEmpty)
        closingGate.open()
        await waitUntil("closed") { closingController.result != nil }
        XCTAssertEqual(closingController.result?.status, "cancelled")

        // The host going away during the cancel settles at once; the cancel still reaches the API.
        let gone = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        let goneGate = Gate()
        gone.transport.on("POST", "/pay/cancel", .gated(goneGate, .fixture("cancel-200")))
        let goneController = await gone.start()
        goneController.dismiss()
        await waitUntil("cancel sent") { gone.transport.requests("POST", "/pay/cancel").count == 1 }
        goneController.hostGone()
        XCTAssertEqual(goneController.result, .cancelled(reason: .hostGone, redirectURL: nil))
        goneGate.open()
        await settle()
        XCTAssertEqual(goneController.result, .cancelled(reason: .hostGone, redirectURL: nil))
        XCTAssertEqual(gone.recorder.completions.count, 1)
    }

    /// CN-02 cancels on dismiss before any attempt
    @MainActor func test_CN_02_cancelsOnDismissBeforeAnyAttempt() async {
        let harness = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        harness.transport.answer("cancel-200")
        let controller = await harness.start()
        controller.dismiss()
        await waitUntil("closed") { controller.result != nil }
        guard case .cancelled(let reason, let redirect)? = controller.result else { return XCTFail("not cancelled") }
        XCTAssertEqual(reason, .dismissed)
        XCTAssertNotNil(redirect)
        XCTAssertEqual(harness.transport.requests("POST", "/pay/cancel").count, 1)

        let kept = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        let keptController = await kept.start { $0.cancelOnDismiss = false }
        keptController.dismiss()
        XCTAssertEqual(keptController.result, .cancelled(reason: .dismissed, redirectURL: nil))
        XCTAssertTrue(kept.transport.requests("POST", "/pay/cancel").isEmpty, "the session stays open")

        // A failed cancel changes nothing for the payer.
        let offline = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        offline.transport.on("POST", "/pay/cancel", .failure(.network("offline")))
        let offlineController = await offline.start()
        offlineController.dismiss()
        await offline.drive(until: "closed") { offlineController.result != nil }
        XCTAssertEqual(offlineController.result, .cancelled(reason: .dismissed, redirectURL: nil))
        XCTAssertEqual(offline.transport.requests("POST", "/pay/cancel").count, 3, "two retries")
    }

    /// CN-03 dismiss after start resolves processing
    @MainActor func test_CN_03_dismissAfterStartResolvesProcessing() async {
        let harness = await Harness.mobileMoney(answers: "process-processing-mobile-money-sandbox", "status-processing")
        harness.controller.submitMobileMoney()
        await waitUntil("started") { !harness.recorder.started.isEmpty }
        XCTAssertFalse(harness.controller.canCancelPayment)
        harness.controller.dismiss()
        guard case .processing(let transaction)? = harness.controller.result else { return XCTFail("not processing") }
        XCTAssertEqual(transaction?.id, "trx_test_PVrU8x2kQ1mNa7Lb3cDe")
        await settle()
        XCTAssertTrue(harness.transport.requests("POST", "/pay/cancel").isEmpty)
    }

    /// CN-04 handles a refused cancel
    @MainActor func test_CN_04_handlesARefusedCancel() async {
        let harness = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        harness.transport.answer("cancel-400-not-cancellable", "status-succeeded")
        let controller = await harness.start()
        controller.cancelPayment()
        await waitUntil("success") { controller.state == .success }
        XCTAssertEqual(harness.transport.requests("GET", "/pay/status").count, 1)
        controller.close()
        XCTAssertEqual(controller.result?.status, "complete")

        let dismissed = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        dismissed.transport.answer("cancel-400-not-cancellable", "status-succeeded")
        let dismissedController = await dismissed.start()
        dismissedController.dismiss()
        await waitUntil("closed") { dismissedController.result != nil }
        XCTAssertEqual(dismissedController.result?.status, "complete")
        XCTAssertEqual(dismissed.recorder.successes.count, 1, "onSuccess before onComplete")
        XCTAssertEqual(dismissed.recorder.events.suffix(2), ["success", "complete:complete"])

        // Still processing: money may move, so never `cancelled`.
        let running = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        running.transport.answer("cancel-400-not-cancellable", "status-processing")
        let runningController = await running.start()
        runningController.dismiss()
        await waitUntil("closed") { runningController.result != nil }
        XCTAssertEqual(runningController.result?.status, "processing")

        let asked = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        asked.transport.answer("cancel-400-not-cancellable", "status-processing")
        let askedController = await asked.start()
        askedController.cancelPayment()
        await waitUntil("pending") { askedController.state == .pending }
        XCTAssertNil(askedController.result, "the sheet waits for the payment running")
        await asked.advance(by: 5)
        XCTAssertEqual(asked.transport.requests("GET", "/pay/status").count, 2, "watching")
        askedController.hostGone()
        XCTAssertEqual(askedController.result?.status, "processing")

        let failed = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        failed.transport.answer("cancel-400-not-cancellable")
        failed.transport.on("GET", "/pay/status", .json(200, ["transaction": ["reference": "trx", "status": "failed"]]))
        let failedController = await failed.start()
        failedController.dismiss()
        await waitUntil("closed") { failedController.result != nil }
        XCTAssertEqual(failedController.result?.status, "failed")
        XCTAssertEqual(failed.recorder.errors.map(\.code), [WajubError.Code.paymentFailed])
    }

    /// ST-02 fires callbacks in order
    @MainActor func test_ST_02_ignoresAnswersThatArriveAfterAnOutcome() async {
        // The status says paid while the OTP verification is still running; then the verification answers.
        let harness = Harness(session: "session-cm-aggregate", config: "sdk-config-card-kkiapay")
        let gate = Gate()
        let paid = Fixtures.body("otp-verify-success").setting(["transaction", "status"], to: "succeeded")
        harness.transport.answer("process-requires-otp")
        harness.transport.on("POST", "/pay/otp/verify", .gated(gate, .json(200, paid)))
        harness.transport.on("GET", "/pay/status", .fixture("status-succeeded"))
        let controller = await harness.start()
        controller.selectMethod("card")
        controller.submitCard()
        await waitUntil("otp") { controller.state == .otpRequired }
        controller.submitStep(["code": "123456"])
        await waitUntil("verifying") { controller.state == .verifying }
        await harness.advance(by: 5)
        XCTAssertEqual(controller.state, .success)
        gate.open()
        await settle()
        XCTAssertEqual(controller.state, .success)
        XCTAssertEqual(harness.recorder.successes.count, 1, "onSuccess once")
        await harness.advance(by: 3)
        XCTAssertEqual(controller.result?.status, "complete")
        XCTAssertTrue(harness.transport.requests("POST", "/pay/cancel").isEmpty)
    }

    /// ST-01 reports Wajub.js states
    @MainActor func test_ST_01_reportsWajubJsStates() async {
        XCTAssertEqual(CheckoutState.allCases.map(\.rawValue), [
            "INITIATED", "COLLECTING_DETAILS", "PROCESSING", "OTP_REQUIRED", "PIN_REQUIRED", "PHONE_REQUIRED",
            "BIRTHDAY_REQUIRED", "ADDRESS_REQUIRED", "3DS_REQUIRED", "USSD_REQUIRED", "APPROVAL_REQUIRED", "VERIFYING",
            "PENDING", "SUCCESS", "FAILED", "EXPIRED", "CANCELLED",
        ])
        let approval = await Harness.mobileMoney(answers: "process-processing-mobile-money-sandbox")
        approval.controller.submitMobileMoney()
        await waitUntil("approval") { approval.controller.state == .approvalRequired }
        XCTAssertEqual(approval.recorder.states, [.collectingDetails, .processing, .approvalRequired])
        approval.controller.hostGone()

        let otp = await Harness.mobileMoney(answers: "process-requires-otp")
        otp.controller.submitMobileMoney()
        await waitUntil("otp") { otp.controller.state == .otpRequired }
        XCTAssertEqual(otp.recorder.states, [.collectingDetails, .processing, .otpRequired])
        otp.controller.hostGone()

        let hosted = await Harness.mobileMoney(answers: "process-redirect-card-hosted")
        hosted.controller.submitMobileMoney()
        await waitUntil("pending") { hosted.controller.state == .pending }
        XCTAssertEqual(hosted.recorder.states, [.collectingDetails, .processing, .pending])
        hosted.controller.hostGone()

        let ussd = Fixtures.body("process-processing-mobile-money-live").setting(["transaction", "processing_context", "is_mobile_money"], to: false)
            .setting(["transaction", "processing_context", "is_ussd"], to: true)
        let dial = await Harness.mobileMoney()
        dial.transport.on("POST", "/pay/process", .json(202, ussd))
        dial.controller.submitMobileMoney()
        await waitUntil("ussd") { dial.controller.state == .ussdRequired }
        dial.controller.hostGone()
    }

    /// ST-02 fires callbacks in order
    @MainActor func test_ST_02_firesCallbacksInOrder() async {
        let harness = await Harness.mobileMoney(answers: "process-processing-mobile-money-sandbox", "status-succeeded")
        harness.controller.submitMobileMoney()
        await waitUntil("approval") { harness.controller.state == .approvalRequired }
        await harness.advance(by: 5)
        XCTAssertEqual(harness.controller.state, .success)
        await harness.advance(by: 3)
        XCTAssertEqual(harness.recorder.events, [
            "ready", "state:COLLECTING_DETAILS", "state:PROCESSING", "started", "state:APPROVAL_REQUIRED",
            "state:SUCCESS", "success", "complete:complete",
        ])
        for (previous, next) in zip(harness.recorder.states, harness.recorder.states.dropFirst()) {
            XCTAssertNotEqual(previous, next, "no duplicate consecutive state")
        }
    }

    /// ST-03 resolves present once
    @MainActor func test_ST_03_resolvesPresentOnce() async throws {
        let harness = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        harness.transport.answer("cancel-200")
        let controller = harness.makeController()
        let presenter = FakePresenter()
        let task = Task { try await Checkout.present(controller, presenter: presenter) }
        await waitUntil("ready") { controller.state != nil }
        XCTAssertTrue(Checkout.isPresenting)
        XCTAssertEqual(presenter.presented.count, 1)
        controller.cancelPayment()
        let result = try await task.value
        XCTAssertEqual(result.status, "cancelled")
        XCTAssertEqual(presenter.dismissed.count, 1)
        // Later calls change nothing.
        controller.dismiss()
        controller.hostGone()
        controller.close()
        await settle()
        XCTAssertEqual(harness.recorder.completions, [result])
        XCTAssertEqual(controller.result, result)
        XCTAssertFalse(Checkout.isPresenting)
    }

    /// ST-03 resolves present once
    @MainActor func test_ST_03_resolvesOnceTheSheetIsGone() async throws {
        let harness = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        let controller = harness.makeController { $0.cancelOnDismiss = false }
        let presenter = FakePresenter()
        presenter.holdsDismissal = true
        let resolved = Outcome()
        Task { await resolved.recordResult { try await Checkout.present(controller, presenter: presenter) } }
        await waitUntil("ready") { controller.state != nil }
        controller.dismiss()
        XCTAssertEqual(controller.result, .cancelled(reason: .dismissed, redirectURL: nil))
        await settle()
        XCTAssertNil(resolved.value, "the sheet is still going away")
        XCTAssertTrue(Checkout.isPresenting)
        presenter.finishDismissal()
        await waitUntil("resolved") { resolved.value != nil }
        XCTAssertEqual(resolved.value, "cancelled")
        XCTAssertFalse(Checkout.isPresenting)

        // Presenting again right away works.
        let again = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        let next = again.makeController()
        let nextPresenter = FakePresenter()
        let second = Outcome()
        Task { await second.recordResult { try await Checkout.present(next, presenter: nextPresenter) } }
        await waitUntil("presented") { nextPresenter.presented.count == 1 }
        await waitUntil("ready") { next.state != nil }
        next.hostGone()
        await waitUntil("resolved") { second.value != nil }
        XCTAssertEqual(second.value, "cancelled")
    }

    /// ST-04 settles when the host goes away
    @MainActor func test_ST_04_settlesWithoutAScreenToPresentFrom() async throws {
        // A presenter that has no screen to present from settles through the callbacks.
        let harness = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        let controller = harness.makeController()
        let presenter = NoHostPresenter()
        let result = try await Checkout.present(controller, presenter: presenter)
        XCTAssertEqual(result, .cancelled(reason: .hostGone, redirectURL: nil))
        XCTAssertEqual(harness.recorder.events, ["cancel:host_gone", "complete:cancelled"])
        XCTAssertTrue(harness.transport.requests("GET", "/pay/session").isEmpty, "nothing loaded for a settled checkout")
        XCTAssertFalse(Checkout.isPresenting, "the lock is free at once")
        let next = try await Checkout.present(harness.makeController(), presenter: NoHostPresenter())
        XCTAssertEqual(next, .cancelled(reason: .hostGone, redirectURL: nil), "and a new present() can follow")
    }

    /// ST-04 settles when the host goes away
    @MainActor func test_ST_04_settlesWhenTheHostGoesAway() async {
        let before = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        let idle = await before.start()
        idle.hostGone()
        XCTAssertEqual(idle.result, .cancelled(reason: .hostGone, redirectURL: nil))
        await settle()
        XCTAssertTrue(before.transport.requests("POST", "/pay/cancel").isEmpty, "never /pay/cancel")

        let during = await Harness.mobileMoney(answers: "process-processing-mobile-money-sandbox", "status-processing")
        during.controller.submitMobileMoney()
        await waitUntil("approval") { during.controller.state == .approvalRequired }
        during.controller.hostGone()
        XCTAssertEqual(during.controller.result?.status, "processing")
        await during.clock.advance(by: 60)
        XCTAssertTrue(during.transport.requests("GET", "/pay/status").isEmpty, "watching stopped")
        XCTAssertTrue(during.transport.requests("POST", "/pay/cancel").isEmpty)

        let paid = await Harness.mobileMoney(answers: "process-succeeded-200")
        paid.controller.submitMobileMoney()
        await waitUntil("success") { paid.controller.state == .success }
        paid.controller.hostGone()
        XCTAssertEqual(paid.controller.result?.status, "complete")

        // While loading too: it never hangs.
        let loading = Harness()
        loading.transport.on("GET", "/pay/session", .gated(Gate(), .fixture("session-cm-aggregate")))
        let controller = loading.makeController()
        controller.start()
        controller.hostGone()
        XCTAssertEqual(controller.result, .cancelled(reason: .hostGone, redirectURL: nil))
    }

    /// ST-04 settles when the host goes away
    @MainActor func test_ST_04_releasesTheCheckoutOnceSettled() async {
        weak var client: WajubSession?
        weak var settled: CheckoutController?
        func run() async {
            let harness = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
            harness.transport.answer("process-processing-mobile-money-live", "status-processing", "broadcasting-auth-200")
            let controller = await harness.start()
            controller.setPhone("670000000")
            controller.submitMobileMoney()
            await waitUntil("watching") { controller.state == .approvalRequired }
            await harness.advance(by: 5)
            client = controller.client
            settled = controller
            controller.hostGone()
        }
        await run()
        await settle()
        XCTAssertNil(settled, "nothing keeps a settled checkout alive")
        XCTAssertNil(client, "so its URLSession (invalidated when its transport goes) does not leak")
    }

    /// ST-05 rejects a second present
    @MainActor func test_ST_05_rejectsBeforeLookingForAScreen() async throws {
        let first = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        let controller = first.makeController()
        let task = Task { try await Checkout.present(controller, presenter: FakePresenter()) }
        await waitUntil("ready") { controller.state != nil }
        let second = NoHostPresenter()
        do {
            _ = try await Checkout.present(PresentOptions(sessionToken: "other"), presenter: second, browser: FakeBrowser())
            XCTFail("a second present must reject")
        } catch let error as WajubError {
            XCTAssertEqual(error.code, WajubError.Code.sheetAlreadyPresented)
        }
        XCTAssertEqual(second.calls, 0, "rejected before the presenter is asked anything")
        controller.hostGone()
        _ = try await task.value
    }

    /// ST-05 rejects a second present
    @MainActor func test_ST_05_rejectsASecondPresent() async throws {
        let first = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        let controller = first.makeController()
        let presenter = FakePresenter()
        let task = Task { try await Checkout.present(controller, presenter: presenter) }
        await waitUntil("ready") { controller.state != nil }
        do {
            _ = try await Checkout.present(PresentOptions(sessionToken: "other"), presenter: FakePresenter(), browser: FakeBrowser())
            XCTFail("a second present must reject")
        } catch let error as WajubError {
            XCTAssertEqual(error.code, WajubError.Code.sheetAlreadyPresented)
            XCTAssertEqual(error.type, .invalidRequestError)
            XCTAssertEqual(error.message, "A Wajub payment sheet is already presented.")
        }
        XCTAssertNil(controller.result, "the open sheet is left alone")
        XCTAssertEqual(controller.state, .collectingDetails)
        controller.hostGone()
        _ = try await task.value
    }

    /// ST-06 builds PaymentSuccess
    @MainActor func test_ST_06_buildsPaymentSuccess() async throws {
        let harness = Harness(session: "session-cm-aggregate", config: "sdk-config-card-paystack")
        harness.transport.answer("client-session-start-202", "client-session-complete-200", "status-processing")
        let controller = await harness.start()
        controller.selectMethod("card")
        controller.submitCard()
        await waitUntil("browser") { !harness.browser.opened.isEmpty }
        harness.browser.close()
        await waitUntil("success") { controller.state == .success }
        let payment = try XCTUnwrap(harness.recorder.successes.first)
        XCTAssertEqual(payment.id, "trx_ClientSessN7aQ2LmX9k")
        XCTAssertEqual(payment.reference, "CMD-4172")
        XCTAssertEqual(payment.amount, 1000)
        XCTAssertEqual(payment.currency, "NGN")
        XCTAssertEqual(payment.method, "card")
        XCTAssertEqual(payment.status, "success")
        XCTAssertEqual(payment.timestamp, "2026-10-14T09:30:00+00:00")
        XCTAssertEqual(payment.receiptURL, "https://invoice.wajub.com/r/trx_ClientSessN7aQ2LmX9k?s=SIGNATURE")
        controller.hostGone()

        let fee = Fixtures.session("session-payer-bears-fee").transaction
        let withFee = PaymentSuccess(transaction: fee, method: "mobile_money", now: harness.clock.now)
        XCTAssertEqual(withFee.amount, 10350, "amount_total")
        XCTAssertEqual(withFee.timestamp, "2026-10-14T09:30:00+00:00", "updated_at when there is no terminal_at")
        var bare = fee
        bare.updatedAt = nil
        XCTAssertEqual(PaymentSuccess(transaction: bare, method: "card", now: harness.clock.now).timestamp, "2026-10-14T09:00:00Z")
    }

    /// ST-07 survives throwing callbacks
    @MainActor func test_ST_07_survivesThrowingCallbacks() async {
        struct Boom: Error {}
        let harness = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        harness.transport.answer("process-succeeded-200")
        let controller = await harness.start {
            $0.callbacks = CheckoutCallbacks(onReady: { _ in throw Boom() }, onStateChange: { _ in throw Boom() },
                                             onPaymentStarted: { _ in throw Boom() }, onSuccess: { _ in throw Boom() },
                                             onComplete: { _ in throw Boom() })
        }
        controller.setPhone("670000000")
        controller.submitMobileMoney()
        await waitUntil("success despite the callbacks") { controller.state == .success }
        controller.close()
        XCTAssertEqual(controller.result?.status, "complete")
    }
}

/// A presenter with no screen to present from.
@MainActor
final class NoHostPresenter: CheckoutPresenting {
    var calls = 0

    func present(_ controller: CheckoutController) {
        calls += 1
        controller.hostGone()
    }

    func dismiss(_ controller: CheckoutController, completion: @escaping @MainActor @Sendable () -> Void) {
        calls += 1
        completion()
    }
}

extension Outcome {
    func recordResult(_ call: @Sendable () async throws -> CheckoutResult) async {
        let text: String
        do {
            text = try await call().status
        } catch {
            text = "\(error)"
        }
        set(text)
    }
}
