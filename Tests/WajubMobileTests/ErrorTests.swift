import XCTest
@testable import WajubMobile

/// ER — the error shape, the mapping of every error fixture, and localised messages; AL — Altcha.
final class ErrorTests: XCTestCase {
    /// ER-01 exposes the error shape
    func test_ER_01_exposesTheErrorShape() {
        let error = WajubError(type: .rateLimitError, code: "rate_limited", message: "Wait", declineCode: nil, retryable: true,
                               param: "data.phone", httpStatus: 429, correlationId: "req_1", retryAfterSeconds: 300,
                               details: ["data.phone": "Too many"], blockReference: nil, apiMessage: "Too many requests")
        let json = error.toJSON()
        XCTAssertEqual(Set(json.object?.keys.map { $0 } ?? []), [
            "name", "type", "code", "message", "decline_code", "retryable", "param", "http_status", "correlation_id",
            "retry_after_seconds", "details", "block_reference", "api_message",
        ])
        XCTAssertEqual(json["name"], "WajubError")
        XCTAssertEqual(json["type"], "rate_limit_error")
        XCTAssertEqual(json["http_status"], 429)
        XCTAssertEqual(json["retry_after_seconds"], 300)
        XCTAssertEqual(json["decline_code"], .null)
        XCTAssertEqual(json["details"], ["data.phone": "Too many"])
        XCTAssertEqual(error.errorDescription, "Wait")
        XCTAssertEqual(Set(WajubErrorType.allCases.map(\.rawValue)),
                       ["api_error", "authentication_error", "invalid_request_error", "payment_error", "rate_limit_error"])
    }

    /// code, type, retryable, decline_code, param for every fixture answered with an HTTP error.
    private let expectations: [String: (String, WajubErrorType, Bool, String?, String?)] = [
        "3ds-verify-422-invalid-code": ("invalid_code", .invalidRequestError, true, nil, "request"),
        "3ds-verify-500-invalid-code-api-bug": ("server_error", .apiError, true, nil, nil),
        "address-verify-422-missing-fields": ("validation_error", .invalidRequestError, true, nil, nil),
        "birthday-verify-422-format": ("validation_error", .invalidRequestError, true, nil, "birthday"),
        "broadcasting-auth-403": ("merchant_restricted", .paymentError, false, nil, nil),
        "cancel-400-not-cancellable": ("not_processable", .invalidRequestError, false, nil, nil),
        "cancel-409-payment-in-progress": ("payment_in_progress", .invalidRequestError, false, nil, nil),
        "cancel-409-payment-partly-paid": ("payment_partly_paid", .invalidRequestError, false, nil, nil),
        "client-session-422-sandbox": ("client_session_unavailable", .invalidRequestError, false, nil, "request"),
        "client-session-422-security-check-failed": ("security_check_failed", .invalidRequestError, true, nil, "request"),
        "process-422-security-check-failed": ("security_check_failed", .invalidRequestError, true, nil, "request"),
        "client-session-complete-402": ("failed", .paymentError, true, "failed", nil),
        "client-session-complete-422-expired": ("client_session_expired", .invalidRequestError, true, nil, "request"),
        "error-401-invalid-token": ("session_not_found", .authenticationError, false, nil, nil),
        "error-401-missing-token": ("session_not_found", .authenticationError, false, nil, nil),
        "error-403-not-a-payment-session": ("session_not_found", .authenticationError, false, nil, nil),
        "error-410-process-session-ended": ("session_terminal_expired", .invalidRequestError, false, nil, nil),
        "error-410-session-expired": ("session_terminal_expired", .invalidRequestError, false, nil, nil),
        "error-410-session-terminal-expired": ("session_terminal_expired", .invalidRequestError, false, nil, nil),
        "error-429-rate-limited": ("rate_limited", .rateLimitError, true, nil, nil),
        "error-500-production": ("server_error", .apiError, true, nil, nil),
        "process-400-not-processable": ("not_processable", .invalidRequestError, false, nil, nil),
        "process-402-insufficient-funds-sandbox": ("insufficient_funds", .paymentError, true, "insufficient_funds", nil),
        "process-402-merchant-not-verified": ("merchant_not_verified", .paymentError, false, "merchant_not_verified", nil),
        "process-403-restricted": ("payment_method_restricted", .paymentError, true, nil, nil),
        "process-403-shield-blocked": ("shield_blocked", .paymentError, false, nil, nil),
        "process-409-order-not-validated": ("order_not_validated", .invalidRequestError, false, nil, nil),
        "process-409-payment-in-progress": ("payment_in_progress", .invalidRequestError, false, nil, nil),
        "process-422-idempotency-key-invalid": ("validation_error", .invalidRequestError, true, nil, "idempotency_key"),
        "process-422-operator-mismatch": ("validation_error", .invalidRequestError, true, nil, "phone"),
        "process-422-over-mobile-money-limit-sandbox": ("validation_error", .invalidRequestError, true, nil, "request"),
        "process-422-raw-card-data-live": ("raw_card_data_not_accepted", .invalidRequestError, false, nil, "card"),
        "process-422-sandbox-invalid-test-number": ("validation_error", .invalidRequestError, true, nil, "data.phone"),
        "process-422-unknown-channel": ("validation_error", .invalidRequestError, true, nil, "channel"),
        "process-422-validation": ("validation_error", .invalidRequestError, true, nil, nil),
        "process-failed-402": ("insufficient_funds", .paymentError, true, "insufficient_funds", nil),
    ]

    /// ER-02 maps every error fixture
    func test_ER_02_mapsEveryErrorFixture() throws {
        let failing = Fixtures.allNames.filter { Fixtures.status($0) >= 400 }
        XCTAssertEqual(Set(failing), Set(expectations.keys), "every error fixture has an expectation")
        for name in failing {
            let path = Fixtures.envelope(name)["request"]?["path"]?.string ?? ""
            var headers = Fixtures.headers(name)
            headers["X-Request-Id"] = "req_\(name)"
            let answer = APIAnswer(status: Fixtures.status(name), headers: headers, body: Fixtures.body(name))
            let error = WajubError.from(answer, phase: path == "/pay/session" ? .loading : .payment, language: .en)
            let (code, type, retryable, decline, param) = try XCTUnwrap(expectations[name])
            XCTAssertEqual(error.code, code, name)
            XCTAssertEqual(error.type, type, name)
            XCTAssertEqual(error.retryable, retryable, name)
            XCTAssertEqual(error.declineCode, decline, name)
            XCTAssertEqual(error.param, param, name)
            XCTAssertEqual(error.httpStatus, Fixtures.status(name), name)
            XCTAssertEqual(error.correlationId, "req_\(name)", name)
            XCTAssertFalse(error.message.isEmpty, name)
        }
        let limited = WajubError.from(APIAnswer(status: 429, headers: Fixtures.headers("error-429-rate-limited"),
                                                body: Fixtures.body("error-429-rate-limited")), phase: .payment, language: .en)
        XCTAssertEqual(limited.retryAfterSeconds, 300)
        let headerOnly = WajubError.from(APIAnswer(status: 429, headers: ["Retry-After": "12"], body: ["code": 429]), phase: .payment, language: .en)
        XCTAssertEqual(headerOnly.retryAfterSeconds, 12)
        let shield = WajubError.from(APIAnswer(status: 403, body: Fixtures.body("process-403-shield-blocked")), phase: .payment, language: .en)
        XCTAssertEqual(shield.blockReference, "BLK-PLACEHOLDER")
        let details = WajubError.from(APIAnswer(status: 422, body: Fixtures.body("address-verify-422-missing-fields")), phase: .payment, language: .en)
        XCTAssertEqual(details.details, ["city": "The city field is required.", "state": "The state field is required.",
                                         "zip_code": "The zip code field is required."])
        // The 3-D Secure verify endpoint reads any 5xx as a wrong code.
        let bug = APIAnswer(status: 500, body: Fixtures.body("3ds-verify-500-invalid-code-api-bug"))
        XCTAssertEqual(WajubSession.threeDSError(bug, .en).code, WajubError.Code.invalidCode)
        XCTAssertTrue(WajubSession.threeDSKeepsScreen(bug))

        // The confirmation steps' HTTP 200 failures.
        let steps: [(String, String, WajubErrorType)] = [
            ("otp-verify-invalid", "invalid_otp", .invalidRequestError), ("otp-verify-expired", "otp_expired", .invalidRequestError),
            ("otp-verify-max-attempts", "max_attempts_exceeded", .paymentError), ("pin-verify-invalid", "invalid_pin", .invalidRequestError),
        ]
        for (fixture, code, type) in steps {
            guard case .failed(let failure, let message, let remaining) = StepVerifyResponse(json: Fixtures.body(fixture)) else {
                return XCTFail(fixture)
            }
            let error = WajubError.stepFailure(code: failure, apiMessage: message, attemptsRemaining: remaining, .en)
            XCTAssertEqual(error.code, code, fixture)
            XCTAssertEqual(error.type, type, fixture)
            XCTAssertTrue(error.retryable, fixture)
            XCTAssertEqual(error.httpStatus, 200)
        }
    }

    /// ER-03 localises error messages
    func test_ER_03_localisesErrorMessages() {
        let decline = APIAnswer(status: 402, body: Fixtures.body("process-failed-402"))
        XCTAssertEqual(WajubError.from(decline, phase: .payment, language: .en).message, "Insufficient funds.")
        XCTAssertEqual(WajubError.from(decline, phase: .payment, language: .fr).message, "Fonds insuffisants.")
        let pspCode = APIAnswer(status: 402, body: Fixtures.body("client-session-complete-402"))
        XCTAssertEqual(WajubError.from(pspCode, phase: .payment, language: .en).message,
                       "This payment could not be completed. Try again or use another payment method.")
        XCTAssertEqual(WajubError.from(pspCode, phase: .payment, language: .fr).message,
                       "Ce paiement n'a pas abouti. Réessayez ou utilisez un autre moyen de paiement.")
        let validation = APIAnswer(status: 422, body: Fixtures.body("process-422-unknown-channel"))
        XCTAssertEqual(WajubError.from(validation, phase: .payment, language: .en).message, "The selected channel is invalid.")
        XCTAssertEqual(WajubError.from(validation, phase: .payment, language: .fr).message, "Vérifiez les informations saisies.")
        let unknown = APIAnswer(status: 503, body: ["code": 503, "message": "Maintenance", "error_code": "maintenance_window"])
        XCTAssertEqual(WajubError.from(unknown, phase: .payment, language: .en).message, "Maintenance")
        XCTAssertEqual(WajubError.from(unknown, phase: .payment, language: .fr).message, "Service temporairement indisponible.")
        XCTAssertEqual(WajubError.from(unknown, phase: .payment, language: .fr).code, "maintenance_window", "passed through")
        XCTAssertEqual(WajubError.from(unknown, phase: .payment, language: .fr).apiMessage, "Maintenance")
        XCTAssertEqual(WajubError.stepFailure(code: "invalid_otp", apiMessage: nil, attemptsRemaining: 2, .en).message,
                       "Incorrect code. 2 attempts left.")

        // Every catalogue code has both languages, and every code of the contract is in the catalogue.
        for (code, entry) in ErrorCatalogue.entries {
            XCTAssertFalse(entry.en.isEmpty, code)
            XCTAssertFalse(entry.fr.isEmpty, code)
        }
        let contract = ["session_not_found", "session_terminal_expired", "session_terminal_cancelled", "session_terminal_failed",
                        "load_error", "ready_timeout", "no_payment_method", "network_error", "timeout", "server_error", "rate_limited",
                        "request_failed", "phone_required", "invalid_phone", "operator_mismatch", "operator_required",
                        "operator_unavailable", "field_required", "invalid_email", "validation_error", "payment_declined",
                        "insufficient_funds", "merchant_not_verified", "limit_exceeded", "shield_blocked", "merchant_restricted",
                        "payment_method_restricted", "country_restricted", "currency_restricted", "channel_not_accepted",
                        "payment_failed", "payment_attempt_ended", "payment_cancelled", "session_expired", "not_processable",
                        "order_not_validated", "raw_card_data_not_accepted", "security_check_failed", "unsupported_action",
                        "redirect_unavailable", "invalid_otp", "otp_expired", "invalid_pin", "pin_expired", "phone_expired",
                        "invalid_birthday", "birthday_expired", "invalid_address", "address_expired", "max_attempts_exceeded",
                        "invalid_code", "3ds_failed", "3ds_rejected", "3ds_cancelled", "3ds_timeout", "client_session_unavailable",
                        "client_session_expired", "sheet_already_presented"]
        XCTAssertEqual(Set(contract), Set(ErrorCatalogue.entries.keys))

        // The sheet's own texts exist in both languages.
        for language in WajubLanguage.allCases {
            let strings = WajubStrings(language)
            XCTAssertFalse(strings.approvalTitle.isEmpty)
            for kind in ConfirmStepKind.allCases { XCTAssertFalse(strings.stepTitle(kind).isEmpty) }
        }
        XCTAssertEqual(WajubStrings(.fr).approvalTitle, "Validez le paiement sur votre téléphone")
        XCTAssertEqual(WajubStrings(.en).approvalTitle, "Approve the payment on your phone")
        XCTAssertEqual(WajubStrings(.fr).loadErrorTitle, "Impossible de charger le paiement")
    }

    /// AL-01 solves altcha challenges
    @MainActor func test_AL_01_solvesAltchaChallenges() async throws {
        let challenge = AltchaChallenge(algorithm: "SHA-256", challenge: Digest.sha256Hex("s4lt1234"), salt: "s4lt",
                                        signature: "sig", maxNumber: 5000)
        XCTAssertEqual(challenge.challenge, "1428a5a65936b6fb52c4792e13873f4ed8a20584dd4846b5057535416c287d9d")
        XCTAssertEqual(AltchaSolver.solve(challenge)?.number, 1234)
        XCTAssertNil(AltchaSolver.solve(AltchaChallenge(algorithm: "SHA-256", challenge: challenge.challenge, salt: "s4lt",
                                                        signature: "sig", maxNumber: 1000)), "out of range")

        let altcha: JSONValue = ["algorithm": "SHA-256", "challenge": .string(challenge.challenge), "salt": "s4lt", "signature": "sig",
                                 "maxnumber": 5000]
        let expected: JSONValue = ["algorithm": "SHA-256", "challenge": .string(challenge.challenge), "number": 1234, "salt": "s4lt",
                                   "signature": "sig"]
        let session = Fixtures.body("session-cm-aggregate").setting(["altcha"], to: altcha)
        let harness = Harness(config: "sdk-config-cm-stripe")
        harness.transport.on("GET", "/pay/session", .json(200, session))
        harness.transport.answer("process-processing-mobile-money-sandbox")
        let controller = await harness.start()
        controller.setPhone("670000000")
        controller.submitMobileMoney()
        await waitUntil("sent") { harness.processBodies().count == 1 }
        XCTAssertEqual(harness.processBodies()[0]["data"]?["altcha"], expected)
        controller.hostGone()

        // On /pay/client-session too.
        let card = Harness(config: "sdk-config-card-paystack")
        card.transport.on("GET", "/pay/session", .json(200, session))
        card.transport.answer("client-session-start-202")
        let cardController = await card.start()
        cardController.selectMethod("card")
        cardController.submitCard()
        await waitUntil("sent") { !card.transport.requests("POST", "/pay/client-session").isEmpty }
        XCTAssertEqual(card.transport.requests("POST", "/pay/client-session")[0].json?["altcha"], expected)
        cardController.hostGone()

        // Refused: reload the session for a new challenge once, then security_check_failed.
        let refused = Harness(config: "sdk-config-cm-stripe")
        refused.transport.on("GET", "/pay/session", .json(200, session))
        refused.transport.on("POST", "/pay/process", .json(422, ["code": 422, "message": "Security challenge verification failed",
                                                                  "errors": ["altcha": ["Security challenge verification failed"]]]))
        let refusedController = await refused.start()
        refusedController.setPhone("670000000")
        refusedController.submitMobileMoney()
        await waitUntil("failed") { refusedController.state == .failed }
        guard case .failed(let error) = refusedController.screen else { return XCTFail("not failed") }
        XCTAssertEqual(error.code, WajubError.Code.securityCheckFailed)
        XCTAssertTrue(error.retryable)
        XCTAssertEqual(refused.transport.requests("POST", "/pay/process").count, 2)
        XCTAssertEqual(refused.transport.requests("GET", "/pay/session").count, 2, "one reload")
        refusedController.hostGone()

        // The same on /pay/client-session.
        let cardRefused = Harness(config: "sdk-config-card-paystack")
        cardRefused.transport.on("GET", "/pay/session", .json(200, session))
        cardRefused.transport.on("POST", "/pay/client-session", .json(422, ["code": 422, "message": "Security challenge verification failed",
                                                                           "errors": ["altcha": ["Security challenge verification failed"]]]))
        let cardRefusedController = await cardRefused.start()
        cardRefusedController.selectMethod("card")
        cardRefusedController.submitCard()
        await waitUntil("failed") { cardRefusedController.state == .failed }
        guard case .failed(let cardError) = cardRefusedController.screen else { return XCTFail("not failed") }
        XCTAssertEqual(cardError.code, WajubError.Code.securityCheckFailed)
        XCTAssertEqual(cardRefused.transport.requests("POST", "/pay/client-session").count, 2)
        cardRefusedController.hostGone()

        // A refusal with a field at fault is a validation error, whatever its message says.
        let fieldRefused = Harness(config: "sdk-config-cm-stripe")
        fieldRefused.transport.on("GET", "/pay/session", .json(200, session))
        fieldRefused.transport.on("POST", "/pay/process", .json(422, ["code": 422, "message": "Security challenge verification failed",
                                                                     "errors": ["data.phone": ["The phone field is required."]]]))
        let fieldController = await fieldRefused.start()
        fieldController.setPhone("670000000")
        fieldController.submitMobileMoney()
        await waitUntil("field error") { fieldController.fieldErrors["data.phone"] != nil }
        XCTAssertEqual(fieldRefused.transport.requests("GET", "/pay/session").count, 1, "no reload")
        fieldController.hostGone()
    }

    /// AL-02 recognises the altcha refusal by its code
    @MainActor func test_AL_02_recognisesTheAltchaRefusalByItsCode() async throws {
        let altcha: JSONValue = ["algorithm": "SHA-256", "challenge": .string(Digest.sha256Hex("s4lt1234")), "salt": "s4lt",
                                 "signature": "sig", "maxnumber": 5000]
        let session = Fixtures.body("session-cm-aggregate").setting(["altcha"], to: altcha)

        // Refused once: the session is reloaded once, solved again, and sent with a new Idempotency-Key.
        let once = Harness(config: "sdk-config-cm-stripe")
        once.transport.on("GET", "/pay/session", .json(200, session))
        once.transport.on("POST", "/pay/process", .fixture("process-422-security-check-failed"),
                          .fixture("process-processing-mobile-money-sandbox"))
        let paying = await once.start()
        paying.setPhone("670000000")
        paying.submitMobileMoney()
        await waitUntil("approval") { paying.state == .approvalRequired }
        let tries = once.transport.requests("POST", "/pay/process")
        XCTAssertEqual(tries.count, 2)
        XCTAssertNotEqual(tries[0].header("Idempotency-Key"), tries[1].header("Idempotency-Key"))
        XCTAssertEqual(once.transport.requests("GET", "/pay/session").count, 2, "one reload")
        XCTAssertNotNil(once.processBodies()[1]["data"]?["altcha"])
        XCTAssertTrue(once.recorder.errors.isEmpty)
        paying.hostGone()

        // By its code, whatever the message says, and even without a challenge on the session: refused
        // twice, FAILED security_check_failed, retryable, no field errors.
        let reworded = Fixtures.body("process-422-security-check-failed").setting(["message"], to: "Nope")
            .setting(["errors"], to: ["request": ["Nope"]])
        for body in [session, Fixtures.body("session-cm-aggregate")] {
            let twice = Harness(config: "sdk-config-cm-stripe")
            twice.transport.on("GET", "/pay/session", .json(200, body))
            twice.transport.on("POST", "/pay/process", .json(422, reworded))
            let controller = await twice.start()
            controller.setPhone("670000000")
            controller.submitMobileMoney()
            await waitUntil("failed") { controller.state == .failed }
            guard case .failed(let error) = controller.screen else { return XCTFail("not failed") }
            XCTAssertEqual(error.code, WajubError.Code.securityCheckFailed)
            XCTAssertTrue(error.retryable)
            XCTAssertTrue(controller.fieldErrors.isEmpty)
            XCTAssertEqual(twice.transport.requests("POST", "/pay/process").count, 2)
            XCTAssertEqual(twice.transport.requests("GET", "/pay/session").count, 2)
            controller.hostGone()
        }

        // On /pay/client-session too.
        let card = Harness(config: "sdk-config-card-paystack")
        card.transport.on("GET", "/pay/session", .json(200, session))
        card.transport.on("POST", "/pay/client-session", .fixture("client-session-422-security-check-failed"),
                          .fixture("client-session-start-202"))
        card.transport.answer("status-processing")
        let cardController = await card.start()
        cardController.selectMethod("card")
        cardController.submitCard()
        await waitUntil("page") { !card.browser.opened.isEmpty }
        XCTAssertEqual(card.transport.requests("POST", "/pay/client-session").count, 2)
        XCTAssertEqual(card.transport.requests("GET", "/pay/session").count, 2)
        cardController.hostGone()
    }

    /// AL-01 solves altcha challenges
    @MainActor func test_AL_01_spendsEachSolutionOnce() async throws {
        func challenge(_ salt: String, _ number: Int) -> JSONValue {
            ["algorithm": "SHA-256", "challenge": .string(Digest.sha256Hex(salt + String(number))), "salt": .string(salt),
             "signature": "sig", "maxnumber": 5000]
        }
        let first = Fixtures.body("session-cm-aggregate").setting(["altcha"], to: challenge("one", 321))
        let second = Fixtures.body("session-cm-aggregate").setting(["altcha"], to: challenge("two", 654))
        let harness = Harness(config: "sdk-config-cm-stripe")
        harness.transport.on("GET", "/pay/session", .json(200, first), .json(200, second))
        harness.transport.answer("process-failed-402")
        let controller = await harness.start()
        controller.setPhone("670000000")
        controller.submitMobileMoney()
        await waitUntil("declined") { controller.state == .failed }
        controller.tryAgain()
        controller.submitMobileMoney()
        await waitUntil("second try") { harness.processBodies().count == 2 }
        XCTAssertEqual(harness.processBodies().map { $0["data"]?["altcha"]?["number"]?.int }, [321, 654],
                       "a new challenge for the second submission")
        XCTAssertEqual(harness.transport.requests("GET", "/pay/session").count, 2)
        controller.hostGone()

        // No fresh challenge (the session reload fails after its retries): nothing is sent, the sheet
        // says so and Pay can be pressed again.
        let offline = Harness(config: "sdk-config-cm-stripe")
        offline.transport.on("GET", "/pay/session", .json(200, first), .failure(.network("offline")), .failure(.network("offline")),
                             .failure(.network("offline")), .failure(.network("offline")), .json(200, second))
        offline.transport.answer("process-failed-402")
        let form = await offline.start()
        form.setPhone("670000000")
        form.submitMobileMoney()
        await waitUntil("declined") { form.state == .failed }
        form.tryAgain()
        form.submitMobileMoney()
        await offline.drive(until: "not sent") { form.banner != nil && !form.isBusy }
        XCTAssertEqual(form.banner?.code, WajubError.Code.securityCheckFailed)
        XCTAssertTrue(form.banner?.retryable ?? false)
        XCTAssertEqual(form.state, .collectingDetails)
        XCTAssertEqual(offline.processBodies().count, 1, "never sent without a fresh solution")
        offline.transport.answer("process-processing-mobile-money-sandbox")
        form.submitMobileMoney()
        await waitUntil("sent") { offline.processBodies().count == 2 }
        XCTAssertEqual(offline.processBodies()[1]["data"]?["altcha"]?["number"]?.int, 654)
        form.hostGone()
    }
}
