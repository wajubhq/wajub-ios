import Foundation

/// The method list and the forms: Mobile Money, card, one-tap wallets.
extension CheckoutController {
    // MARK: Methods

    /// Opens a method's form (`COLLECTING_DETAILS`).
    public func selectMethod(_ id: String) {
        guard result == nil, !isWorking, let method = methods.first(where: { $0.id == id }), method.isEnabled else { return }
        openForm(method)
        screen = .form
        update()
    }

    /// Back to the method list.
    public func backToMethods() {
        guard canGoBack else { return }
        payerOTP = nil
        payerOTPRequest = nil
        screen = .methods
        banner = nil
        fieldErrors = [:]
        update()
    }

    func openForm(_ method: CheckoutMethod) {
        currentMethod = method
        banner = nil
        fieldErrors = [:]
        payerOTP = nil
        payerOTPRequest = nil
        switch method.kind {
        case .mobileMoney:
            if mobileMoney == nil, let session {
                mobileMoney = MobileMoneyForm(channels: method.channels, config: config, language: language,
                                              amount: session.transaction.amountTotal, options: options.mobileMoney,
                                              geoCountry: session.geoCountry, sandbox: isSandbox)
            }
        case .card(let flavour):
            if cardForm?.flavour != flavour {
                cardForm = CardForm(flavour: flavour, customer: session?.transaction.customer)
            }
        case .wallet:
            break
        }
    }

    // MARK: Mobile Money (README §6)

    public func setCountry(_ code: String) {
        mobileMoney?.setCountry(code)
        fieldErrors = [:]
        update()
    }

    public func setPhone(_ text: String) {
        mobileMoney?.setPhone(text)
        fieldErrors["data.phone"] = nil
        update()
    }

    public func pickOperator(_ id: String) {
        mobileMoney?.pick(id)
        fieldErrors["data.operator"] = nil
        fieldErrors["data.phone"] = nil
        update()
    }

    public func openOperatorList() {
        mobileMoney?.openList()
        update()
    }

    /// Validates the Mobile Money form and pays.
    public func submitMobileMoney() {
        guard result == nil, !isWorking, let form = mobileMoney else { return }
        if form.hasNoOperator {
            banner = .catalogue(WajubError.Code.operatorUnavailable, language)
            update()
            return
        }
        if let error = form.validate() {
            // The payer is told to pick in the list: show it.
            if error.code == WajubError.Code.operatorMismatch || error.code == WajubError.Code.operatorRequired {
                mobileMoney?.openList()
            }
            fieldErrors = [error.param ?? "data.phone": error]
            update()
            return
        }
        guard let request = form.request(returnURL: options.returnURL) else { return }
        payerOTPRequest = (request.channel, request.data, request.data["phone"]?.string)
        if let announced = form.announcedPayerOTP {
            // The operator will want the payer's own code: ask for it first, nothing is sent yet.
            showPayerOTP(announced)
            return
        }
        pay(channel: request.channel, data: request.data, family: "mobile_money", mobileMoney: true,
            phone: request.data["phone"]?.string)
    }

    // MARK: The payer's own code (README §6.7)

    /// The code screen: the steps to get the code, the code to dial, the exact amount.
    func showPayerOTP(_ instructions: PayerOTPInstructions, message: String? = nil, attemptsRemaining: Int? = nil) {
        isBusy = false
        var screen = PayerOTPScreen(instructions: instructions, language: language, sandbox: isSandbox)
        screen.message = message
        screen.attemptsRemaining = attemptsRemaining
        // An answer refusing a code empties the field.
        screen.refusals = (payerOTP?.refusals ?? 0) + (message == nil ? 0 : 1)
        payerOTP = screen
        banner = nil
        fieldErrors = [:]
        self.screen = .form
        update()
    }

    /// Pays with the code the payer generated in their operator's menu. The code is checked first
    /// (digits, the expected length); one that fails it is not sent.
    public func submitPayerOTP(_ code: String) {
        guard result == nil, !isWorking, case .form = screen, let screen = payerOTP, let request = payerOTPRequest else { return }
        let code = Digits.ascii(code).trimmingCharacters(in: .whitespaces)
        guard Digits.isASCIIDigits(code), screen.lengthRange.contains(code.count) else {
            let range = screen.lengthRange
            // The tries left stay shown.
            payerOTP?.message = strings.payerOTPLength(screen.instructions.otpLength, min: range.lowerBound, max: range.upperBound)
            update()
            return
        }
        var data = request.data
        data["otp"] = .string(code)
        // A new press of Pay: a new Idempotency-Key.
        reusableKey = nil
        payerOTP?.message = nil
        pay(channel: request.channel, data: data, family: "mobile_money", mobileMoney: true, phone: request.phone)
        attempt?.payerOTP = screen.instructions
    }

    /// "Use another payment method" on the code screen: back to the Mobile Money form.
    public func leavePayerOTP() {
        guard result == nil, !isWorking, payerOTP != nil else { return }
        payerOTP = nil
        payerOTPRequest = nil
        attempt = nil
        screen = .form
        update()
    }

    // MARK: Card (README §7, §11)

    public func setCardField(_ field: String, _ value: String) {
        cardForm?.values[field] = value
        fieldErrors[field] = nil
        update()
    }

    /// Pays by card: through your card collector (Stripe), on the provider's page after the contact
    /// fields it asks for, or with the sandbox test card.
    public func submitCard() {
        guard result == nil, !isWorking, case .card(let flavour)? = currentMethod?.kind, let form = cardForm else { return }
        let errors = form.validate(language)
        guard errors.isEmpty else {
            fieldErrors = errors
            update()
            return
        }
        var data: [String: JSONValue] = form.payload.mapValues(JSONValue.string)
        switch flavour {
        case .stripe(let publishableKey):
            collectCard(publishableKey: publishableKey)
        case .clientSession:
            startClientSession(fields: form.payload)
        case .hostedRedirect:
            if let returnURL = options.returnURL { data["return_url"] = .string(returnURL) }
            pay(channel: "card", data: data, family: "card", mobileMoney: false)
        case .sandboxForm:
            if let returnURL = options.returnURL { data["return_url"] = .string(returnURL) }
            pay(channel: "card", data: data, family: "card", mobileMoney: false)
        }
    }

    func collectCard(publishableKey: String) {
        guard let collector = options.cardCollector, let transaction = session?.transaction else { return }
        // The attempt starts with the Pay press: while the card is tokenized, a dismiss resolves
        // `processing` and cancels nothing.
        let attempt = Attempt(family: "card", channel: currentMethod?.channels.first?.slug ?? "card", startedAt: clock.uptime)
        self.attempt = attempt
        isCollectingCard = true
        banner = nil
        update()
        let request = CardCollectionRequest(publishableKey: publishableKey, amount: transaction.amountTotal,
                                            currency: transaction.currency, customerEmail: transaction.customer?.email,
                                            customerName: transaction.customer?.name, language: language)
        workTask = Task { [weak self] in
            do {
                let paymentMethod = try await collector.collectPaymentMethod(request)
                guard let self else { return }
                self.isCollectingCard = false
                // The sheet may have closed meanwhile: no charge after that.
                guard self.isCurrent(attempt.key), case .form = self.screen else { return }
                guard let paymentMethod else {
                    self.attempt = nil
                    self.update()
                    return
                }
                var data: [String: JSONValue] = ["payment_method_id": .string(paymentMethod)]
                if let returnURL = self.options.returnURL { data["return_url"] = .string(returnURL) }
                self.pay(channel: "card", data: data, family: "card", mobileMoney: false)
            } catch {
                guard let self else { return }
                self.isCollectingCard = false
                guard self.isCurrent(attempt.key), case .form = self.screen else { return }
                self.attempt = nil
                self.banner = (error as? WajubError) ?? Self.cardCollectionError(error, language: self.language)
                self.update()
            }
        }
    }

    /// A collector's own error, on the card form: `validation_error`, with the error's description when
    /// it has one for the payer (Stripe's errors do), else the catalogue's; its text kept in `apiMessage`.
    static func cardCollectionError(_ error: Error, language: WajubLanguage) -> WajubError {
        var banner = WajubError.catalogue(WajubError.Code.validationError, language)
        let described = (error as? LocalizedError)?.errorDescription
            ?? ((error as NSError).userInfo[NSLocalizedDescriptionKey] as? String)
        if let described = described?.trimmingCharacters(in: .whitespacesAndNewlines), !described.isEmpty {
            banner.message = described
        }
        banner.apiMessage = String(describing: error)
        return banner
    }

    func startClientSession(fields: [String: String], securityRetry: Bool = false) {
        guard let channel = currentMethod?.channels.first else { return }
        let attempt = Attempt(family: "card", channel: channel.slug, startedAt: clock.uptime)
        self.attempt = attempt
        isBusy = true
        banner = nil
        fieldErrors = [:]
        update()
        let restart = clientSessionFailed
        workTask = Task { [weak self] in
            guard let self else { return }
            let altcha: AltchaSolution?
            switch await self.nextAltcha() {
            case .off:
                altcha = nil
            case .solved(let solution):
                altcha = solution
            case .unavailable:
                guard self.isCurrent(attempt.key) else { return }
                self.notSent(.catalogue(WajubError.Code.securityCheckFailed, self.language))
                return
            }
            guard self.isCurrent(attempt.key) else { return }
            let body = WajubSession.clientSessionBody(fields: fields, returnURL: self.options.returnURL, restart: restart, altcha: altcha)
            let answer: APIAnswer
            do {
                answer = try await self.client.send(.clientSession, body: body)
            } catch is CancellationError {
                return
            } catch {
                guard self.isCurrent(attempt.key) else { return }
                self.attempt?.inFlight = false
                self.fail(WajubSession.transportError(error, self.language))
                return
            }
            guard self.isCurrent(attempt.key) else { return }
            if self.isSecurityRefusal(answer) {
                if securityRetry {
                    self.attempt?.inFlight = false
                    self.fail(.catalogue(WajubError.Code.securityCheckFailed, self.language))
                } else {
                    await self.renewAltcha()
                    self.startClientSession(fields: fields, securityRetry: true)
                }
                return
            }
            self.handlePaymentAnswer(answer, mobileMoney: false, clientSession: true)
        }
    }

    // MARK: Wallets (README §8)

    /// One tap: pays with a wallet and opens its page.
    public func payWallet() {
        guard result == nil, !isWorking, let method = currentMethod, method.kind == .wallet, let channel = method.channels.first else { return }
        var data: [String: JSONValue] = [:]
        if let returnURL = options.returnURL { data["return_url"] = .string(returnURL) }
        pay(channel: channel.slug, data: data, family: "wallet", mobileMoney: false)
    }
}
