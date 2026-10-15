import XCTest
@testable import WajubMobile

/// CH — which channels are shown; CD — card flavours; WL — one-tap wallets.
final class ChannelTests: XCTestCase {
    /// CH-01 shows only supported channels
    func test_CH_01_showsOnlySupportedChannels() {
        let ivorian = Fixtures.session("session-ci-xof-wallets")
        let wallets = Fixtures.config("sdk-config-ci-wallets")
        XCTAssertEqual(MethodResolver.shownChannels(ivorian, config: wallets, hasCardCollector: false).map(\.slug),
                       ["ci.djamo", "ci.mtn", "ci.moov", "ci.orange", "ci.wave"])
        XCTAssertEqual(MethodResolver.methods(ivorian, config: wallets, language: .en, hasCardCollector: false).map(\.id),
                       ["ci.djamo", "mobile_money"])

        let sandbox = Fixtures.session("session-sandbox-cm")
        let methods = MethodResolver.methods(sandbox, config: Fixtures.config("sdk-config-sandbox"), language: .en, hasCardCollector: false)
        XCTAssertEqual(methods.map(\.id), ["mobile_money", "card"])
        XCTAssertEqual(methods[1].kind, .card(.sandboxForm))
        XCTAssertEqual(methods[0].channels.map(\.slug), ["cm.eu", "cm.mobile"])

        var body = Fixtures.body("session-ci-xof-wallets")
        for index in 0..<5 { body = body.setting(["channels", String(index), "type"], to: ["crypto", "bank", "ussd", "bnpl", "redirect"][index]) }
        let unsupported = try! SessionResponse(json: body)
        XCTAssertTrue(MethodResolver.methods(unsupported, config: wallets, language: .en, hasCardCollector: false).isEmpty)
    }

    /// CH-01 shows only supported channels
    @MainActor func test_CH_01_reportsNoPaymentMethod() async {
        var body = Fixtures.body("session-ci-xof-wallets")
        for index in 0..<5 { body = body.setting(["channels", String(index), "type"], to: "crypto") }
        let harness = Harness(config: "sdk-config-ci-wallets")
        harness.transport.on("GET", "/pay/session", .json(200, body))
        let controller = await harness.start()
        guard case .loadError(let error) = controller.screen else { return XCTFail("no load error") }
        XCTAssertEqual(error.code, WajubError.Code.noPaymentMethod)
        XCTAssertEqual(harness.recorder.loadErrors.map(\.code), [WajubError.Code.noPaymentMethod])
    }

    /// CH-02 localises channel names
    func test_CH_02_localisesChannelNames() {
        let sandbox = Fixtures.session("session-sandbox-cm")
        let config = Fixtures.config("sdk-config-sandbox")
        let english = MethodResolver.methods(sandbox, config: config, language: .en, hasCardCollector: false)
        let french = MethodResolver.methods(sandbox, config: config, language: .fr, hasCardCollector: false)
        XCTAssertEqual(english.first { $0.id == "card" }?.name, "Card")
        XCTAssertEqual(french.first { $0.id == "card" }?.name, "Carte bancaire")
        XCTAssertEqual(french.first { $0.id == "mobile_money" }?.name, "Mobile Money")
    }

    /// CH-03 resolves sdk-config for aggregates
    func test_CH_03_resolvesSdkConfigForAggregates() {
        let session = Fixtures.session("session-cm-aggregate")
        let config = Fixtures.config("sdk-config-cm-stripe")
        let aggregate = session.channels.first { $0.slug == "cm.mobile" }!
        XCTAssertNil(config.channels["cm.mobile"])
        XCTAssertEqual(MethodResolver.mobileMoneyConfig(aggregate, operatorSlug: "cm.orange", config: config), config.channels["cm.orange"])
        XCTAssertEqual(MethodResolver.mobileMoneyConfig(aggregate, config: config), config.channels["cm.mtn"])

        let withoutOrange = SdkConfigResponse(json: Fixtures.body("sdk-config-cm-stripe").setting(["channels", "cm.orange", "available"], to: false))
        let choices = MobileMoneyForm.choices(channels: [aggregate], country: "CM", config: withoutOrange, language: .en, amount: 25000)
        XCTAssertEqual(choices.map(\.id), ["mtn"], "available: false hides that operator")
    }

    /// CH-04 defaults mobile money without sdk-config
    func test_CH_04_defaultsMobileMoneyWithoutSdkConfig() {
        let session = Fixtures.session("session-sandbox-cm")
        let config = Fixtures.config("sdk-config-sandbox")
        for channel in session.channels where channel.isMobileMoney {
            let entry = MethodResolver.mobileMoneyConfig(channel, config: config)
            XCTAssertEqual(entry.sdk, "form")
            XCTAssertEqual(entry.requiredFields, ["phone"])
            XCTAssertTrue(entry.available)
        }
        XCTAssertEqual(MethodResolver.shownChannels(session, config: config, hasCardCollector: false).map(\.slug), ["cm.eu", "cm.mobile", "card"])
        XCTAssertEqual(MethodResolver.shownChannels(session, config: nil, hasCardCollector: false).map(\.slug), ["cm.eu", "cm.mobile"],
                       "no sdk-config at all: Mobile Money still shown, card hidden")
    }

    /// CH-05 disables channels out of their limits
    func test_CH_05_disablesChannelsOutOfTheirLimits() throws {
        let config = Fixtures.config("sdk-config-cm-stripe")
        let above = try SessionResponse(json: Fixtures.body("session-cm-aggregate").setting(["transaction", "amount_total"], to: 600_000))
        let aboveMethod = MethodResolver.methods(above, config: config, language: .en, hasCardCollector: true).first { $0.id == "mobile_money" }
        XCTAssertEqual(aboveMethod?.limit, .maximum(500_000))
        XCTAssertEqual(aboveMethod?.isEnabled, false)
        let below = try SessionResponse(json: Fixtures.body("session-cm-aggregate").setting(["transaction", "amount_total"], to: 50))
        XCTAssertEqual(MethodResolver.methods(below, config: config, language: .en, hasCardCollector: true).first { $0.id == "mobile_money" }?.limit,
                       .minimum(100))
        let inside = Fixtures.session("session-cm-aggregate")
        XCTAssertNil(MethodResolver.methods(inside, config: config, language: .en, hasCardCollector: true).first?.limit)
        XCTAssertEqual(WajubStrings(.fr).maximum("500 000 FCFA"), "Maximum 500 000 FCFA")

        // Inside the Mobile Money form, an operator out of its limits is shown disabled, not hidden.
        let narrow = try SessionResponse(json: Fixtures.body("session-ci-xof-wallets").setting(["channels", "1", "max_amount"], to: 1000))
        var form = MobileMoneyForm(channels: narrow.channels.filter(\.isMobileMoney), config: Fixtures.config("sdk-config-ci-wallets"),
                                   language: .en, amount: 15000, options: MobileMoneyOptions(), geoCountry: "CI")
        XCTAssertEqual(form.choices.map(\.id), ["mtn", "moov", "orange", "wave"])
        XCTAssertEqual(form.choices[0].limit, .maximum(1000))
        XCTAssertEqual(form.selection, "moov", "the first operator the payer can use")
        form.pick("mtn")
        XCTAssertEqual(form.selection, "moov", "a disabled operator cannot be picked")
        form.setPhone("0501020304")
        XCTAssertEqual(form.selection, "moov", "nor preselected by detection")
        XCTAssertNil(form.validate(sandbox: false).error, "never a mismatch naming an operator that cannot be picked")

        // Every operator out of its limits: they are all listed with their limits, and Pay is disabled.
        let allOut = try SessionResponse(json: Fixtures.body("session-cm-aggregate").setting(["transaction", "amount_total"], to: 600_000))
        let blocked = MobileMoneyForm(channels: allOut.channels.filter(\.isMobileMoney), config: Fixtures.config("sdk-config-cm-stripe"),
                                      language: .en, amount: 600_000, options: MobileMoneyOptions(), geoCountry: "CM")
        XCTAssertEqual(blocked.choices.map(\.limit), [.maximum(500_000), .maximum(500_000)])
        XCTAssertTrue(blocked.hasNoOperator)
        XCTAssertNil(blocked.selection)
    }

    /// CD-01 picks the card flavour
    func test_CD_01_picksTheCardFlavour() throws {
        let live = Fixtures.session("session-cm-aggregate")
        let card = live.channels.first { $0.type == "card" }!
        func flavour(_ config: String, sandbox: Bool = false, collector: Bool = true) -> CardFlavour? {
            MethodResolver.cardFlavour(card, config: Fixtures.config(config), sandbox: sandbox, hasCardCollector: collector)
        }
        XCTAssertEqual(flavour("sdk-config-card-paystack"), .clientSession(fields: ["email"]))
        XCTAssertEqual(flavour("sdk-config-card-adyen"), .clientSession(fields: []), "Adyen's encrypted_* fields are not collected")
        XCTAssertEqual(flavour("sdk-config-cm-stripe"), .stripe(publishableKey: "pk_live_51Hx4mPLACEHOLDER"))
        XCTAssertNil(flavour("sdk-config-cm-stripe", collector: false), "no card collector: Stripe is hidden")
        XCTAssertEqual(flavour("sdk-config-card-cinetpay"),
                       .hostedRedirect(fields: ["first_name", "last_name", "email", "phone", "address", "city", "country", "zip_code"]))
        XCTAssertEqual(flavour("sdk-config-card-kkiapay"), .hostedRedirect(fields: ["email"]))
        XCTAssertEqual(flavour("sdk-config-card-mollie"), .hostedRedirect(fields: []))
        XCTAssertEqual(flavour("sdk-config-sandbox", sandbox: true), .sandboxForm)
        XCTAssertNil(flavour("sdk-config-sandbox", sandbox: false), "form in live is hidden")
        XCTAssertNil(flavour("sdk-config-ci-wallets"), "no card entry")
        let unavailable = SdkConfigResponse(json: Fixtures.body("sdk-config-card-paystack").setting(["channels", "card", "available"], to: false))
        XCTAssertNil(MethodResolver.cardFlavour(card, config: unavailable, sandbox: false, hasCardCollector: true))
        let unknown = SdkConfigResponse(json: Fixtures.body("sdk-config-card-kkiapay").setting(["channels", "card", "sdk"], to: "paystack_inline"))
        XCTAssertNil(MethodResolver.cardFlavour(card, config: unknown, sandbox: false, hasCardCollector: true))
        let inlineWithoutSession = SdkConfigResponse(json: Fixtures.body("sdk-config-card-paystack").setting(["channels", "card", "client_session"], to: false))
        XCTAssertNil(MethodResolver.cardFlavour(card, config: inlineWithoutSession, sandbox: false, hasCardCollector: true))
    }

    /// CD-02 collects hosted card required fields
    @MainActor func test_CD_02_collectsHostedCardRequiredFields() async throws {
        let harness = Harness(session: "session-cm-aggregate", config: "sdk-config-card-cinetpay")
        harness.transport.answer("process-redirect-card-hosted")
        let controller = await harness.start()
        controller.selectMethod("card")
        let form = try XCTUnwrap(controller.cardForm)
        XCTAssertEqual(form.fields, ["first_name", "last_name", "email", "phone", "address", "city", "country", "zip_code"])
        XCTAssertEqual(form.values, ["first_name": "Awa", "last_name": "Ngono", "email": "awa.ngono@example.com"], "prefilled from the customer")
        controller.submitCard()
        XCTAssertEqual(Set(controller.fieldErrors.keys), ["phone", "address", "city", "country", "zip_code"])
        XCTAssertTrue(harness.processBodies().isEmpty)
        for (field, value) in ["phone": "+237677123456", "address": "Rue 1.234", "city": "Douala", "country": "cm", "zip_code": "00237"] {
            controller.setCardField(field, value)
        }
        controller.submitCard()
        await waitUntil("browser opened") { controller.state == .pending && !harness.browser.opened.isEmpty }
        let body = try XCTUnwrap(harness.processBodies().first)
        XCTAssertEqual(body["channel"]?.string, "card")
        XCTAssertEqual(Set(body["data"]?.object?.keys.map { $0 } ?? []), Set(form.fields + ["_client"]), "exactly required_fields, flat")
        XCTAssertEqual(body["data"]?["country"]?.string, "CM")
        XCTAssertEqual(harness.recorder.redirects, ["https://checkout.psp.example/pay/abc123"])
        XCTAssertEqual(harness.browser.opened.first?.mode, .inApp)
        controller.hostGone()
    }

    /// CD-01 picks the card flavour
    @MainActor func test_CD_01_treatsACollectedCardAsAnAttempt() async {
        // The attempt starts with the Pay press: a dismiss while the card is tokenized resolves
        // `processing`, cancels nothing, and no charge follows once the sheet has closed.
        let collector = HeldCollector()
        let harness = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        harness.collector = collector
        harness.transport.answer("process-processing-mobile-money-sandbox", "cancel-200")
        let controller = await harness.start()
        controller.selectMethod("card")
        controller.submitCard()
        await waitUntil("collecting") { collector.pending != nil }
        XCTAssertEqual(controller.state, .collectingDetails, "collecting a card is not PROCESSING")
        controller.dismiss()
        XCTAssertEqual(controller.result?.status, "processing")
        collector.finish("pm_123")
        await settle()
        XCTAssertTrue(harness.processBodies().isEmpty, "no charge after the sheet closed")
        XCTAssertTrue(harness.transport.requests("POST", "/pay/cancel").isEmpty)

        // Collected while the sheet is open: the pm_ is sent.
        let open = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        let openCollector = HeldCollector()
        open.collector = openCollector
        open.transport.answer("process-processing-mobile-money-sandbox")
        let openController = await open.start()
        openController.selectMethod("card")
        openController.submitCard()
        await waitUntil("collecting") { openCollector.pending != nil }
        openCollector.finish("pm_123")
        await waitUntil("sent") { open.processBodies().count == 1 }
        XCTAssertEqual(open.processBodies()[0]["data"]?["payment_method_id"]?.string, "pm_123")
        openController.hostGone()
    }

    /// CD-01 picks the card flavour
    @MainActor func test_CD_01_showsACollectorErrorOnTheCardForm() async throws {
        // A collector's own error is a catalogue code on the card form, not a code of its own.
        let harness = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        let collector = HeldCollector()
        harness.collector = collector
        let controller = await harness.start()
        controller.selectMethod("card")
        let catalogue = WajubError.catalogue(WajubError.Code.validationError, controller.language)

        // Stripe's errors are NSErrors with a description for the payer: shown as it is.
        controller.submitCard()
        await waitUntil("collecting") { collector.pending != nil }
        collector.fail(NSError(domain: "com.stripe.lib", code: 70,
                               userInfo: [NSLocalizedDescriptionKey: "Your card's security code is incorrect."]))
        await waitUntil("shown") { controller.banner != nil }
        var banner = try XCTUnwrap(controller.banner)
        XCTAssertEqual(banner.code, WajubError.Code.validationError)
        XCTAssertEqual(banner.type, catalogue.type)
        XCTAssertTrue(banner.retryable)
        XCTAssertEqual(banner.message, "Your card's security code is incorrect.")
        XCTAssertEqual(controller.state, .collectingDetails, "back on the card form")
        XCTAssertFalse(controller.isCollectingCard)

        // An error without one: the catalogue's message, the error's text kept for the logs.
        struct Opaque: Error {}
        controller.submitCard()
        await waitUntil("collecting again") { collector.pending != nil }
        collector.fail(Opaque())
        await waitUntil("shown again") { controller.banner != nil }
        banner = try XCTUnwrap(controller.banner)
        XCTAssertEqual(banner.code, WajubError.Code.validationError)
        XCTAssertEqual(banner.message, catalogue.message)
        XCTAssertEqual(banner.apiMessage, "Opaque()")

        // A WajubError is shown as it is.
        controller.submitCard()
        await waitUntil("collecting a third time") { collector.pending != nil }
        collector.fail(WajubError.catalogue(WajubError.Code.networkError, controller.language))
        await waitUntil("shown a third time") { controller.banner != nil }
        XCTAssertEqual(controller.banner?.code, WajubError.Code.networkError)

        XCTAssertTrue(harness.processBodies().isEmpty, "nothing was sent")
        XCTAssertTrue(harness.recorder.errors.isEmpty, "a form error, like field validation")

        // A LocalizedError's description, in either language.
        struct Described: LocalizedError { var errorDescription: String? { "Carte refusée par Stripe." } }
        XCTAssertEqual(CheckoutController.cardCollectionError(Described(), language: .fr).message, "Carte refusée par Stripe.")
        XCTAssertEqual(CheckoutController.cardCollectionError(Opaque(), language: .fr).message, "Vérifiez les informations saisies.")
        controller.hostGone()
    }

    /// CD-03 never sends raw card data in live
    @MainActor func test_CD_03_neverSendsRawCardDataInLive() async {
        // A live session never offers the sandbox test-card form…
        let live = Harness(session: "session-cm-aggregate", config: "sdk-config-sandbox")
        let controller = await live.start()
        XCTAssertFalse(controller.methods.contains { $0.id == "card" })
        // …and card fields never leave the device in live, whatever asks for them.
        controller.pay(channel: "card", data: ["card.number": "4242424242424242", "cvc": "123", "exp": "12/30"], family: "card", mobileMoney: false)
        await settle()
        XCTAssertTrue(live.processBodies().isEmpty)
        guard case .failed(let error) = controller.screen else { return XCTFail("not refused") }
        XCTAssertEqual(error.code, WajubError.Code.rawCardDataNotAccepted)

        // The API's own refusal maps to the same code.
        let refusal = WajubError.from(APIAnswer(status: 422, body: Fixtures.body("process-422-raw-card-data-live")), phase: .payment, language: .en)
        XCTAssertEqual(refusal.code, WajubError.Code.rawCardDataNotAccepted)
        XCTAssertFalse(refusal.retryable)

        // In sandbox the test card is sent.
        let sandbox = Harness(session: "session-sandbox-cm")
        sandbox.transport.answer("process-requires-3ds-sandbox")
        let test = await sandbox.start()
        test.selectMethod("card")
        for (field, value) in ["card.number": "4000056655665556", "card_holder": "Awa Ngono", "expiry_month": "12", "expiry_year": "30", "cvv": "123"] {
            test.setCardField(field, value)
        }
        test.submitCard()
        await waitUntil("3DS") { test.state == .threeDSRequired }
        XCTAssertEqual(sandbox.processBodies().first?["data"]?["card.number"]?.string, "4000056655665556")
        test.hostGone()
    }

    /// WL-01 pays one-tap wallets
    @MainActor func test_WL_01_paysOneTapWallets() async throws {
        let harness = Harness(session: "session-ci-xof-wallets", config: "sdk-config-ci-wallets")
        harness.transport.answer("process-redirect-wallet-djamo")
        let controller = await harness.start()
        XCTAssertEqual(controller.state, .initiated)
        controller.selectMethod("ci.djamo")
        XCTAssertEqual(controller.state, .collectingDetails)
        controller.payWallet()
        await waitUntil("redirect") { controller.state == .pending && !harness.browser.opened.isEmpty }
        let body = try XCTUnwrap(harness.processBodies().first)
        XCTAssertEqual(body["channel"]?.string, "ci.djamo")
        XCTAssertEqual(Set(body["data"]?.object?.keys.map { $0 } ?? []), ["_client"])
        XCTAssertEqual(harness.recorder.redirects, ["https://djamo.ci/?type=payment_confirmation&id=abc"])
        XCTAssertEqual(harness.browser.opened.map(\.url.absoluteString), ["https://djamo.ci/?type=payment_confirmation&id=abc"])
        XCTAssertEqual(harness.browser.opened.first?.mode, .external, "the wallet's page opens its app")
        guard case .pending(let pending) = controller.screen else { return XCTFail("not pending") }
        XCTAssertEqual(pending.continueURL, "https://djamo.ci/?type=payment_confirmation&id=abc")
        controller.hostGone()
    }

    /// WL-02 follows a wave redirect
    @MainActor func test_WL_02_followsAWaveRedirect() async throws {
        let harness = Harness(session: "session-ci-xof-wallets", config: "sdk-config-ci-wallets")
        harness.transport.answer("process-redirect-wave")
        let controller = await harness.start()
        controller.selectMethod("mobile_money")
        controller.pickOperator("wave")
        controller.setPhone("07 01 02 03 04")
        controller.submitMobileMoney()
        await waitUntil("redirect") { controller.state == .pending && !harness.browser.opened.isEmpty }
        let body = try XCTUnwrap(harness.processBodies().first)
        XCTAssertEqual(body["channel"]?.string, "ci.wave")
        XCTAssertEqual(body["data"]?["phone"]?.string, "+2250701020304")
        XCTAssertNil(body["data"]?["operator"], "not an aggregate")
        XCTAssertEqual(harness.recorder.redirects, ["https://pay.wave.com/c/cos-1x2y3z?a=10000&c=XOF&m=Maquis"])
        XCTAssertEqual(harness.browser.opened.first?.mode, .external)
        controller.hostGone()
    }
}

/// A card collector that answers when the test says so.
@MainActor
final class HeldCollector: CardCollector {
    var pending: CheckedContinuation<String?, Error>?

    func collectPaymentMethod(_ request: CardCollectionRequest) async throws -> String? {
        try await withCheckedThrowingContinuation { pending = $0 }
    }

    func finish(_ paymentMethod: String?) {
        pending?.resume(returning: paymentMethod)
        pending = nil
    }

    func fail(_ error: Error) {
        pending?.resume(throwing: error)
        pending = nil
    }
}
