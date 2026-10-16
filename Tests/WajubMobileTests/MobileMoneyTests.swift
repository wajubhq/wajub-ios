import XCTest
@testable import WajubMobile

/// MM — Mobile Money: the shared data, detection, validation, choices and request.
final class MobileMoneyTests: XCTestCase {
    let data = MobileMoneyData.shared

    /// MM-01 matches the number vectors
    func test_MM_01_matchesTheNumberVectors() {
        let vectors = Fixtures.vectors["numbers"]?.array ?? []
        XCTAssertFalse(vectors.isEmpty)
        for vector in vectors {
            let input = vector["input"]?.string ?? ""
            let country = vector["country"]?.string ?? ""
            let label = "\(country) \(input)"
            XCTAssertEqual(data.nationalDigits(input, country: country), vector["national_digits"]?.string, label)
            XCTAssertEqual(data.isValid(input, country: country), vector["valid"]?.bool, label)
            XCTAssertEqual(data.detectOperator(input, country: country), vector["detected_operator"]?.string, label)
            XCTAssertEqual(data.e164(input, country: country), vector["e164"]?.string, label)
            XCTAssertEqual(data.formatAsYouType(input), vector["formatted"]?.string, label)
        }
    }

    /// MM-02 matches the mismatch vectors
    func test_MM_02_matchesTheMismatchVectors() {
        let vectors = Fixtures.vectors["validation_and_mismatch"]?.array ?? []
        XCTAssertFalse(vectors.isEmpty)
        for vector in vectors {
            let country = vector["country"]?.string ?? ""
            let phone = vector["phone"]?.string ?? ""
            let sandbox = vector["sandbox"]?.bool ?? false
            XCTAssertEqual(data.detectOperator(phone, country: country, sandbox: sandbox), vector["detected"]?.string, "\(country) \(phone)")
            let code = MobileMoneyForm.validationCode(phone: phone, country: country, choiceIds: vector["choices"]?.strings ?? [],
                                                      selection: vector["selected"]?.string, data: data, sandbox: sandbox)
            XCTAssertEqual(code, vector["expected"]?.string, "\(country) \(phone) \(vector["selected"]?.string ?? "")")
        }
        XCTAssertEqual(MobileMoneyForm.validationCode(phone: "677123456", country: "CM", choiceIds: [], selection: nil, data: data),
                       WajubError.Code.operatorRequired)
    }

    /// MM-03 matches the preselection vectors
    func test_MM_03_matchesThePreselectionVectors() {
        let vectors = Fixtures.vectors["preselection"]?.array ?? []
        XCTAssertFalse(vectors.isEmpty)
        for vector in vectors {
            let choices = vector["choices"]?.strings ?? []
            let country = vector["country"]?.string ?? ""
            let phone = vector["phone"]?.string ?? ""
            var selection = MobileMoneyForm.initialSelection(choiceIds: choices, data: data)
            var pickedByHand = false
            if let picked = vector["picked_by_hand"]?.string {
                selection = picked
                pickedByHand = true
            }
            selection = MobileMoneyForm.preselect(current: selection, pickedByHand: pickedByHand,
                                                  detected: data.detectOperator(phone, country: country), choiceIds: choices)
            XCTAssertEqual(selection, vector["expected_selection"]?.string, "\(country) \(phone)")
        }

        // The same rules in the form itself.
        var form = makeForm("session-cm-aggregate")
        XCTAssertEqual(form.selection, "mtn")
        form.setPhone("691234567")
        XCTAssertEqual(form.selection, "orange")
        XCTAssertFalse(form.pickedByHand)
        form.pick("mtn")
        form.setPhone("69123456")
        XCTAssertEqual(form.selection, "mtn", "a pick by hand is never overridden")

        // Before any number, never a wallet that takes any number: Express Union comes first here.
        var sandbox = makeForm("session-sandbox-cm", config: "sdk-config-sandbox")
        XCTAssertEqual(sandbox.choices.map(\.id), ["eu", "mtn", "orange"])
        XCTAssertEqual(sandbox.selection, "mtn")
        sandbox.setPhone("691234567")
        XCTAssertEqual(sandbox.selection, "orange", "then detection decides")
    }

    /// MM-03 matches the preselection vectors
    func test_MM_03_keepsThePickVisibleInDetectMode() {
        let session = Fixtures.session("session-cm-aggregate")
        var form = MobileMoneyForm(channels: session.channels.filter(\.isMobileMoney), config: nil, language: .en, amount: 25000,
                                   options: MobileMoneyOptions(operatorMode: .detect), geoCountry: "CM")
        XCTAssertFalse(form.isOperatorListVisible)
        XCTAssertNil(form.badgeChoice, "nothing detected yet, two operators")
        form.setPhone("691234567")
        XCTAssertFalse(form.isOperatorListVisible)
        XCTAssertEqual(form.badgeChoice?.id, "orange")
        XCTAssertEqual(form.selection, "orange")
        form.pick("mtn")
        XCTAssertTrue(form.isOperatorListVisible, "a pick by hand stays in view")
        form.setPhone("6912345678")
        XCTAssertTrue(form.isOperatorListVisible)
        XCTAssertEqual(form.selection, "mtn")
        form.setPhone("691234567")
        XCTAssertEqual(form.validate()?.code, WajubError.Code.operatorMismatch,
                       "the list it names is on screen")
        XCTAssertEqual(form.validate()?.message,
                       "This number belongs to Orange Money. Pick Orange Money in the list, or enter a MTN MoMo number.")
    }

    /// MM-03 matches the preselection vectors
    func test_MM_03_saysWhenTheNumbersOperatorCannotTakeTheAmount() throws {
        let narrow = try SessionResponse(json: Fixtures.body("session-ci-xof-wallets").setting(["channels", "1", "max_amount"], to: 1000))
        var form = MobileMoneyForm(channels: narrow.channels.filter(\.isMobileMoney), config: Fixtures.config("sdk-config-ci-wallets"),
                                   language: .fr, amount: 15000, options: MobileMoneyOptions(operatorMode: .detect), geoCountry: "CI")
        XCTAssertNil(form.unavailableDetected)
        form.setPhone("0501020304")
        XCTAssertEqual(form.unavailableDetected?.id, "mtn", "an MTN number, MTN out of its limits")
        XCTAssertTrue(form.isOperatorListVisible, "never another operator with the list hidden")
        XCTAssertNotEqual(form.badgeChoice?.id, "mtn")
        XCTAssertEqual(WajubStrings(.fr).operatorOutOfLimits("MTN MoMo", limit: WajubStrings(.fr).maximum("1 000 F CFA")),
                       "MTN MoMo ne peut pas être utilisé pour ce montant (Maximum 1 000 F CFA). Choisissez un autre opérateur ou moyen de paiement.")
        XCTAssertEqual(WajubStrings(.en).operatorOutOfLimits("MTN MoMo", limit: "Maximum XOF 1,000"),
                       "MTN MoMo can't be used for this amount (Maximum XOF 1,000). Choose another operator or payment method.")
    }

    /// MM-04 lists aggregate operators
    func test_MM_04_listsAggregateOperators() {
        let aggregate = makeForm("session-cm-aggregate")
        XCTAssertEqual(aggregate.choices.map(\.id), ["mtn", "orange"])
        XCTAssertEqual(aggregate.choices.map(\.label), ["MTN MoMo", "Orange Money"])
        XCTAssertEqual(aggregate.choices.map(\.channelSlug), ["cm.mobile", "cm.mobile"])
        XCTAssertEqual(aggregate.choices.map(\.operatorSlug), ["cm.mtn", "cm.orange"])
        XCTAssertEqual(aggregate.choices.map(\.logoURL), ["https://assets.wajub.com/img/channels/momo.svg",
                                                          "https://assets.wajub.com/img/channels/om.svg"], "the operator's logo, as in 1.0.0")
        XCTAssertEqual(aggregate.choices.map(\.drawableLogoURL), ["https://api.wajub.com/img/channels/momo.png",
                                                                  "https://api.wajub.com/img/channels/om.png"], "PNG logos (CH-06)")
        XCTAssertTrue(aggregate.choices.allSatisfy(\.isAggregateMember))

        let ivorian = makeForm("session-ci-xof-wallets", config: "sdk-config-ci-wallets")
        XCTAssertEqual(ivorian.country, "CI")
        XCTAssertEqual(ivorian.choices.map(\.id), ["mtn", "moov", "orange", "wave"])
        XCTAssertEqual(ivorian.choices.map(\.channelSlug), ["ci.mtn", "ci.moov", "ci.orange", "ci.wave"])
        XCTAssertEqual(ivorian.choices.map(\.label), ["MTN MoMo", "Moov Money", "Orange Money", "Wave"])
        XCTAssertFalse(ivorian.choices.contains { $0.isAggregateMember })
        XCTAssertEqual(ivorian.choices.first { $0.id == "wave" }?.isOperatorIndependent, true)
    }

    /// MM-05 builds the mobile money request
    @MainActor func test_MM_05_buildsTheMobileMoneyRequest() async {
        let hints = Fixtures.vectors["operator_hint"]?.array ?? []
        XCTAssertFalse(hints.isEmpty)
        for vector in hints {
            let slug = vector["channel"]?.string ?? ""
            let session = Fixtures.session(slug.hasPrefix("cm") ? "session-cm-aggregate" : "session-ci-xof-wallets")
            let channel = session.channels.first { $0.slug == slug }!
            let hint = MobileMoneyForm.operatorHint(isAggregate: channel.isAggregate, selection: vector["selected"]?.string ?? "",
                                                    pickedByHand: vector["picked_by_hand"]?.bool ?? false,
                                                    detected: vector["detected"]?.string)
            XCTAssertEqual(hint, vector["send_operator"]?.string, vector["why"]?.string ?? slug)
        }

        let harness = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        harness.transport.answer("process-processing-mobile-money-sandbox")
        let controller = await harness.start()
        controller.setPhone("670000000")
        controller.submitMobileMoney()
        await waitUntil("process sent") { harness.processBodies().count == 1 }
        defer { controller.hostGone() }
        let body = harness.processBodies()[0]
        let reference = Fixtures.envelope("process-processing-mobile-money-sandbox")["request"]?["body"]
        XCTAssertEqual(body["channel"], reference?["channel"])
        XCTAssertEqual(body["data"]?["phone"], reference?["data"]?["phone"])
        XCTAssertEqual(body["data"]?["country"], reference?["data"]?["country"])
        XCTAssertEqual(body["data"]?["operator"], reference?["data"]?["operator"])
        XCTAssertEqual(Set(body["data"]?.object?.keys.map { $0 } ?? []), ["phone", "country", "operator", "_client"])

        // A default the payer never touched, with a number no rule names, is not sent; a pick by hand is.
        for pick in [nil, "orange"] as [String?] {
            let other = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
            other.transport.answer("process-processing-mobile-money-sandbox")
            let form = await other.start()
            form.setPhone("622345678")
            if let pick { form.pickOperator(pick) }
            form.submitMobileMoney()
            await waitUntil("process sent") { other.processBodies().count == 1 }
            XCTAssertEqual(other.processBodies()[0]["data"]?["operator"]?.string, pick)
            XCTAssertNil(other.processBodies()[0]["data"]?["return_url"])
            form.hostGone()
        }
    }

    /// MM-06 shows the approval screen
    @MainActor func test_MM_06_showsTheApprovalScreen() async {
        for fixture in ["process-processing-mobile-money-live", "process-processing-mobile-money-sandbox"] {
            let harness = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
            harness.transport.answer(fixture, "status-processing")
            let controller = await harness.start()
            controller.setPhone("677123456")
            controller.submitMobileMoney()
            await waitUntil("approval") { controller.state == .approvalRequired }
            guard case .approval(let approval) = controller.screen else { return XCTFail("no approval screen") }
            XCTAssertEqual(approval.instruction,
                           "Confirm the transaction on your phone. If no prompt appears, dial *126# to complete.")
            XCTAssertEqual(approval.phone, "+237677123456")
            await harness.advance(by: 5)
            await waitUntil("status polled") { !harness.transport.requests("GET", "/pay/status").isEmpty }
            XCTAssertEqual(controller.state, .approvalRequired)
            controller.hostGone()
        }
    }

    /// MM-07 falls back to brand badges
    func test_MM_07_fallsBackToBrandBadges() {
        let ivorian = makeForm("session-ci-xof-wallets", config: "sdk-config-ci-wallets")
        let moov = ivorian.choices.first { $0.id == "moov" }!
        XCTAssertNil(moov.logoURL, "ci.moov has no logo")
        XCTAssertEqual(moov.badge, OperatorBadge(text: "Moov", color: "#fff", background: "#005BAC"))
        let mpesa = data.badge(operatorId: "mpesa", fallbackName: "M-Pesa")
        XCTAssertEqual(mpesa.text, "MPESA", "no mark: the first 8 alphanumerics of the label, upper-cased")

        let sandbox = makeForm("session-sandbox-cm")
        let expressUnion = sandbox.choices.first { $0.id == "eu" }!
        XCTAssertNil(expressUnion.logoURL)
        XCTAssertEqual(expressUnion.label, "Express Union Mobile")
        XCTAssertEqual(expressUnion.badge, OperatorBadge(text: "EXPRESSU", color: "#ffffff", background: "#525252"))

        let insecure = Fixtures.body("session-ci-xof-wallets").setting(["channels", "1", "logo"], to: "http://cdn.example/mtn.svg")
        let form = MobileMoneyForm(channels: try! SessionResponse(json: insecure).channels.filter(\.isMobileMoney), config: nil,
                                   language: .en, amount: 15000, options: MobileMoneyOptions(), geoCountry: "CI")
        XCTAssertNil(form.choices.first { $0.id == "mtn" }?.logoURL, "only https logos")
    }

    /// MM-08 reads mismatches in sandbox from the test number
    @MainActor func test_MM_08_readsMismatchesInSandboxFromTheTestNumber() async {
        // In a sandbox payment, Express Union's test number on MTN is a mismatch, and blocks as in live.
        let harness = Harness(session: "session-sandbox-cm")
        harness.transport.answer("process-processing-mobile-money-sandbox")
        let controller = await harness.start()
        controller.selectMethod("mobile_money")
        controller.setPhone("680000000")
        XCTAssertEqual(controller.mobileMoney?.detectedOperator, "eu")
        controller.pickOperator("mtn")
        controller.submitMobileMoney()
        await settle()
        XCTAssertTrue(harness.processBodies().isEmpty)
        XCTAssertEqual(controller.fieldErrors["data.phone"]?.code, WajubError.Code.operatorMismatch)
        // On the operator it tests, it goes through.
        controller.pickOperator("eu")
        controller.submitMobileMoney()
        await waitUntil("process sent in sandbox") { harness.processBodies().count == 1 }
        XCTAssertEqual(harness.processBodies()[0]["channel"]?.string, "cm.eu")
        controller.hostGone()

        // The same mismatch in live blocks the submission.
        let live = Fixtures.body("session-sandbox-cm").setting(["transaction", "sandbox"], to: false)
        let liveHarness = Harness(config: "sdk-config-cm-stripe")
        liveHarness.transport.on("GET", "/pay/session", .json(200, live))
        let liveController = await liveHarness.start()
        liveController.selectMethod("mobile_money")
        liveController.setPhone("680000000")
        liveController.pickOperator("orange")
        liveController.submitMobileMoney()
        await settle()
        XCTAssertTrue(liveHarness.processBodies().isEmpty)
        XCTAssertEqual(liveController.fieldErrors["data.phone"]?.code, WajubError.Code.operatorMismatch)
        // The device speaks French and the session has no locale: a French sheet.
        XCTAssertEqual(liveController.fieldErrors["data.phone"]?.message,
                       "Ce numéro est un numéro MTN MoMo. Choisissez MTN MoMo dans la liste, ou saisissez un numéro Orange Money.")
    }

    /// MM-09 loads the shared data file
    func test_MM_09_loadsTheSharedDataFile() throws {
        let loaded = try MobileMoneyData.load()
        XCTAssertEqual(loaded.countries.count, 29)
        XCTAssertEqual(loaded.countries["CM"]?.dialCode, "+237")
        XCTAssertEqual(loaded.operatorIndependentWallets, ["wave", "eu", "express_union", "djamo", "capitec", "opay", "palmpay"])

        let source = try Data(contentsOf: Fixtures.packageRoot.appendingPathComponent("Sources/WajubMobile/Resources/mobile-money.json"))
        XCTAssertEqual(try JSONValue.parse(source)["schema_version"]?.int, 2)
        for version in [1, 3] {
            let other = try JSONValue.parse(source).setting(["schema_version"], to: .number(Double(version)))
            XCTAssertThrowsError(try MobileMoneyData(data: other.serialized())) { error in
                XCTAssertEqual(error as? MobileMoneyData.LoadError, .unsupportedSchemaVersion(version))
            }
        }

        // No second copy of the tables in code.
        let sources = Fixtures.packageRoot.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for marker in ["\"+237\"", "\"+225\"", "\"MTN MoMo\"", "\"#FFCC00\""] {
                XCTAssertFalse(text.contains(marker), "\(file.lastPathComponent) hard-codes \(marker)")
            }
        }
    }

    /// MM-10 takes the sandbox test numbers
    @MainActor func test_MM_10_takesTheSandboxTestNumbers() async {
        let vectors = Fixtures.vectors["sandbox_numbers"]?.array ?? []
        XCTAssertFalse(vectors.isEmpty)
        for vector in vectors {
            let input = vector["input"]?.string ?? ""
            let country = vector["country"]?.string ?? ""
            let label = "\(country) \(input)"
            let test = data.sandboxTestNumber(input, country: country)
            XCTAssertEqual(test?.operatorId, vector["operator"]?.string, label)
            XCTAssertEqual(test?.e164, vector["e164"]?.string, label)
            if let operatorId = vector["operator"]?.string, let e164 = vector["e164"]?.string {
                // In a sandbox payment: valid, the prefix's operator, sent as read.
                XCTAssertTrue(data.isValid(input, country: country, sandbox: true), label)
                XCTAssertEqual(data.detectOperator(input, country: country, sandbox: true), operatorId, label)
                XCTAssertEqual(data.e164(input, country: country, sandbox: true), e164, label)
            }
            // Outside a sandbox payment the prefixes mean nothing.
            XCTAssertEqual(data.isValid(input, country: country, sandbox: false), data.isValid(input, country: country), label)
            XCTAssertEqual(data.detectOperator(input, country: country, sandbox: false), data.detectOperator(input, country: country), label)
            XCTAssertEqual(data.e164(input, country: country, sandbox: false), data.e164(input, country: country), label)
        }

        // The sheet: a sandbox payment takes Express Union's test number, sent as typed.
        let sandbox = Harness(session: "session-sandbox-cm", config: "sdk-config-sandbox")
        sandbox.transport.answer("process-processing-mobile-money-sandbox")
        let controller = await sandbox.start()
        controller.selectMethod("mobile_money")
        controller.setPhone("680000000")
        XCTAssertEqual(controller.mobileMoney?.detectedOperator, "eu")
        XCTAssertEqual(controller.mobileMoney?.selection, "eu")
        controller.submitMobileMoney()
        await waitUntil("sent") { sandbox.processBodies().count == 1 }
        XCTAssertEqual(sandbox.processBodies()[0]["data"]?["phone"]?.string, "+237680000000")
        XCTAssertEqual(sandbox.processBodies()[0]["channel"]?.string, "cm.eu")
        controller.hostGone()

        // A live payment: the same number is MTN's.
        let live = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        let liveController = await live.start()
        liveController.selectMethod("mobile_money")
        liveController.setPhone("680000000")
        XCTAssertEqual(liveController.mobileMoney?.detectedOperator, "mtn")
        liveController.hostGone()
    }

    /// MM-10 takes the sandbox test numbers
    @MainActor func test_MM_10_readsSandboxFromTheLoadedPayment() async {
        // A sandbox payment stays one when a later answer's transaction leaves the flag out.
        let sandbox = Harness(session: "session-sandbox-cm", config: "sdk-config-sandbox")
        let silent = Fixtures.body("process-processing-mobile-money-sandbox").setting(["transaction", "sandbox"], to: nil)
        sandbox.transport.on("POST", "/pay/process", .json(202, silent))
        sandbox.transport.answer("status-processing")
        let controller = await sandbox.start()
        XCTAssertTrue(controller.isSandbox)
        controller.selectMethod("mobile_money")
        controller.setPhone("680000000")
        controller.submitMobileMoney()
        await waitUntil("approval") { controller.state == .approvalRequired }
        XCTAssertEqual(controller.transaction?.sandbox, false, "the answer said nothing")
        XCTAssertTrue(controller.isSandbox, "never lowered by a later answer")
        controller.hostGone()

        // A live payment never becomes a sandbox one from an answer.
        let live = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        let loud = Fixtures.body("process-processing-mobile-money-sandbox").setting(["transaction", "sandbox"], to: true)
        live.transport.on("POST", "/pay/process", .json(202, loud))
        live.transport.answer("status-processing")
        let liveController = await live.start()
        XCTAssertFalse(liveController.isSandbox)
        liveController.setPhone("670000000")
        liveController.submitMobileMoney()
        await waitUntil("approval") { liveController.state == .approvalRequired }
        XCTAssertEqual(liveController.transaction?.sandbox, true)
        XCTAssertFalse(liveController.isSandbox, "only the loaded payment says sandbox")
        liveController.hostGone()
    }

    /// Digits typed on an Arabic, Persian or full-width keyboard are read as ASCII digits, in the number,
    /// the confirmation steps and the card fields.
    @MainActor func test_readsDigitsOfOtherKeyboardsAsASCII() async throws {
        for typed in ["٦٧٧ ١٢ ٣٤ ٥٦", "۶۷۷۱۲۳۴۵۶", "６７７１２３４５６", "+٢٣٧ 677 12 34 56"] {
            XCTAssertEqual(data.sanitize(typed), typed.hasPrefix("+") ? "237677123456" : "677123456", typed)
            XCTAssertTrue(data.isValid(typed, country: "CM"), typed)
            XCTAssertEqual(data.detectOperator(typed, country: "CM"), "mtn", typed)
            XCTAssertEqual(data.e164(typed, country: "CM"), "+237677123456", typed)
        }
        XCTAssertEqual(data.sanitize("½ Ⅳ ²"), "", "numbers that are not decimal digits are dropped")
        XCTAssertEqual(data.sandboxTestNumber("٦٨٠٠٠٠٠٠٠", country: "CM")?.e164, "+237680000000")

        // The sheet: the field shows the digits, and Pay sends them in ASCII.
        let harness = await Harness.mobileMoney(answers: "process-processing-mobile-money-sandbox")
        harness.controller.setPhone("٦٧٠ ٠٠ ٠٠ ٠٠")
        XCTAssertEqual(harness.controller.mobileMoney?.phone, "670000000")
        XCTAssertEqual(harness.controller.mobileMoney?.formattedPhone, "67 00 00 00 0")
        harness.controller.submitMobileMoney()
        await waitUntil("sent") { harness.processBodies().count == 1 }
        XCTAssertEqual(harness.processBodies()[0]["data"]?["phone"]?.string, "+237670000000")
        harness.controller.hostGone()

        // A confirmation step's code, in ASCII; a number that is not a decimal digit is refused.
        let step = Harness(session: "session-cm-aggregate", config: "sdk-config-card-kkiapay")
        step.transport.answer("process-requires-otp", "status-processing", "pin-verify-success")
        let controller = await step.start()
        controller.selectMethod("card")
        controller.submitCard()
        await waitUntil("otp") { controller.state == .otpRequired }
        controller.submitStep(["code": "Ⅳ２３４５６"])
        XCTAssertNotNil(controller.fieldErrors["code"])
        XCTAssertTrue(step.transport.requests("POST", "/pay/otp/verify").isEmpty)
        step.transport.on("POST", "/pay/otp/verify", .fixture("pin-verify-success"))
        controller.submitStep(["code": "١٢٣٤٥٦"])
        await waitUntil("verified") { !step.transport.requests("POST", "/pay/otp/verify").isEmpty }
        XCTAssertEqual(step.transport.requests("POST", "/pay/otp/verify")[0].json?["code"]?.string, "123456")
        controller.hostGone()

        // The card fields, in ASCII.
        var card = CardForm(flavour: .sandboxForm, customer: nil)
        card.values = ["card.number": "٤٢٤٢ ٤٢٤٢ ٤٢٤٢ ٤٢٤٢", "card_holder": "Awa Ngono", "expiry_month": "١٢",
                       "expiry_year": "۲۰۳۰", "cvv": "١٢٣"]
        XCTAssertEqual(card.payload["card.number"], "4242 4242 4242 4242")
        XCTAssertEqual(card.payload["expiry_year"], "2030")
        XCTAssertEqual(card.payload["cvv"], "123")
        XCTAssertEqual(card.payload["card_holder"], "Awa Ngono")
    }

    private func makeForm(_ session: String, config: String? = nil) -> MobileMoneyForm {
        let session = Fixtures.session(session)
        return MobileMoneyForm(channels: session.channels.filter(\.isMobileMoney), config: config.map(Fixtures.config),
                               language: .en, amount: session.transaction.amountTotal, options: MobileMoneyOptions(),
                               geoCountry: session.geoCountry)
    }
}
