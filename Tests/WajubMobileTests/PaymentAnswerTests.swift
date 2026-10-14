import XCTest
@testable import WajubMobile

/// PA — handling `/pay/process` answers; RD — redirects and return.
final class PaymentAnswerTests: XCTestCase {
    /// PA-01 ignores message when deciding
    @MainActor func test_PA_01_ignoresMessageWhenDeciding() async {
        let harness = await Harness.mobileMoney(answers: "process-succeeded-200")
        harness.controller.submitMobileMoney()
        await waitUntil("success") { harness.controller.state == .success }
        XCTAssertEqual(Fixtures.body("process-succeeded-200")["message"]?.string, "Confirm the transaction on your phone.")
        XCTAssertFalse(harness.recorder.states.contains(.approvalRequired))
        XCTAssertTrue(harness.transport.requests("GET", "/pay/status").isEmpty, "decided at once, no watching")
        harness.controller.close()
        XCTAssertEqual(harness.controller.result?.status, "complete")
    }

    /// PA-02 follows redirects
    @MainActor func test_PA_02_followsRedirects() async {
        for fixture in ["process-redirect-card-hosted", "process-redirect-wallet-djamo"] {
            let harness = await Harness.mobileMoney(answers: fixture)
            harness.controller.submitMobileMoney()
            await waitUntil("pending") { harness.controller.state == .pending && !harness.browser.opened.isEmpty }
            let url = Fixtures.body(fixture)["confirm_url"]?.string
            XCTAssertEqual(harness.recorder.redirects, [url].compactMap { $0 })
            XCTAssertEqual(harness.browser.opened.map(\.url.absoluteString), [url].compactMap { $0 })
            await harness.advance(by: 5)
            XCTAssertFalse(harness.transport.requests("GET", "/pay/status").isEmpty, "watching")
            harness.controller.hostGone()
        }

        // confirm_3ds with a URL: 3DS_REQUIRED while the browser is open, then PENDING.
        let threeDS = Fixtures.body("process-requires-3ds-sandbox").setting(["confirm_url"], to: "https://acs.bank.example/3ds")
            .setting(["three_ds_id"], to: nil)
        let harness = Harness(session: "session-sandbox-cm")
        harness.transport.on("POST", "/pay/process", .json(202, threeDS))
        harness.transport.answer("status-processing")
        let controller = await harness.start()
        controller.selectMethod("card")
        for (field, value) in ["card.number": "4000056655665556", "card_holder": "A N", "expiry_month": "12", "expiry_year": "30", "cvv": "123"] {
            controller.setCardField(field, value)
        }
        controller.submitCard()
        await waitUntil("3DS in the browser") { controller.state == .threeDSRequired && !harness.browser.opened.isEmpty }
        XCTAssertEqual(harness.recorder.redirects, ["https://acs.bank.example/3ds"])
        harness.browser.close()
        await waitUntil("pending after the browser") { controller.state == .pending }
        controller.hostGone()
    }

    /// PA-03 maps unknown actions to unsupported_action
    @MainActor func test_PA_03_mapsUnknownActionsToUnsupportedAction() async {
        let base = Fixtures.body("process-requires-otp")
        for body in [base.setting(["action"], to: "confirm_magic"), base.setting(["otp_id"], to: nil)] {
            let harness = await Harness.mobileMoney()
            harness.transport.on("POST", "/pay/process", .json(202, body))
            harness.controller.submitMobileMoney()
            await waitUntil("failed") { harness.controller.state == .failed }
            guard case .failed(let error) = harness.controller.screen else { return XCTFail("not failed") }
            XCTAssertEqual(error.code, WajubError.Code.unsupportedAction)
            XCTAssertFalse(error.retryable)
            XCTAssertFalse(harness.controller.canTryAgain)
            XCTAssertEqual(harness.recorder.started.count, 1, "the payment may still be processing")
            harness.controller.close()
            XCTAssertEqual(harness.controller.result?.status, "processing")
        }
    }

    /// PA-03 maps unknown actions to unsupported_action
    @MainActor func test_PA_03_watchesA2xxThatSaysNothing() async {
        // A 2xx with neither action nor transaction: an unknown outcome, never a failure.
        for body: JSONValue in [["code": 202, "status": "Accepted", "message": "Accepted"], [:]] {
            let harness = await Harness.mobileMoney()
            harness.transport.on("POST", "/pay/process", .json(202, body))
            harness.transport.answer("status-succeeded")
            harness.controller.submitMobileMoney()
            await waitUntil("pending") { harness.controller.state == .pending }
            XCTAssertTrue(harness.recorder.errors.isEmpty)
            await harness.advance(by: 5)
            XCTAssertEqual(harness.controller.state, .success)
            harness.controller.hostGone()
        }
    }

    /// PA-04 maps declines
    @MainActor func test_PA_04_mapsDeclines() async {
        for (fixture, retryable) in [("process-failed-402", true), ("process-402-insufficient-funds-sandbox", true),
                                     ("process-402-merchant-not-verified", false)] {
            let harness = await Harness.mobileMoney(answers: fixture)
            harness.controller.submitMobileMoney()
            await waitUntil("failed") { harness.controller.state == .failed }
            guard case .failed(let error) = harness.controller.screen else { return XCTFail(fixture) }
            XCTAssertEqual(error.declineCode, Fixtures.body(fixture)["error_code"]?.string, fixture)
            XCTAssertEqual(error.retryable, retryable, fixture)
            XCTAssertEqual(error.type, .paymentError)
            XCTAssertEqual(harness.recorder.errors.map(\.code), [error.code])
            XCTAssertEqual(harness.controller.canTryAgain, retryable)
            harness.controller.tryAgain()
            XCTAssertEqual(harness.controller.state, retryable ? .collectingDetails : .failed, fixture)
            harness.controller.hostGone()
        }
    }

    /// PA-05 waits on a charge in progress
    @MainActor func test_PA_05_waitsOnAChargeInProgress() async {
        let harness = await Harness.mobileMoney(answers: "process-409-payment-in-progress", "status-processing")
        harness.controller.submitMobileMoney()
        await waitUntil("pending") { harness.controller.state == .pending }
        XCTAssertTrue(harness.recorder.errors.isEmpty)
        await harness.advance(by: 5)
        XCTAssertEqual(harness.transport.requests("GET", "/pay/status").count, 1)
        harness.controller.close()
        XCTAssertEqual(harness.controller.result?.status, "processing")
    }

    /// PA-06 maps validation errors to fields
    @MainActor func test_PA_06_mapsValidationErrorsToFields() async {
        let overLimit = "This amount is above the limit for this payment method. Use a smaller amount or another method."
        let cases: [(String, String, String?, String?)] = [
            ("process-422-validation", "en", WajubError.Code.invalidPhone, nil),
            ("process-422-operator-mismatch", "fr", WajubError.Code.operatorMismatch, nil),
            ("process-422-sandbox-invalid-test-number", "en", WajubError.Code.invalidPhone, nil),
            ("process-422-over-mobile-money-limit-sandbox", "en", nil, overLimit),
            ("process-422-over-mobile-money-limit-sandbox", "fr", nil, "Vérifiez les informations saisies."),
        ]
        for (fixture, locale, phoneCode, bannerMessage) in cases {
            let harness = await Harness.mobileMoney(locale: locale, answers: fixture)
            // A number no prefix rule names, so the form itself lets it through.
            harness.controller.setPhone("622345678")
            harness.controller.pickOperator("mtn")
            harness.controller.submitMobileMoney()
            await waitUntil("back on the form") { harness.controller.state == .collectingDetails && !harness.processBodies().isEmpty }
            XCTAssertEqual(harness.controller.screen, .form, fixture)
            XCTAssertEqual(harness.controller.fieldErrors["data.phone"]?.code, phoneCode, fixture)
            XCTAssertEqual(harness.controller.banner?.message, bannerMessage, fixture)
            XCTAssertTrue(harness.recorder.errors.isEmpty, "field validation is not sent to onError")
            if phoneCode == WajubError.Code.operatorMismatch {
                XCTAssertEqual(harness.controller.fieldErrors["data.phone"]?.message,
                               "Ce numéro est un numéro Orange Money. Choisissez Orange Money dans la liste, ou saisissez un numéro MTN MoMo.")
            }
            harness.controller.hostGone()
        }
    }

    /// PA-07 surfaces rate limits
    @MainActor func test_PA_07_surfacesRateLimits() async {
        let harness = await Harness.mobileMoney(answers: "error-429-rate-limited")
        harness.controller.submitMobileMoney()
        await waitUntil("failed") { harness.controller.state == .failed }
        guard case .failed(let error) = harness.controller.screen else { return XCTFail("not failed") }
        XCTAssertEqual(error.code, WajubError.Code.rateLimited)
        XCTAssertEqual(error.type, .rateLimitError)
        XCTAssertEqual(error.retryAfterSeconds, 300)
        XCTAssertEqual(error.message, "Trop de tentatives. Merci de patienter 300 s avant de réessayer.")
        XCTAssertEqual(harness.transport.requests("POST", "/pay/process").count, 1, "no automatic retry")
        XCTAssertEqual(harness.controller.retryAvailableAt, harness.clock.now.addingTimeInterval(300))
        harness.controller.tryAgain()
        XCTAssertEqual(harness.controller.state, .failed, "the countdown runs")
        await harness.clock.advance(by: 300)
        harness.controller.tryAgain()
        XCTAssertEqual(harness.controller.state, .collectingDetails)
        harness.controller.hostGone()
    }

    /// PA-08 maps refusals
    @MainActor func test_PA_08_mapsRefusals() async {
        for (fixture, code, retryable) in [("process-403-shield-blocked", WajubError.Code.shieldBlocked, false),
                                           ("process-403-restricted", WajubError.Code.paymentMethodRestricted, true)] {
            let harness = await Harness.mobileMoney(answers: fixture)
            harness.controller.submitMobileMoney()
            await waitUntil("failed") { harness.controller.state == .failed }
            guard case .failed(let error) = harness.controller.screen else { return XCTFail(fixture) }
            XCTAssertEqual(error.code, code)
            XCTAssertEqual(error.retryable, retryable)
            XCTAssertEqual(error.type, .paymentError)
            if code == WajubError.Code.shieldBlocked {
                XCTAssertEqual(error.blockReference, "BLK-PLACEHOLDER")
                XCTAssertEqual(error.message, "Paiement bloqué pour sécurité. Référence : BLK-PLACEHOLDER.")
            }
            harness.controller.hostGone()
        }
        let noCode = WajubError.from(APIAnswer(status: 403, body: ["code": 403, "message": "Merchant suspended"]), phase: .payment, language: .en)
        XCTAssertEqual(noCode.code, WajubError.Code.merchantRestricted)
    }

    /// PA-09 handles ended sessions during payment
    @MainActor func test_PA_09_handlesEndedSessionsDuringPayment() async {
        let notProcessable = await Harness.mobileMoney(answers: "process-400-not-processable", "status-succeeded")
        notProcessable.controller.submitMobileMoney()
        await waitUntil("success after re-reading the status") { notProcessable.controller.state == .success }
        notProcessable.controller.hostGone()

        // Still processing: an attempt is running, so wait for it (README §9).
        let running = await Harness.mobileMoney(answers: "process-400-not-processable", "status-processing")
        running.controller.submitMobileMoney()
        await waitUntil("pending") { running.controller.state == .pending }
        XCTAssertTrue(running.recorder.errors.isEmpty)
        await running.advance(by: 5)
        XCTAssertEqual(running.transport.requests("GET", "/pay/status").count, 2, "watching")
        running.controller.dismiss()
        XCTAssertEqual(running.controller.result?.status, "processing", "money may move")

        // Neither ended nor processing: not processable.
        let stillPending = await Harness.mobileMoney(answers: "process-400-not-processable")
        stillPending.transport.on("GET", "/pay/status", .json(200, ["transaction": ["reference": "trx", "status": "pending"]]))
        stillPending.controller.submitMobileMoney()
        await waitUntil("failed") { stillPending.controller.state == .failed }
        guard case .failed(let error) = stillPending.controller.screen else { return XCTFail("not failed") }
        XCTAssertEqual(error.code, WajubError.Code.notProcessable)
        stillPending.controller.hostGone()

        // No information: never a refusal.
        let silent = await Harness.mobileMoney(answers: "process-400-not-processable")
        silent.transport.on("GET", "/pay/status", .json(200, [:]))
        silent.controller.submitMobileMoney()
        await waitUntil("pending") { silent.controller.state == .pending }
        XCTAssertTrue(silent.recorder.errors.isEmpty)
        silent.controller.hostGone()

        let ended = await Harness.mobileMoney(answers: "error-410-process-session-ended")
        ended.controller.submitMobileMoney()
        await waitUntil("expired") { ended.controller.state == .expired }
        guard case .expired(let expired) = ended.controller.screen else { return XCTFail("not expired") }
        XCTAssertEqual(expired.code, WajubError.Code.sessionTerminalExpired)
        ended.controller.close()
        XCTAssertEqual(ended.controller.result?.status, "failed")
    }

    /// PA-10 fires payment started on the first 2xx
    @MainActor func test_PA_10_firesPaymentStartedOnTheFirst2xx() async {
        let harness = await Harness.mobileMoney(answers: "process-processing-mobile-money-sandbox", "status-processing")
        harness.controller.submitMobileMoney()
        await waitUntil("approval") { harness.controller.state == .approvalRequired }
        XCTAssertEqual(harness.recorder.started, [PaymentStartedEvent(method: "mobile_money", channel: "cm.mobile")])
        await harness.advance(by: 5)
        await harness.advance(by: 5)
        XCTAssertEqual(harness.recorder.started.count, 1, "once per attempt")

        // A refusal is not a start.
        let declined = await Harness.mobileMoney(answers: "process-failed-402")
        declined.controller.submitMobileMoney()
        await waitUntil("failed") { declined.controller.state == .failed }
        XCTAssertTrue(declined.recorder.started.isEmpty)
        harness.controller.hostGone()
        declined.controller.hostGone()
    }

    /// RD-01 opens provider pages in the system browser
    @MainActor func test_RD_01_opensProviderPagesInTheSystemBrowser() async {
        let harness = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        harness.transport.answer("process-redirect-card-hosted")
        var openedWhenRedirectFired: Int?
        let controller = await harness.start {
            $0.callbacks.onRedirect = { _ in openedWhenRedirectFired = harness.browser.opened.count }
        }
        controller.setPhone("670000000")
        controller.submitMobileMoney()
        await waitUntil("opened") { !harness.browser.opened.isEmpty }
        XCTAssertEqual(openedWhenRedirectFired, 0, "onRedirect fires before the browser opens")
        XCTAssertEqual(harness.browser.opened.first?.url.absoluteString, "https://checkout.psp.example/pay/abc123")

        // No browser can open it: redirect_unavailable, and Try again reopens it.
        harness.browser.canOpen = false
        controller.continuePayment()
        await waitUntil("failed") { controller.state == .failed }
        guard case .failed(let error) = controller.screen else { return XCTFail("not failed") }
        XCTAssertEqual(error.code, WajubError.Code.redirectUnavailable)
        XCTAssertTrue(error.retryable)
        harness.browser.canOpen = true
        controller.tryAgain()
        await waitUntil("reopened") { harness.browser.opened.count == 3 }
        XCTAssertEqual(controller.state, .pending)
        controller.hostGone()
    }

    /// RD-02 sends the return url only when given
    @MainActor func test_RD_02_sendsTheReturnUrlOnlyWhenGiven() async {
        let withURL = Harness(session: "session-ci-xof-wallets", config: "sdk-config-ci-wallets")
        withURL.transport.answer("process-redirect-wallet-djamo")
        let controller = await withURL.start { $0.returnURL = "https://shop.example.com/app-return" }
        controller.selectMethod("ci.djamo")
        controller.payWallet()
        await waitUntil("sent") { withURL.processBodies().count == 1 }
        XCTAssertEqual(withURL.processBodies()[0]["data"]?["return_url"]?.string, "https://shop.example.com/app-return")
        controller.hostGone()

        let without = Harness(session: "session-ci-xof-wallets", config: "sdk-config-ci-wallets")
        without.transport.answer("process-redirect-wallet-djamo")
        let plain = await without.start()
        plain.selectMethod("ci.djamo")
        plain.payWallet()
        await waitUntil("sent") { without.processBodies().count == 1 }
        XCTAssertNil(without.processBodies()[0]["data"]?["return_url"])
        plain.hostGone()

        let card = Harness(session: "session-cm-aggregate", config: "sdk-config-card-paystack")
        card.transport.answer("client-session-start-202")
        let cardController = await card.start { $0.returnURL = "https://shop.example.com/app-return" }
        cardController.selectMethod("card")
        cardController.submitCard()
        await waitUntil("client session") { !card.transport.requests("POST", "/pay/client-session").isEmpty }
        XCTAssertEqual(card.transport.requests("POST", "/pay/client-session")[0].json?["return_url"]?.string,
                       "https://shop.example.com/app-return")
        cardController.hostGone()

        let sandbox = Harness(session: "session-sandbox-cm")
        sandbox.transport.answer("process-requires-3ds-sandbox")
        let test = await sandbox.start { $0.returnURL = "https://shop.example.com/app-return" }
        test.selectMethod("card")
        for (field, value) in ["card.number": "4000056655665556", "card_holder": "A N", "expiry_month": "12", "expiry_year": "30", "cvv": "123"] {
            test.setCardField(field, value)
        }
        test.submitCard()
        await waitUntil("sent") { sandbox.processBodies().count == 1 }
        XCTAssertEqual(sandbox.processBodies()[0]["data"]?["return_url"]?.string, "https://shop.example.com/app-return")
        test.hostGone()
    }

    /// RD-03 polls on return
    @MainActor func test_RD_03_reopensAfterTheCap() async {
        let harness = await Harness.mobileMoney(answers: "process-redirect-wallet-djamo", "status-processing")
        harness.controller.submitMobileMoney()
        await waitUntil("pending") { harness.controller.state == .pending && !harness.browser.opened.isEmpty }
        await harness.drive(until: "cap", maxSteps: 200) {
            if case .pending(let pending) = harness.controller.screen { return pending.capReached }
            return false
        }
        let polls = harness.transport.requests("GET", "/pay/status").count
        harness.controller.continuePayment()
        await waitUntil("reopened") { harness.browser.opened.count == 2 }
        await harness.advance(by: 5)
        XCTAssertEqual(harness.transport.requests("GET", "/pay/status").count, polls + 1, "a new watch window")
        harness.controller.hostGone()
    }

    @MainActor func test_RD_03_pollsOnReturn() async {
        let harness = await Harness.mobileMoney(answers: "process-redirect-card-hosted", "status-succeeded")
        harness.controller.submitMobileMoney()
        await waitUntil("pending") { harness.controller.state == .pending && !harness.browser.opened.isEmpty }
        XCTAssertTrue(harness.transport.requests("GET", "/pay/status").isEmpty)
        harness.browser.close()
        await waitUntil("success without waiting for the next poll") { harness.controller.state == .success }
        XCTAssertEqual(harness.transport.requests("GET", "/pay/status").count, 1)
        harness.controller.hostGone()

        let foreground = await Harness.mobileMoney(answers: "process-redirect-wallet-djamo", "status-succeeded")
        foreground.controller.submitMobileMoney()
        await waitUntil("pending") { foreground.controller.state == .pending }
        foreground.controller.appWillEnterForeground()
        await waitUntil("success") { foreground.controller.state == .success }
        foreground.controller.hostGone()
    }
}
