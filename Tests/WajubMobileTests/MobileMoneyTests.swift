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
            XCTAssertEqual(data.detectOperator(phone, country: country), vector["detected"]?.string, "\(country) \(phone)")
            let code = MobileMoneyForm.validationCode(phone: phone, country: country, choiceIds: vector["choices"]?.strings ?? [],
                                                      selection: vector["selected"]?.string, data: data)
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
            var selection = choices.first
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
        XCTAssertEqual(form.validate(sandbox: false).error?.code, WajubError.Code.operatorMismatch,
                       "the list it names is on screen")
        XCTAssertEqual(form.validate(sandbox: false).error?.message,
                       "This number belongs to Orange Money. Pick Orange Money in the list, or enter a MTN MoMo number.")
    }

    /// MM-04 lists aggregate operators
    func test_MM_04_listsAggregateOperators() {
        let aggregate = makeForm("session-cm-aggregate")
        XCTAssertEqual(aggregate.choices.map(\.id), ["mtn", "orange"])
        XCTAssertEqual(aggregate.choices.map(\.label), ["MTN MoMo", "Orange Money"])
        XCTAssertEqual(aggregate.choices.map(\.channelSlug), ["cm.mobile", "cm.mobile"])
        XCTAssertEqual(aggregate.choices.map(\.operatorSlug), ["cm.mtn", "cm.orange"])
        XCTAssertEqual(aggregate.choices.map(\.logoURL), ["https://assets.wajub.com/img/channels/momo.svg",
                                                          "https://assets.wajub.com/img/channels/om.svg"])
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

    /// MM-08 does not block mismatches in sandbox
    @MainActor func test_MM_08_doesNotBlockMismatchesInSandbox() async {
        let harness = Harness(session: "session-sandbox-cm")
        harness.transport.answer("process-processing-mobile-money-sandbox")
        let controller = await harness.start()
        controller.selectMethod("mobile_money")
        controller.setPhone("680000000")
        controller.pickOperator("orange")
        controller.submitMobileMoney()
        await waitUntil("process sent in sandbox") { harness.processBodies().count == 1 }
        XCTAssertEqual(controller.warning?.code, WajubError.Code.operatorMismatch)

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
        XCTAssertEqual(loaded.countries.count, 23)
        XCTAssertEqual(loaded.countries["CM"]?.dialCode, "+237")
        XCTAssertEqual(loaded.operatorIndependentWallets, ["wave", "eu", "express_union", "djamo", "capitec", "opay", "palmpay"])

        let source = try Data(contentsOf: Fixtures.packageRoot.appendingPathComponent("Sources/WajubMobile/Resources/mobile-money.json"))
        let future = try JSONValue.parse(source).setting(["schema_version"], to: 2)
        XCTAssertThrowsError(try MobileMoneyData(data: future.serialized())) { error in
            XCTAssertEqual(error as? MobileMoneyData.LoadError, .unsupportedSchemaVersion(2))
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

    private func makeForm(_ session: String, config: String? = nil) -> MobileMoneyForm {
        let session = Fixtures.session(session)
        return MobileMoneyForm(channels: session.channels.filter(\.isMobileMoney), config: config.map(Fixtures.config),
                               language: .en, amount: session.transaction.amountTotal, options: MobileMoneyOptions(),
                               geoCountry: session.geoCountry)
    }
}
