import XCTest
@testable import WajubMobile

/// What the payer pays on each channel (CH-07, ST-06), and the code the payer generates in their
/// operator's menu (MM-11 to MM-14, PA-10, ST-01).
final class PayerTests: XCTestCase {
    // MARK: Fees

    /// CH-07 shows what the payer pays on the chosen channel
    @MainActor func test_CH_07_showsWhatThePayerPaysOnTheChosenChannel() async throws {
        let harness = Harness(session: "session-payer-fee-per-channel", config: "sdk-config-sandbox")
        harness.transport.answer("process-payer-fee-on-channel-sandbox", "status-processing")
        let controller = await harness.start()
        XCTAssertEqual(controller.state, .initiated)
        XCTAssertEqual(controller.payableAmount, 10200, "before a method is chosen, the payment's total")

        // The card channel's own price.
        controller.selectMethod("card")
        XCTAssertEqual(controller.payableAmount, 10200)
        controller.backToMethods()

        // Mobile Money: the selected operator's price, following the number live.
        controller.selectMethod("mobile_money")
        XCTAssertEqual(controller.mobileMoney?.selection, "mtn")
        XCTAssertEqual(controller.payableAmount, 10200)
        controller.setPhone("690000000")
        XCTAssertEqual(controller.mobileMoney?.selection, "orange")
        XCTAssertEqual(controller.payableAmount, 10450)
        XCTAssertEqual(controller.formattedAmount, controller.formatAmount(10450))
        controller.pickOperator("mtn")
        XCTAssertEqual(controller.payableAmount, 10200, "a pick by hand decides")
        controller.pickOperator("orange")

        // After the 2xx, what was charged.
        controller.submitMobileMoney()
        await waitUntil("approval") { controller.state == .approvalRequired }
        XCTAssertEqual(controller.payableAmount, 10450)
        controller.hostGone()

        // Without the fields, the payment's total as before.
        let plain = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        let plainController = await plain.start()
        plainController.setPhone("690000000")
        XCTAssertEqual(plainController.payableAmount, plainController.session?.transaction.amountTotal)
        plainController.hostGone()

        // The channel's limits are compared with its own price.
        let session = try SessionResponse(json: Fixtures.body("session-payer-fee-per-channel")
            .setting(["channels", "1", "max_amount"], to: 10100))
        let card = MethodResolver.methods(session, config: Fixtures.config("sdk-config-sandbox"), language: .en, hasCardCollector: false)
            .first { $0.id == "card" }
        XCTAssertEqual(card?.limit, .maximum(10100), "10 200 on card is over the limit, 10 000 alone is not")
    }

    /// ST-06 builds PaymentSuccess
    @MainActor func test_ST_06_carriesTheChargedAmount() async {
        let harness = Harness(session: "session-payer-fee-per-channel", config: "sdk-config-sandbox")
        harness.transport.answer("process-payer-fee-on-channel-sandbox")
        harness.transport.on("GET", "/pay/status", .json(200, ["transaction": ["reference": "trx", "status": "succeeded"]]))
        let controller = await harness.start()
        controller.selectMethod("mobile_money")
        controller.setPhone("690000000")
        controller.submitMobileMoney()
        await waitUntil("approval") { controller.state == .approvalRequired }
        await harness.advance(by: 5)
        await waitUntil("paid") { controller.state == .success }
        XCTAssertEqual(harness.recorder.successes.first?.amount, 10450, "Orange's price, not the session's 10 200")
        controller.hostGone()
    }

    // MARK: The payer's own code

    /// MM-11 asks for the payer's code before the charge
    @MainActor func test_MM_11_asksForThePayersCodeBeforeTheCharge() async throws {
        let harness = Harness(session: "session-payer-otp-announced", config: "sdk-config-sandbox")
        harness.transport.answer("process-payer-otp-accepted-sandbox", "status-processing")
        let controller = await harness.start()
        controller.selectMethod("mobile_money")
        controller.setPhone("70000000")
        let announced = try XCTUnwrap(controller.mobileMoney?.announcedPayerOTP, "the form says a code will be generated")
        XCTAssertEqual(announced.ussdCode, "*144*4*6#")
        XCTAssertEqual(WajubStrings(.en).payerOTPFormHint(ussdCode: announced.ussdCode),
                       "For this payment, you will generate a code by dialing *144*4*6#: the next step guides you.")

        // Pay opens the code screen without calling the API.
        controller.submitMobileMoney()
        await settle()
        XCTAssertTrue(harness.processBodies().isEmpty)
        XCTAssertNotNil(controller.payerOTP)
        XCTAssertEqual(controller.stateName, "PAYER_OTP_REQUIRED")
        XCTAssertEqual(controller.state, .collectingDetails)

        // The code goes with the first charge.
        controller.submitPayerOTP("123456")
        await waitUntil("sent") { harness.processBodies().count == 1 }
        let body = harness.processBodies()[0]
        XCTAssertEqual(body["channel"]?.string, "bf.orange")
        XCTAssertEqual(body["data"]?["otp"]?.string, "123456")
        XCTAssertEqual(body["data"]?["phone"]?.string, "+22670000000")
        await waitUntil("approval") { controller.state == .approvalRequired }
        guard case .approval(let approval) = controller.screen else { return XCTFail("no approval") }
        XCTAssertTrue(approval.payerOTPReceived)
        XCTAssertEqual(harness.recorder.started.count, 1)
        controller.hostGone()

        // A channel that announces nothing pays at once.
        let plain = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        plain.transport.answer("process-processing-mobile-money-sandbox")
        let plainController = await plain.start()
        plainController.setPhone("670000000")
        XCTAssertNil(plainController.mobileMoney?.announcedPayerOTP)
        plainController.submitMobileMoney()
        await waitUntil("sent") { plain.processBodies().count == 1 }
        XCTAssertNil(plainController.payerOTP)
        plainController.hostGone()
    }

    /// The BF session without the announcement: the charge asks for the code.
    @MainActor private func askedHarness(_ answers: FakeTransport.Reply...) async -> Harness {
        let body = Fixtures.body("session-payer-otp-announced").setting(["channels", "0", "payer_otp"], to: nil)
        let harness = Harness(config: "sdk-config-sandbox")
        harness.transport.on("GET", "/pay/session", .json(200, body))
        harness.transport.on("POST", "/pay/process", replies: answers)
        harness.transport.answer("status-processing")
        let controller = await harness.start()
        controller.selectMethod("mobile_money")
        controller.setPhone("70000000")
        XCTAssertNil(controller.mobileMoney?.announcedPayerOTP)
        controller.submitMobileMoney()
        await waitUntil("code screen") { controller.payerOTP != nil }
        return harness
    }

    /// MM-12 asks for the payer's code the charge asks for
    @MainActor func test_MM_12_asksForThePayersCodeTheChargeAsksFor() async throws {
        let harness = await askedHarness(.fixture("process-payer-otp-required"), .fixture("process-payer-otp-accepted-sandbox"))
        let controller = harness.controller!
        let screen = try XCTUnwrap(controller.payerOTP)
        XCTAssertEqual(controller.stateName, "PAYER_OTP_REQUIRED")
        XCTAssertTrue(harness.recorder.stateNames.contains("PAYER_OTP_REQUIRED"))
        XCTAssertTrue(harness.recorder.started.isEmpty, "nothing charged: no onPaymentStarted")
        XCTAssertEqual(screen.instructions.ussdCode, "*144*4*6#")
        XCTAssertEqual(screen.exactAmount, "1000 XOF", "the amount as sent, not reformatted")
        XCTAssertEqual(screen.lengthRange, 6...6)
        XCTAssertEqual(screen.sandboxCode, "123456")
        // The steps of the sheet's language, from their template: the code to dial and the amount stand out.
        let language = controller.language.rawValue
        let expected = Fixtures.body("process-payer-otp-required")["payer_otp"]?["steps"]?[language]?.array ?? []
        XCTAssertEqual(screen.steps.map(\.text), expected.compactMap { $0["text"]?.string })
        XCTAssertTrue(screen.steps[0].parts.contains(.ussdCode("*144*4*6#")))
        XCTAssertTrue(screen.steps[1].parts.contains(.amount("1000")))

        // A code that fails the check is not sent.
        controller.submitPayerOTP("12")
        XCTAssertEqual(harness.processBodies().count, 1)
        XCTAssertEqual(controller.payerOTP?.message, controller.strings.payerOTPLength(6))
        controller.submitPayerOTP("12345a")
        XCTAssertEqual(harness.processBodies().count, 1)

        // The same request with the code, under a new Idempotency-Key.
        controller.submitPayerOTP("123456")
        await waitUntil("sent") { harness.processBodies().count == 2 }
        let first = harness.transport.requests("POST", "/pay/process")[0]
        let second = harness.transport.requests("POST", "/pay/process")[1]
        XCTAssertNotEqual(first.header("Idempotency-Key"), second.header("Idempotency-Key"))
        XCTAssertEqual(harness.processBodies()[1]["data"]?["otp"]?.string, "123456")
        XCTAssertEqual(harness.processBodies()[1]["data"]?["phone"], harness.processBodies()[0]["data"]?["phone"])
        await waitUntil("approval") { controller.state == .approvalRequired }
        guard case .approval(let approval) = controller.screen else { return XCTFail("no approval") }
        XCTAssertTrue(approval.payerOTPReceived)
        controller.hostGone()

        // "Use another payment method": back to the Mobile Money form.
        let leaving = await askedHarness(.fixture("process-payer-otp-required"))
        leaving.controller.leavePayerOTP()
        XCTAssertNil(leaving.controller.payerOTP)
        XCTAssertEqual(leaving.controller.state, .collectingDetails)
        XCTAssertEqual(leaving.controller.stateName, "COLLECTING_DETAILS")
        leaving.controller.hostGone()

        // No steps: the generic ones, with the exact amount.
        var bare = Fixtures.body("process-payer-otp-required")["payer_otp"]!
        bare = bare.setting(["steps"], to: [:]).setting(["otp_length"], to: nil)
        let generic = PayerOTPScreen(instructions: PayerOTPInstructions(json: bare), language: .en, sandbox: false)
        XCTAssertEqual(generic.steps.map(\.text), ["Open your operator's Mobile Money menu (USSD code or app).",
                                                   "Generate a payment code for the exact amount: 1000 XOF.",
                                                   "Enter the code you received below."])
        XCTAssertEqual(generic.lengthRange, 4...8)
        XCTAssertNil(generic.sandboxCode)
        // A template naming something else, or a value missing: the step's text.
        let odd = bare.setting(["steps"], to: ["en": [["text": "Dial it.", "template": "Dial {pin}."],
                                                      ["text": "Dial the code.", "template": "Dial {ussd_code}."]]])
            .setting(["ussd_code"], to: nil)
        XCTAssertEqual(PayerOTPScreen(instructions: PayerOTPInstructions(json: odd), language: .fr, sandbox: false).steps.map(\.text),
                       ["Dial it.", "Dial the code."], "English when the sheet's language has none")

        // The lower-level client says the same.
        let low = Harness(session: "session-payer-otp-announced")
        low.transport.answer("process-payer-otp-required")
        guard case .requiresAction(let action) = await low.client.process(channel: "bf.orange", data: ["phone": "+22670000000"]) else {
            return XCTFail("no action")
        }
        XCTAssertEqual(action.action, .payerOTP)
        XCTAssertEqual(action.payerOTP?.otpLength, 6)
        XCTAssertEqual(action.payerOTP?.reason, "required")
        XCTAssertEqual(action.payerOTP?.attemptsRemaining, 3)
    }

    /// MM-13 handles refused payer codes
    @MainActor func test_MM_13_handlesRefusedPayerCodes() async throws {
        // Malformed: the screen again with the length message, not onError.
        let invalid = await askedHarness(.fixture("process-payer-otp-required"), .fixture("process-payer-otp-invalid"))
        invalid.controller.submitPayerOTP("654321")
        await waitUntil("answered") { invalid.processBodies().count == 2 && !invalid.controller.isBusy }
        XCTAssertEqual(invalid.controller.payerOTP?.message, invalid.controller.strings.payerOTPLength(6))
        XCTAssertNil(invalid.controller.payerOTP?.attemptsRemaining)
        XCTAssertTrue(invalid.recorder.errors.isEmpty)
        invalid.controller.hostGone()

        // Refused by the operator: the refused message and the tries left.
        let refused = await askedHarness(.fixture("process-payer-otp-required"), .fixture("process-payer-otp-refused"))
        refused.controller.submitPayerOTP("654321")
        await waitUntil("answered") { refused.processBodies().count == 2 && !refused.controller.isBusy }
        XCTAssertEqual(refused.controller.payerOTP?.message, refused.controller.strings.payerOTPRefused)
        XCTAssertEqual(refused.controller.payerOTP?.attemptsRemaining, 2)
        XCTAssertEqual(WajubStrings(.en).payerOTPAttemptsRemaining(2), "2 tries left.")
        XCTAssertEqual(WajubStrings(.fr).payerOTPAttemptsRemaining(1), "Il vous reste 1 essai.")
        XCTAssertTrue(refused.recorder.errors.isEmpty)
        XCTAssertEqual(refused.controller.stateName, "PAYER_OTP_REQUIRED")
        refused.controller.hostGone()

        // Too many codes refused: the Mobile Money form with that error, and onError.
        let exceeded = await askedHarness(.fixture("process-payer-otp-required"), .fixture("process-402-payer-otp-attempts-exceeded"))
        exceeded.controller.submitPayerOTP("654323")
        await waitUntil("back on the form") { exceeded.controller.banner != nil }
        XCTAssertNil(exceeded.controller.payerOTP)
        XCTAssertEqual(exceeded.controller.state, .collectingDetails)
        XCTAssertEqual(exceeded.controller.banner?.code, WajubError.Code.otpAttemptsExceeded)
        XCTAssertEqual(exceeded.recorder.errors.map(\.code), [WajubError.Code.otpAttemptsExceeded])
        XCTAssertTrue(exceeded.controller.canCancelPayment, "still payable another way, and cancellable")
        exceeded.controller.hostGone()

        // Refused later, while watching: back to the code screen, no count shown.
        let later = await askedHarness(.fixture("process-payer-otp-required"), .fixture("process-payer-otp-accepted-sandbox"))
        later.transport.on("GET", "/pay/status", .fixture("status-pending-payer-otp-refused"))
        later.controller.submitPayerOTP("123456")
        await waitUntil("approval") { later.controller.state == .approvalRequired }
        await later.advance(by: 5)
        XCTAssertNotNil(later.controller.payerOTP)
        XCTAssertEqual(later.controller.payerOTP?.message, later.controller.strings.payerOTPRefused)
        XCTAssertNil(later.controller.payerOTP?.attemptsRemaining)
        XCTAssertEqual(later.controller.stateName, "PAYER_OTP_REQUIRED")
        later.controller.hostGone()

        // otp_attempts_exceeded while watching: the form with that error.
        let lateExceeded = await askedHarness(.fixture("process-payer-otp-required"), .fixture("process-payer-otp-accepted-sandbox"))
        lateExceeded.transport.on("GET", "/pay/status", .json(200, Fixtures.body("status-pending-payer-otp-refused")
            .setting(["transaction", "error_code"], to: "otp_attempts_exceeded")))
        lateExceeded.controller.submitPayerOTP("123456")
        await waitUntil("approval") { lateExceeded.controller.state == .approvalRequired }
        await lateExceeded.advance(by: 5)
        XCTAssertEqual(lateExceeded.controller.banner?.code, WajubError.Code.otpAttemptsExceeded)
        XCTAssertEqual(lateExceeded.controller.state, .collectingDetails)
        XCTAssertNil(lateExceeded.controller.payerOTP)
        lateExceeded.controller.hostGone()
    }

    /// PA-10 fires payment started on the first 2xx
    @MainActor func test_PA_10_firesPaymentStartedOnTheCodesAnswerOnly() async {
        let harness = await askedHarness(.fixture("process-payer-otp-required"), .fixture("process-payer-otp-accepted-sandbox"))
        XCTAssertTrue(harness.recorder.started.isEmpty, "the payer_otp answer charged nothing")
        harness.controller.submitPayerOTP("123456")
        await waitUntil("started") { harness.recorder.started.count == 1 }
        XCTAssertEqual(harness.recorder.started.first?.channel, "bf.orange")
        harness.controller.hostGone()
    }

    /// ST-01 reports Wajub.js states
    @MainActor func test_ST_01_namesThePayerCodeState() async {
        let harness = await askedHarness(.fixture("process-payer-otp-required"), .fixture("process-payer-otp-accepted-sandbox"))
        harness.controller.submitPayerOTP("123456")
        await waitUntil("approval") { harness.controller.state == .approvalRequired }
        XCTAssertEqual(Array(harness.recorder.stateNames.suffix(4)),
                       ["PROCESSING", "PAYER_OTP_REQUIRED", "PROCESSING", "APPROVAL_REQUIRED"])
        // `state` keeps 1.0.0's cases: the code screen is a Mobile Money form for it.
        XCTAssertFalse(CheckoutState.allCases.map(\.rawValue).contains("PAYER_OTP_REQUIRED"))
        harness.controller.hostGone()
    }

    /// MM-14 offers the operator's code to dial
    func test_MM_14_offersTheOperatorsCodeToCopyOnly() throws {
        // iOS cannot dial * and # from a link: the code screen copies it, and has no dial link.
        let view = try String(contentsOf: Fixtures.packageRoot.appendingPathComponent("Sources/WajubMobileUI/PayerOTPView.swift"),
                              encoding: .utf8)
        XCTAssertTrue(view.contains("UIPasteboard.general.string = ussdCode"))
        for link in ["tel:", "openURL", "Link(", "UIApplication.shared.open"] {
            XCTAssertFalse(view.contains(link), "no dial link: \(link)")
        }
        XCTAssertEqual(WajubStrings(.en).payerOTPSandboxHint(PayerOTPScreen.sandboxCode),
                       "Test mode: enter the code 123456. Any other code is refused.")
        XCTAssertEqual(WajubStrings(.fr).payerOTPSandboxHint(PayerOTPScreen.sandboxCode),
                       "Mode test : saisissez le code 123456. Tout autre code est refusé.")
    }

    // MARK: Edge cases (README §6.7)

    /// MM-13 handles refused payer codes
    @MainActor func test_MM_13_takesARefusedCodeAsTheBaseline() async {
        // After a refused code, a status still carrying that refusal is not a new one.
        let harness = await askedHarness(.fixture("process-payer-otp-required"), .fixture("process-payer-otp-refused"),
                                         .failure(.timeout))
        let controller = harness.controller!
        controller.submitPayerOTP("654321")
        await waitUntil("refused") { controller.payerOTP?.attemptsRemaining == 2 }
        XCTAssertEqual(controller.lastErrorCode, WajubError.Code.invalidOTP)
        harness.transport.on("GET", "/pay/status", .fixture("status-pending-payer-otp-refused"))
        controller.submitPayerOTP("111111")
        await harness.drive(until: "pending") { controller.state == .pending }
        await harness.advance(by: 5)
        XCTAssertEqual(controller.state, .pending, "the same refusal is not news")
        XCTAssertNotEqual(controller.stateName, CheckoutController.payerOTPRequiredName)
        XCTAssertTrue(harness.recorder.errors.isEmpty)
        controller.hostGone()
    }

    /// MM-13 handles refused payer codes
    @MainActor func test_MM_13_handlesARefusalNoCodeOfThisSheetLedTo() async {
        // A code sent elsewhere was refused: back to the form with the refused text, not FAILED, no onError.
        let harness = await Harness.mobileMoney(answers: "process-processing-mobile-money-sandbox")
        harness.transport.on("GET", "/pay/status", .fixture("status-pending-payer-otp-refused"))
        harness.controller.submitMobileMoney()
        await waitUntil("approval") { harness.controller.state == .approvalRequired }
        await harness.advance(by: 5)
        XCTAssertEqual(harness.controller.state, .collectingDetails)
        XCTAssertEqual(harness.controller.banner?.message, harness.controller.strings.payerOTPRefused)
        XCTAssertTrue(harness.recorder.errors.isEmpty)
        XCTAssertFalse(harness.controller.banner?.message.contains("{") ?? true)
        harness.controller.hostGone()

        // No catalogue message ever shows a raw placeholder.
        for language in WajubLanguage.allCases {
            for code in ErrorCatalogue.entries.keys {
                let message = WajubError.catalogue(code, language).message
                XCTAssertFalse(message.contains("{"), "\(code) \(language): \(message)")
                XCTAssertFalse(message.isEmpty, code)
            }
        }
        let update = StatusUpdate(status: .pending, errorCode: WajubError.Code.invalidOTP)
        XCTAssertEqual(harness.controller.attemptEndedError(update).message.contains("{"), false)
    }

    /// MM-13 handles refused payer codes
    @MainActor func test_MM_13_doesNotOfferAnExhaustedChannelAgain() async {
        let harness = await askedHarness(.fixture("process-payer-otp-required"), .fixture("process-402-payer-otp-attempts-exceeded"))
        let controller = harness.controller!
        controller.submitPayerOTP("654323")
        await waitUntil("back on the form") { controller.banner != nil }
        let choice = controller.mobileMoney?.choices.first { $0.channelSlug == "bf.orange" }
        XCTAssertEqual(choice?.isAvailable, false, "shown disabled")
        XCTAssertEqual(choice?.unavailableReason, controller.banner?.message)
        XCTAssertNotEqual(controller.mobileMoney?.selection, choice?.id, "the selection moves off it")
        // Pay never reopens the code screen there.
        controller.submitMobileMoney()
        await settle()
        XCTAssertNil(controller.payerOTP)
        XCTAssertEqual(harness.processBodies().count, 2)
        controller.hostGone()
    }

    /// MM-13 handles refused payer codes
    @MainActor func test_MM_13_handlesMissingFieldsAndSteps() async {
        // payer_otp without its object: unsupported_action, and nothing charged.
        let missing = await Harness.mobileMoney()
        missing.transport.on("POST", "/pay/process", .json(202, Fixtures.body("process-payer-otp-required").setting(["payer_otp"], to: nil)))
        missing.controller.submitMobileMoney()
        await waitUntil("failed") { missing.controller.state == .failed }
        guard case .failed(let error) = missing.controller.screen else { return XCTFail("not failed") }
        XCTAssertEqual(error.code, WajubError.Code.unsupportedAction)
        XCTAssertTrue(missing.recorder.started.isEmpty)
        missing.controller.hostGone()

        // No amount: no amount box, and the generic step without it.
        let base = Fixtures.body("process-payer-otp-required")["payer_otp"]!
        let noAmount = PayerOTPInstructions(json: base.setting(["amount"], to: "").setting(["steps"], to: [:]))
        let english = PayerOTPScreen(instructions: noAmount, language: .en, sandbox: false)
        XCTAssertNil(english.exactAmount)
        XCTAssertEqual(english.steps[1].text, "Generate a payment code for the exact amount.")
        XCTAssertEqual(PayerOTPScreen(instructions: noAmount, language: .fr, sandbox: false).steps[1].text,
                       "Générez un code de paiement pour le montant exact.")
        XCTAssertTrue(english.steps.allSatisfy { !$0.text.contains("{") && !$0.text.contains(" XOF") })

        // A plain-string step is its text; an empty list counts as none.
        let steps = PayerOTPInstructions(json: base.setting(["steps"], to: ["fr": [], "en": ["Dial the code.", ["text": "Enter it."]]]))
        XCTAssertNil(steps.steps["fr"])
        XCTAssertEqual(PayerOTPScreen(instructions: steps, language: .fr, sandbox: false).steps.map(\.text), ["Dial the code.", "Enter it."])

        // An otp_length outside 1 to 12: none; a negative attempts_remaining: none left.
        for length: JSONValue in [-1, 0, 13] {
            let instructions = PayerOTPInstructions(json: base.setting(["otp_length"], to: length))
            XCTAssertNil(instructions.otpLength, "\(length)")
            XCTAssertEqual(PayerOTPScreen(instructions: instructions, language: .en, sandbox: false).lengthRange, 4...8)
        }
        let negative = PayerOTPInstructions(json: base.setting(["attempts_remaining"], to: -2))
        XCTAssertEqual(negative.attemptsRemaining, 0)
        XCTAssertEqual(WajubStrings(.en).payerOTPAttemptsRemaining(negative.attemptsRemaining ?? 0), "No tries left.")
    }

    /// MM-13 handles refused payer codes
    @MainActor func test_MM_13_keepsTheTriesLeftAndTheCodeStepOnARetry() async throws {
        // The tries left stay after a code fails the local check.
        let refused = await askedHarness(.fixture("process-payer-otp-required"), .fixture("process-payer-otp-refused"))
        refused.controller.submitPayerOTP("654321")
        await waitUntil("refused") { refused.controller.payerOTP?.attemptsRemaining == 2 }
        let refusals = refused.controller.payerOTP?.refusals
        refused.controller.submitPayerOTP("12")
        XCTAssertEqual(refused.controller.payerOTP?.attemptsRemaining, 2)
        XCTAssertEqual(refused.controller.payerOTP?.refusals, refusals, "the local check does not empty the field")
        refused.controller.hostGone()

        // A security retry of the code keeps the code step: the same code, the same flow.
        let retried = await askedHarness(.fixture("process-payer-otp-required"), .fixture("process-422-security-check-failed"),
                                         .fixture("process-payer-otp-accepted-sandbox"))
        retried.controller.submitPayerOTP("123456")
        await waitUntil("approval") { retried.controller.state == .approvalRequired }
        XCTAssertEqual(retried.processBodies().count, 3)
        XCTAssertEqual(retried.processBodies()[2]["data"]?["otp"]?.string, "123456")
        guard case .approval(let approval) = retried.controller.screen else { return XCTFail("no approval") }
        XCTAssertTrue(approval.payerOTPReceived)
        retried.transport.on("GET", "/pay/status", .fixture("status-pending-payer-otp-refused"))
        await retried.advance(by: 5)
        XCTAssertNotNil(retried.controller.payerOTP, "still the code step's flow")
        retried.controller.hostGone()
    }

    /// CH-07 shows what the payer pays on the chosen channel
    @MainActor func test_CH_07_showsTheSelectionsAmountAgainAfterAnAttemptEnded() async throws {
        let harness = Harness(session: "session-payer-fee-per-channel", config: "sdk-config-sandbox")
        harness.transport.answer("process-payer-fee-on-channel-sandbox")
        harness.transport.on("GET", "/pay/status", .fixture("status-pending-attempt-refused"))
        let controller = await harness.start()
        controller.selectMethod("mobile_money")
        controller.setPhone("690000000")
        controller.submitMobileMoney()
        await waitUntil("approval") { controller.state == .approvalRequired }
        XCTAssertEqual(controller.payableAmount, 10450)
        await harness.advance(by: 5)
        XCTAssertEqual(controller.state, .failed)
        controller.tryAgain()
        controller.pickOperator("mtn")
        XCTAssertEqual(controller.payableAmount, 10200, "the selection's again, not the ended attempt's")
        controller.backToMethods()
        XCTAssertEqual(controller.payableAmount, 10200)
        controller.hostGone()

        // A limit is compared with the chosen operator's price.
        let session = try SessionResponse(json: Fixtures.body("session-payer-fee-per-channel").setting(["channels", "0", "max_amount"], to: 10300))
        let choices = MobileMoneyForm.choices(channels: session.channels, country: "CM", config: Fixtures.config("sdk-config-sandbox"),
                                              language: .en, amount: session.transaction.amountTotal)
        XCTAssertNil(choices.first { $0.id == "mtn" }?.limit)
        XCTAssertEqual(choices.first { $0.id == "orange" }?.limit, .maximum(10300))
    }
}
