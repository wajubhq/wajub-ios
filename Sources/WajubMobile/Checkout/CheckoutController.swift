import Foundation

/// How a provider page is opened.
public enum BrowserMode: Sendable {
    /// Inside the app (`SFSafariViewController`): a hosted card page, 3-D Secure, a client session.
    case inApp
    /// Handed to the system (`UIApplication.open`): a wallet's page, which opens the wallet's app.
    case external
}

/// Opens provider pages in the system browser, never in a WebView. WajubMobileUI implements it.
@MainActor
public protocol BrowserOpening: AnyObject {
    /// Returns `false` when nothing can open `url`. `onClose` is called when an in-app browser is closed.
    func open(_ url: URL, mode: BrowserMode, onClose: @escaping @MainActor () -> Void) async -> Bool
}

/// The checkout's state machine, without any UI: it loads the session, offers the methods, submits
/// payments, follows actions, watches the status and settles `CheckoutResult` exactly once.
///
/// WajubMobileUI draws `screen` and calls the methods below. A host drawing its own sheet can do the same.
@MainActor
public final class CheckoutController {
    public let options: PresentOptions
    let client: WajubSession
    let browser: BrowserOpening
    let connectWebSocket: (URL) -> WebSocketConnection

    public private(set) var screen: CheckoutScreen = .loading
    /// `nil` until the sheet is ready.
    public private(set) var state: CheckoutState?
    public private(set) var language: WajubLanguage
    public private(set) var session: SessionResponse?
    public private(set) var methods: [CheckoutMethod] = []
    public private(set) var currentMethod: CheckoutMethod?
    public private(set) var mobileMoney: MobileMoneyForm?
    public private(set) var cardForm: CardForm?
    /// Field errors, keyed by field (`data.phone`, `data.operator`, `email`, `code`…).
    public private(set) var fieldErrors: [String: WajubError] = [:]
    /// A form-level error not tied to a field.
    public private(set) var banner: WajubError?
    /// Sandbox only: an operator mismatch that does not block.
    public private(set) var warning: WajubError?
    /// A payment request or a verification is running (`PROCESSING` / `VERIFYING`).
    public private(set) var isBusy = false
    /// The cancel call of "Cancel payment" is running.
    public private(set) var isCancelling = false
    /// The host's `CardCollector` is collecting a card.
    public private(set) var isCollectingCard = false
    /// "Try again" waits until then (`rate_limited`).
    public private(set) var retryAvailableAt: Date?
    public private(set) var isBrowserOpen = false
    /// The payer asked to leave (dismiss or "Cancel payment"); the result follows the cancel call.
    public private(set) var isClosing = false
    public private(set) var result: CheckoutResult?

    /// Called after every change, for the UI to redraw.
    public var onChange: (@MainActor () -> Void)?
    /// Called once with the result, when the sheet must close.
    public var onFinish: (@MainActor (CheckoutResult) -> Void)?

    private var config: SdkConfigResponse?
    private var isReady = false
    private var emittedState: CheckoutState?
    private var attempt: Attempt?
    private var lastTransaction: SessionTransaction?
    private var watcher: StatusWatcher?
    private var loadTask: Task<Void, Never>?
    private var readyTimer: Task<Void, Never>?
    private var altchaTask: Task<AltchaSolution?, Never>?
    private var autoCloseTask: Task<Void, Never>?
    private var threeDSTimer: Task<Void, Never>?
    private var workTask: Task<Void, Never>?
    private var started = false
    private var clientSessionFailed = false

    /// The payment attempt under way.
    private struct Attempt {
        var key = UUID().uuidString.lowercased()
        var family: String
        var channel: String
        var startedAt: Date
        /// `onPaymentStarted` fired (a 2xx came).
        var started = false
        var seenProcessing = false
        /// Money may move: a dismiss resolves `processing` and never cancels.
        var inFlight = true
        var phone: String?
        var continueURL: String?
        var clientSession: ClientSession?
    }

    public convenience init(options: PresentOptions, browser: BrowserOpening) {
        let client = WajubSession(sessionToken: options.sessionToken)
        self.init(options: options, client: client, browser: browser, connectWebSocket: { URLSessionWebSocket(url: $0) })
    }

    init(options: PresentOptions, client: WajubSession, browser: BrowserOpening,
         connectWebSocket: @escaping (URL) -> WebSocketConnection) {
        self.options = options
        self.client = client
        self.browser = browser
        self.connectWebSocket = connectWebSocket
        language = WajubLanguage.resolve(option: options.locale, session: nil, device: client.device.language)
    }

    private var clock: WajubClock { client.clock }

    // MARK: Derived

    public var strings: WajubStrings { WajubStrings(language) }
    public var isSandbox: Bool { session?.transaction.sandbox ?? false }
    public var transaction: SessionTransaction? { lastTransaction ?? session?.transaction }

    /// The amount to pay (`amount_total`) in the currency's usual format.
    public var formattedAmount: String {
        guard let transaction = session?.transaction else { return "" }
        return formatAmount(transaction.amountTotal)
    }

    public func formatAmount(_ amount: Double) -> String {
        AmountFormatter.format(amount, currency: session?.transaction.currency ?? "", language: language)
    }

    /// Something is running: the sheet's buttons wait.
    public var isWorking: Bool { isBusy || isCancelling || isCollectingCard }

    /// "Cancel payment" is offered while no attempt is in flight.
    public var canCancelPayment: Bool {
        guard result == nil, session != nil, !isWorking, attempt?.inFlight != true else { return false }
        switch screen {
        case .methods, .form: return true
        case .failed(let error): return error.retryable
        default: return false
        }
    }

    /// "Back" to the method list from a form.
    public var canGoBack: Bool {
        if case .form = screen { return !isWorking && methods.count > 1 }
        return false
    }

    /// "Try again" on the failure screen.
    public var canTryAgain: Bool {
        guard case .failed(let error) = screen, error.retryable else { return false }
        return true
    }

    // MARK: Loading (README §4)

    /// Starts loading. Called once by the presenter.
    public func start() {
        guard !started, result == nil else { return }
        started = true
        load()
    }

    /// Retry from a load error: cancels the running requests and starts again with a new timer.
    public func retryLoad() {
        guard result == nil, !isReady else { return }
        load()
    }

    private func load() {
        loadTask?.cancel()
        readyTimer?.cancel()
        screen = .loading
        update()
        if options.readyTimeout > 0 {
            let milliseconds = options.readyTimeout
            readyTimer = Task { [weak self] in
                guard let self else { return }
                do { try await self.clock.sleep(seconds: Double(milliseconds) / 1000) } catch { return }
                self.readyTimedOut(milliseconds)
            }
        }
        loadTask = Task { [weak self] in await self?.performLoad() }
    }

    private func performLoad() async {
        let client = self.client
        // Both start at once; a failed sdk-config does not stop the sheet.
        let configTask = Task { () -> SdkConfigResponse? in
            guard let answer = try? await client.send(.sdkConfig), answer.isSuccess, let body = answer.body else { return nil }
            return SdkConfigResponse(json: body)
        }
        let answer: APIAnswer
        do {
            answer = try await client.send(.session)
        } catch is CancellationError {
            configTask.cancel()
            return
        } catch {
            configTask.cancel()
            guard !Task.isCancelled else { return }
            loadFailed(.catalogue(WajubError.Code.loadError, language))
            return
        }
        guard !Task.isCancelled else {
            configTask.cancel()
            return
        }
        guard answer.isSuccess else {
            configTask.cancel()
            var error = WajubError.from(answer, phase: .loading, language: language)
            if error.code != WajubError.Code.sessionNotFound && error.code != WajubError.Code.sessionTerminalExpired {
                let original = error
                error = .catalogue(WajubError.Code.loadError, language, httpStatus: answer.status)
                error.correlationId = original.correlationId
                error.apiMessage = original.apiMessage
            }
            loadFailed(error)
            return
        }
        guard let body = answer.body, let session = try? SessionResponse(json: body) else {
            configTask.cancel()
            loadFailed(.catalogue(WajubError.Code.loadError, language, httpStatus: answer.status))
            return
        }
        let config: SdkConfigResponse?
        if session.transaction.status.isPaid || CheckoutController.endedStatuses.contains(session.transaction.status) {
            configTask.cancel()
            config = nil
        } else {
            config = await configTask.value
        }
        guard !Task.isCancelled, result == nil else { return }
        sessionLoaded(session, config: config)
    }

    static let endedStatuses: Set<TransactionStatus> = [.failed, .cancelled, .expired]

    private func readyTimedOut(_ milliseconds: Int) {
        guard !isReady, result == nil else { return }
        let error = WajubError.readyTimeout(after: milliseconds, language)
        screen = .loadError(error)
        update()
        emit { try self.options.callbacks.onLoadError?(error) }
    }

    private func loadFailed(_ error: WajubError) {
        guard !isReady, result == nil else { return }
        readyTimer?.cancel()
        screen = .loadError(error)
        update()
        emit { try self.options.callbacks.onLoadError?(error) }
    }

    private func sessionLoaded(_ session: SessionResponse, config: SdkConfigResponse?) {
        readyTimer?.cancel()
        self.session = session
        self.config = config
        lastTransaction = session.transaction
        language = WajubLanguage.resolve(option: options.locale, session: session.locale, device: client.device.language)
        if let challenge = session.altcha { solveAltcha(challenge) }

        let transaction = session.transaction
        switch transaction.status {
        case let status where status.isPaid:
            let payment = PaymentSuccess(transaction: transaction, method: "unknown", now: clock.now)
            becomeReady(.success(payment), shown: [])
            emit { try self.options.callbacks.onSuccess?(payment) }
            scheduleAutoClose()
        case .failed:
            endedAtLoad(WajubError.Code.sessionTerminalFailed, state: .failed)
        case .cancelled:
            endedAtLoad(WajubError.Code.sessionTerminalCancelled, state: .cancelled)
        case .expired:
            endedAtLoad(WajubError.Code.sessionTerminalExpired, state: .expired)
        case .processing, .partial:
            methods = MethodResolver.methods(session, config: config, language: language, hasCardCollector: options.cardCollector != nil)
            restore(session)
        default:
            let shown = MethodResolver.shownChannels(session, config: config, hasCardCollector: options.cardCollector != nil)
            methods = MethodResolver.methods(session, config: config, language: language, hasCardCollector: options.cardCollector != nil)
            guard !methods.isEmpty else {
                loadFailed(.catalogue(WajubError.Code.noPaymentMethod, language))
                return
            }
            if methods.count == 1, methods[0].isEnabled {
                openForm(methods[0])
                becomeReady(.form, shown: shown)
            } else {
                becomeReady(.methods, shown: shown)
            }
        }
    }

    private func endedAtLoad(_ code: String, state: CheckoutState) {
        let error = WajubError.catalogue(code, language)
        becomeReady(.ended(error, state: state), shown: [])
        emit { try self.options.callbacks.onLoadError?(error) }
    }

    /// `processing` / `partial` at load: the screen of `processing_context`, then watch.
    private func restore(_ session: SessionResponse) {
        let context = session.transaction.processingContext
        let family: String
        if context?.isMobileMoney == true {
            family = "mobile_money"
        } else if context?.channelSlug == "card" {
            family = "card"
        } else {
            family = "unknown"
        }
        attempt = Attempt(family: family, channel: context?.channelSlug ?? "", startedAt: clock.now, seenProcessing: true)
        let screen: CheckoutScreen
        if context?.isUSSD == true {
            screen = .ussd(instruction: context?.payerInstruction)
        } else if context?.isMobileMoney == true {
            screen = .approval(ApprovalScreen(phone: nil, instruction: context?.payerInstruction))
        } else if let id = context?.threeDSId {
            screen = .threeDS(threeDSScreen(id: id, maskedEmail: context?.maskedEmail, timeout: context?.threeDSTimeout))
        } else if let url = context?.actionURL {
            attempt?.continueURL = url
            screen = .pending(PendingScreen(continueURL: url))
        } else {
            screen = .pending(PendingScreen())
        }
        becomeReady(screen, shown: MethodResolver.shownChannels(session, config: config, hasCardCollector: options.cardCollector != nil))
        if case .threeDS(let challenge) = screen { startThreeDSTimer(challenge) }
        startWatching()
    }

    private func becomeReady(_ screen: CheckoutScreen, shown: [SessionChannel]) {
        self.screen = screen
        let firstReady = !isReady
        isReady = true
        if firstReady, let transaction = session?.transaction {
            let event = ReadyEvent(sessionId: transaction.id, environment: transaction.sandbox ? "sandbox" : "live",
                                   amount: transaction.amountTotal, currency: transaction.currency, methods: shown.map(\.slug))
            emit { try self.options.callbacks.onReady?(event) }
        }
        update()
    }

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
        screen = .methods
        banner = nil
        warning = nil
        fieldErrors = [:]
        update()
    }

    private func openForm(_ method: CheckoutMethod) {
        currentMethod = method
        banner = nil
        warning = nil
        fieldErrors = [:]
        switch method.kind {
        case .mobileMoney:
            if mobileMoney == nil, let session {
                mobileMoney = MobileMoneyForm(channels: method.channels, config: config, language: language,
                                              amount: session.transaction.amountTotal, options: options.mobileMoney,
                                              geoCountry: session.geoCountry)
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
        warning = nil
        update()
    }

    public func setPhone(_ text: String) {
        mobileMoney?.setPhone(text)
        fieldErrors["data.phone"] = nil
        warning = nil
        update()
    }

    public func pickOperator(_ id: String) {
        mobileMoney?.pick(id)
        fieldErrors["data.operator"] = nil
        fieldErrors["data.phone"] = nil
        warning = nil
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
        let validation = form.validate(sandbox: isSandbox)
        if let error = validation.error {
            fieldErrors = [error.param ?? "data.phone": error]
            update()
            return
        }
        warning = validation.warning
        guard let request = form.request(returnURL: options.returnURL) else { return }
        pay(channel: request.channel, data: request.data, family: "mobile_money", mobileMoney: true,
            phone: request.data["phone"]?.string)
    }

    // MARK: Card (README §7, §11)

    public func setCardField(_ field: String, _ value: String) {
        cardForm?.values[field] = value
        fieldErrors[field] = nil
        update()
    }

    /// Pays by card with the method's flavour: collects the card (Stripe), opens a client session, or
    /// sends the hosted page's fields or the sandbox test card.
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

    private func collectCard(publishableKey: String) {
        guard let collector = options.cardCollector, let transaction = session?.transaction else { return }
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
                guard self.result == nil, case .form = self.screen, let paymentMethod else {
                    self.update()
                    return
                }
                var data: [String: JSONValue] = ["payment_method_id": .string(paymentMethod)]
                if let returnURL = self.options.returnURL { data["return_url"] = .string(returnURL) }
                self.pay(channel: "card", data: data, family: "card", mobileMoney: false)
            } catch {
                guard let self else { return }
                self.isCollectingCard = false
                guard self.result == nil, case .form = self.screen else { return }
                self.banner = (error as? WajubError)
                    ?? WajubError(type: .paymentError, code: "card_collection_failed", message: error.localizedDescription, retryable: true)
                self.update()
            }
        }
    }

    private func startClientSession(fields: [String: String], securityRetry: Bool = false) {
        guard let channel = currentMethod?.channels.first else { return }
        let attempt = Attempt(family: "card", channel: channel.slug, startedAt: clock.now)
        self.attempt = attempt
        isBusy = true
        banner = nil
        fieldErrors = [:]
        update()
        let restart = clientSessionFailed
        workTask = Task { [weak self] in
            guard let self else { return }
            let altcha = await self.altchaSolution()
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

    /// One tap: pays a wallet such as Djamo and follows its page.
    public func payWallet() {
        guard result == nil, !isWorking, let method = currentMethod, method.kind == .wallet, let channel = method.channels.first else { return }
        var data: [String: JSONValue] = [:]
        if let returnURL = options.returnURL { data["return_url"] = .string(returnURL) }
        pay(channel: channel.slug, data: data, family: "wallet", mobileMoney: false)
    }

    // MARK: Paying (README §9)

    /// Raw card fields the API refuses in live (`RawCardDataGuard`).
    private static let rawCardKeys: Set<String> = ["card.number", "card_number", "number", "cvv", "cvc", "card_holder", "card.holder",
                                                   "expiry_month", "expiry_year", "exp", "pin"]

    func pay(channel: String, data: [String: JSONValue], family: String, mobileMoney: Bool, phone: String? = nil,
                     securityRetry: Bool = false) {
        guard result == nil else { return }
        // Card numbers, CVCs and PINs never leave the device in live.
        if !isSandbox, !Set(data.keys).isDisjoint(with: CheckoutController.rawCardKeys) {
            fail(.catalogue(WajubError.Code.rawCardDataNotAccepted, language))
            return
        }
        var attempt = Attempt(family: family, channel: channel, startedAt: clock.now)
        attempt.phone = phone
        self.attempt = attempt
        isBusy = true
        banner = nil
        fieldErrors = [:]
        stopWatching()
        update()
        let key = attempt.key
        workTask = Task { [weak self] in
            guard let self else { return }
            var data = data
            if let solution = await self.altchaSolution() { data["altcha"] = solution.json }
            data["_client"] = await self.client.device.clientSignals()
            let body: JSONValue = .object(["channel": .string(channel), "data": .object(data)])
            let answer: APIAnswer
            do {
                answer = try await self.client.send(.process, body: body, idempotencyKey: key)
            } catch is CancellationError {
                return
            } catch {
                // No answer after the retries: the outcome is unknown, never a failure.
                guard self.isCurrent(key) else { return }
                self.unknownOutcome()
                return
            }
            guard self.isCurrent(key) else { return }
            if !securityRetry, self.isSecurityRefusal(answer) {
                await self.renewAltcha()
                self.pay(channel: channel, data: data.filter { $0.key != "altcha" && $0.key != "_client" }, family: family,
                         mobileMoney: mobileMoney, phone: phone, securityRetry: true)
                return
            }
            if securityRetry, self.isSecurityRefusal(answer) {
                self.attempt?.inFlight = false
                self.fail(.catalogue(WajubError.Code.securityCheckFailed, self.language))
                return
            }
            self.handlePaymentAnswer(answer, mobileMoney: mobileMoney, clientSession: false)
        }
    }

    private func handlePaymentAnswer(_ answer: APIAnswer, mobileMoney: Bool, clientSession: Bool) {
        guard result == nil else { return }
        isBusy = false
        switch PaymentAnswer.classify(answer, mobileMoney: mobileMoney, allowsClientSession: clientSession) {
        case .succeeded(let transaction):
            paymentStarted(transaction)
            succeed(transaction)
        case .processing(let kind, let response):
            paymentStarted(response.transaction)
            let instruction = response.transaction?.processingContext?.payerInstruction
            switch kind {
            case .approval: screen = .approval(ApprovalScreen(phone: attempt?.phone, instruction: instruction))
            case .ussd: screen = .ussd(instruction: instruction)
            case .pending: screen = .pending(PendingScreen())
            }
            update()
            startWatching()
        case .redirect(let url, let threeDS, let response):
            paymentStarted(response.transaction)
            openRedirect(url, threeDS: threeDS)
        case .threeDSCode(let challenge, let response):
            paymentStarted(response.transaction)
            let screen = threeDSScreen(id: challenge.id, maskedEmail: challenge.maskedEmail, timeout: challenge.timeout)
            self.screen = .threeDS(screen)
            update()
            startThreeDSTimer(screen)
            startWatching()
        case .step(let step, let response):
            paymentStarted(response.transaction)
            screen = .step(StepScreen(kind: step.kind, id: step.id, hint: step.hint, attemptsRemaining: nil, error: nil,
                                      resendAvailableAt: clock.now.addingTimeInterval(Timing.resendAfter)))
            update()
            startWatching()
        case .clientSession(let session, let response):
            paymentStarted(response.transaction)
            attempt?.clientSession = session
            openRedirect(session.hostedURL ?? "", threeDS: false)
        case .unsupportedAction(let response):
            paymentStarted(response.transaction)
            fail(.catalogue(WajubError.Code.unsupportedAction, language))
        case .refused(let answer):
            handleRefusal(answer, clientSession: clientSession)
        }
    }

    private func handleRefusal(_ answer: APIAnswer, clientSession: Bool) {
        let error = WajubError.from(answer, phase: .payment, language: language)
        let body = answer.body.map(APIErrorBody.init(json:))
        if let transaction = body?.transaction { lastTransaction = transaction }
        switch answer.status {
        case 400:
            attempt?.inFlight = false
            rereadStatus(orFail: .catalogue(WajubError.Code.notProcessable, language))
        case 409 where body?.errorCode == WajubError.Code.paymentInProgress:
            // A charge is already running: wait for it, no error.
            screen = .pending(PendingScreen())
            update()
            startWatching()
        case 410:
            attempt?.inFlight = false
            expire(error)
        case 422:
            attempt?.inFlight = false
            if let code = body?.errorCode, code != WajubError.Code.validationError, ErrorCatalogue.entries[code] != nil {
                if clientSession { clientSessionFailed = true }
                fail(error)
            } else {
                showFieldErrors(answer, error: error)
            }
        case 500... where clientSession:
            // No provider page was opened: nothing can be running.
            attempt?.inFlight = false
            fail(error)
        case 500...:
            unknownOutcome()
        default:
            attempt?.inFlight = false
            if clientSession { clientSessionFailed = true }
            if answer.status == 429, let seconds = error.retryAfterSeconds {
                retryAvailableAt = clock.now.addingTimeInterval(TimeInterval(seconds))
            }
            fail(error)
        }
    }

    /// A 422: back to the form with field errors (README §9.1).
    private func showFieldErrors(_ answer: APIAnswer, error: WajubError) {
        let errors = answer.body.map(APIErrorBody.init(json:))?.errors ?? [:]
        var fields: [String: WajubError] = [:]
        var bannerError: WajubError?
        for (key, messages) in errors {
            let message = messages.first ?? ""
            let field = key.hasPrefix("data.") ? String(key.dropFirst(5)) : key
            switch field {
            case "phone", "account_number":
                if message.contains("belongs to"), let form = mobileMoney {
                    var mismatch = WajubError.catalogue(WajubError.Code.operatorMismatch, language,
                                                        values: ["detected": form.mismatchLabel(apiMessage: message),
                                                                 "selected": form.selectedChoice?.label ?? ""])
                    mismatch.param = key
                    mismatch.apiMessage = message
                    fields["data.phone"] = mismatch
                } else if fields["data.phone"] == nil {
                    var invalid = WajubError.catalogue(WajubError.Code.invalidPhone, language)
                    invalid.param = key
                    invalid.apiMessage = message
                    fields["data.phone"] = invalid
                }
            case "email", "first_name", "last_name", "address", "city", "country", "state", "zip_code":
                fields[field] = WajubError(type: .invalidRequestError, code: WajubError.Code.validationError, message: message,
                                           retryable: true, param: key, httpStatus: 422, apiMessage: message)
            default:
                bannerError = error
            }
        }
        if fields.isEmpty && bannerError == nil { bannerError = error }
        fieldErrors = fields
        banner = bannerError
        if case .form = screen {} else { screen = .form }
        update()
    }

    /// Network, timeout or 5xx after the retries: the charge may be running. Watch, never fail.
    private func unknownOutcome() {
        guard result == nil else { return }
        isBusy = false
        attempt?.inFlight = true
        screen = .pending(PendingScreen())
        update()
        startWatching()
    }

    private func paymentStarted(_ transaction: SessionTransaction?) {
        if let transaction { lastTransaction = transaction }
        guard var attempt, !attempt.started else { return }
        attempt.started = true
        attempt.seenProcessing = true
        self.attempt = attempt
        let event = PaymentStartedEvent(method: attempt.family, channel: attempt.channel)
        emit { try self.options.callbacks.onPaymentStarted?(event) }
    }

    // MARK: Altcha (README §15)

    private func solveAltcha(_ challenge: AltchaChallenge) {
        altchaTask?.cancel()
        altchaTask = Task.detached(priority: .userInitiated) { AltchaSolver.solve(challenge) }
    }

    private func altchaSolution() async -> AltchaSolution? {
        await altchaTask?.value
    }

    private func isSecurityRefusal(_ answer: APIAnswer) -> Bool {
        guard answer.status == 422, session?.altcha != nil || altchaTask != nil else { return false }
        let body = answer.body.map(APIErrorBody.init(json:))
        if body?.errors.keys.contains(where: { $0 == "altcha" || $0 == "data.altcha" }) == true { return true }
        return (body?.message ?? "").lowercased().contains("security challenge")
    }

    /// Reloads the session for a new challenge and solves it.
    private func renewAltcha() async {
        guard let answer = try? await client.send(.session), answer.isSuccess, let body = answer.body,
              let session = try? SessionResponse(json: body) else { return }
        self.session?.altcha = session.altcha
        if let challenge = session.altcha { solveAltcha(challenge) } else { altchaTask = nil }
    }

    // MARK: Redirects (README §12)

    private func openRedirect(_ urlString: String, threeDS: Bool) {
        attempt?.continueURL = urlString
        screen = .pending(PendingScreen(continueURL: urlString, threeDS: threeDS))
        update()
        startWatching()
        launchBrowser(urlString)
    }

    private func launchBrowser(_ urlString: String) {
        emit { try self.options.callbacks.onRedirect?(RedirectEvent(url: urlString)) }
        let mode: BrowserMode = attempt?.family == "card" ? .inApp : .external
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            fail(.catalogue(WajubError.Code.redirectUnavailable, language))
            return
        }
        isBrowserOpen = true
        update()
        Task { [weak self] in
            guard let self else { return }
            let opened = await self.browser.open(url, mode: mode, onClose: { [weak self] in self?.browserClosed() })
            guard !opened, self.result == nil else { return }
            self.isBrowserOpen = false
            self.fail(.catalogue(WajubError.Code.redirectUnavailable, self.language))
        }
    }

    /// "Continue payment": reopens the provider page.
    public func continuePayment() {
        guard result == nil, let url = attempt?.continueURL else { return }
        switch screen {
        case .failed:
            screen = .pending(PendingScreen(continueURL: url))
            startWatching()
        case .pending(let pending) where pending.capReached:
            // The payer is back at it: a new watch window.
            attempt?.startedAt = clock.now
            screen = .pending(PendingScreen(continueURL: url))
            startWatching()
        default:
            break
        }
        launchBrowser(url)
    }

    /// The in-app browser closed: complete a client session, poll at once.
    func browserClosed() {
        isBrowserOpen = false
        update()
        payerReturned()
    }

    /// The app came back from the background (a wallet's app, the browser) or a deep link arrived: poll at once.
    public func appWillEnterForeground() {
        guard result == nil else { return }
        if watcher == nil {
            // After the watch cap: one look at the status.
            if case .pending = screen, attempt != nil { checkStatusOnce() }
            return
        }
        if isBrowserOpen, attempt?.family != "card" { isBrowserOpen = false }
        update()
        payerReturned()
    }

    private func checkStatusOnce() {
        workTask = Task { [weak self] in
            guard let self, let answer = try? await self.client.send(.status), answer.isSuccess, self.result == nil else { return }
            self.statusUpdated(StatusResponse(json: answer.body ?? .null).transaction)
        }
    }

    private func payerReturned() {
        guard result == nil else { return }
        if let session = attempt?.clientSession {
            completeClientSession(session)
        } else {
            watcher?.pollNow()
        }
    }

    private func completeClientSession(_ session: ClientSession) {
        let key = attempt?.key
        workTask = Task { [weak self] in
            guard let self else { return }
            let answer: APIAnswer
            do {
                answer = try await self.client.send(.clientSessionComplete, body: ["client_session_id": .string(session.id)])
            } catch {
                guard self.isCurrent(key) else { return }
                self.watcher?.pollNow()
                return
            }
            guard self.isCurrent(key) else { return }
            let body = answer.body.map(APIErrorBody.init(json:))
            switch answer.status {
            case 200...299:
                let transaction = ProcessResponse(json: answer.body ?? .null).transaction
                if let transaction { self.lastTransaction = transaction }
                if let transaction, transaction.status.isPaid {
                    self.succeed(transaction)
                } else if transaction?.status == .failed {
                    self.attempt?.inFlight = false
                    self.fail(.catalogue(WajubError.Code.paymentFailed, self.language))
                } else {
                    self.watcher?.pollNow()
                }
            case 402, 422:
                if let transaction = body?.transaction { self.lastTransaction = transaction }
                self.attempt?.inFlight = false
                self.clientSessionFailed = true
                self.fail(WajubError.from(answer, phase: .payment, language: self.language))
            case 410:
                self.attempt?.inFlight = false
                self.expire(WajubError.from(answer, phase: .payment, language: self.language))
            default:
                self.watcher?.pollNow()
            }
        }
    }

    // MARK: Confirmation steps (README §10)

    /// Verifies a step: `code` (OTP), `pin`, `phone`, `birthday` (`YYYY-MM-DD`), or `address`, `city`, `state`, `zip_code`.
    public func submitStep(_ fields: [String: String]) {
        guard result == nil, !isWorking, case .step(var step) = screen else { return }
        let fields = fields.mapValues { $0.trimmingCharacters(in: .whitespaces) }
        let errors = CheckoutController.validateStep(step.kind, fields: fields, language: language)
        guard errors.isEmpty else {
            fieldErrors = errors
            update()
            return
        }
        fieldErrors = [:]
        step.error = nil
        screen = .step(step)
        isBusy = true
        update()
        let key = attempt?.key
        workTask = Task { [weak self] in
            guard let self else { return }
            let answer: APIAnswer
            do {
                answer = try await self.client.send(.verify(step.kind), body: WajubSession.verifyBody(step.kind, id: step.id, fields: fields))
            } catch is CancellationError {
                return
            } catch {
                // Never retried: let the payer try again, and look at the status.
                guard self.isCurrent(key) else { return }
                self.isBusy = false
                step.error = WajubSession.transportError(error, self.language)
                self.screen = .step(step)
                self.update()
                self.watcher?.pollNow()
                return
            }
            guard self.isCurrent(key) else { return }
            self.handleStepAnswer(answer, step: step)
        }
    }

    private func handleStepAnswer(_ answer: APIAnswer, step: StepScreen) {
        isBusy = false
        var step = step
        switch answer.status {
        case 200...299:
            switch StepVerifyResponse(json: answer.body ?? .null) {
            case .success(let transaction):
                if let transaction { lastTransaction = transaction }
                if let transaction, transaction.status.isPaid {
                    succeed(transaction)
                } else if transaction?.status == .failed {
                    attempt?.inFlight = false
                    fail(.catalogue(WajubError.Code.paymentFailed, language))
                } else {
                    screen = .pending(PendingScreen())
                    update()
                    startWatching()
                }
            case .failed(let code, let message, let remaining):
                let error = WajubError.stepFailure(code: code, apiMessage: message, attemptsRemaining: remaining, language)
                if code.hasPrefix("invalid_"), (remaining ?? 1) > 0 {
                    step.error = error
                    step.attemptsRemaining = remaining
                    screen = .step(step)
                    update()
                } else {
                    attempt?.inFlight = false
                    fail(error)
                }
            }
        case 422:
            var fields: [String: WajubError] = [:]
            for (key, messages) in answer.body.map(APIErrorBody.init(json:))?.errors ?? [:] {
                let message = messages.first ?? ""
                fields[key] = WajubError(type: .invalidRequestError, code: WajubError.Code.validationError, message: message,
                                         retryable: true, param: key, httpStatus: 422, apiMessage: message)
            }
            fieldErrors = fields
            screen = .step(step)
            update()
        default:
            watchRefusalOrRetry(answer) {
                step.error = WajubError.from(answer, phase: .payment, language: self.language)
                self.screen = .step(step)
                self.update()
            }
        }
    }

    /// Resends the step's code (offered 60 s after the screen opened; the countdown restarts).
    public func resendStepCode() {
        guard result == nil, case .step(var step) = screen, clock.now >= step.resendAvailableAt else { return }
        step.resendAvailableAt = clock.now.addingTimeInterval(Timing.resendAfter)
        screen = .step(step)
        update()
        let client = self.client
        Task { _ = try? await client.send(.resend(step.kind), body: [step.kind.idKey: .string(step.id)]) }
    }

    static func validateStep(_ kind: ConfirmStepKind, fields: [String: String], language: WajubLanguage) -> [String: WajubError] {
        func digits(_ key: String, _ range: ClosedRange<Int>) -> [String: WajubError] {
            let value = fields[key] ?? ""
            if value.isEmpty { return [key: .catalogue(WajubError.Code.fieldRequired, language)] }
            guard value.allSatisfy(\.isNumber), range.contains(value.count) else {
                return [key: .catalogue(WajubError.Code.validationError, language)]
            }
            return [:]
        }
        switch kind {
        case .otp:
            return digits("code", 4...10)
        case .pin:
            return digits("pin", 4...6)
        case .phone:
            return (fields["phone"] ?? "").isEmpty ? ["phone": .catalogue(WajubError.Code.fieldRequired, language)] : [:]
        case .birthday:
            let value = fields["birthday"] ?? ""
            if value.isEmpty { return ["birthday": .catalogue(WajubError.Code.fieldRequired, language)] }
            let parts = value.split(separator: "-")
            let valid = parts.count == 3 && parts[0].count == 4 && parts[1].count == 2 && parts[2].count == 2
                && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
            return valid ? [:] : ["birthday": .catalogue(WajubError.Code.validationError, language)]
        case .address:
            var errors: [String: WajubError] = [:]
            for key in ["address", "city", "state", "zip_code"] where (fields[key] ?? "").isEmpty {
                errors[key] = .catalogue(WajubError.Code.fieldRequired, language)
            }
            return errors
        }
    }

    // MARK: Sandbox 3-D Secure (README §10.1)

    private func threeDSScreen(id: String, maskedEmail: String?, timeout: Int?) -> ThreeDSScreen {
        ThreeDSScreen(id: id, maskedEmail: maskedEmail, expiresAt: timeout.map { clock.now.addingTimeInterval(TimeInterval($0)) },
                      error: nil, resendAvailableAt: clock.now.addingTimeInterval(Timing.resendAfter), accepted: false)
    }

    private func startThreeDSTimer(_ challenge: ThreeDSScreen) {
        threeDSTimer?.cancel()
        guard let expiresAt = challenge.expiresAt else { return }
        threeDSTimer = Task { [weak self] in
            guard let self else { return }
            do { try await self.clock.sleep(seconds: expiresAt.timeIntervalSince(self.clock.now)) } catch { return }
            guard self.result == nil, case .threeDS(let current) = self.screen, current.id == challenge.id, !current.accepted else { return }
            self.attempt?.inFlight = false
            self.fail(.catalogue(WajubError.Code.threeDSTimeout, self.language))
        }
    }

    public func submitThreeDSCode(_ code: String) {
        guard result == nil, !isWorking, case .threeDS(var challenge) = screen else { return }
        let code = code.trimmingCharacters(in: .whitespaces)
        guard code.allSatisfy(\.isNumber), (4...8).contains(code.count) else {
            fieldErrors = ["code": .catalogue(code.isEmpty ? WajubError.Code.fieldRequired : WajubError.Code.invalidCode, language)]
            update()
            return
        }
        fieldErrors = [:]
        challenge.error = nil
        screen = .threeDS(challenge)
        isBusy = true
        update()
        let key = attempt?.key
        workTask = Task { [weak self] in
            guard let self else { return }
            let answer: APIAnswer
            do {
                answer = try await self.client.send(.threeDSVerify, body: ["three_ds_id": .string(challenge.id), "code": .string(code)])
            } catch is CancellationError {
                return
            } catch {
                guard self.isCurrent(key) else { return }
                self.isBusy = false
                challenge.error = WajubSession.transportError(error, self.language)
                self.screen = .threeDS(challenge)
                self.update()
                self.watcher?.pollNow()
                return
            }
            guard self.isCurrent(key) else { return }
            self.isBusy = false
            if answer.isSuccess {
                challenge.accepted = true
                self.screen = .threeDS(challenge)
                self.update()
                self.watcher?.pollNow()
            } else if WajubSession.threeDSKeepsScreen(answer) {
                challenge.error = WajubSession.threeDSError(answer, self.language)
                self.screen = .threeDS(challenge)
                self.update()
            } else {
                self.watchRefusalOrRetry(answer) {
                    self.attempt?.inFlight = false
                    self.fail(WajubSession.threeDSError(answer, self.language))
                }
            }
        }
    }

    /// Sends a new sandbox 3-D Secure code.
    public func resendThreeDSCode() {
        guard result == nil, case .threeDS(var challenge) = screen, clock.now >= challenge.resendAvailableAt else { return }
        challenge.resendAvailableAt = clock.now.addingTimeInterval(Timing.resendAfter)
        screen = .threeDS(challenge)
        update()
        workTask = Task { [weak self] in
            guard let self, let answer = try? await self.client.send(.threeDSSend, body: ["three_ds_id": .string(challenge.id)]),
                  answer.isSuccess, let email = ResendResponse(json: answer.body ?? .null).maskedEmail,
                  case .threeDS(var current) = self.screen, current.id == challenge.id else { return }
            current.maskedEmail = email
            self.screen = .threeDS(current)
            self.update()
        }
    }

    /// A session-level refusal (401, 403, 404, 410) ends the sheet; anything else runs `otherwise`.
    private func watchRefusalOrRetry(_ answer: APIAnswer, otherwise: () -> Void) {
        switch answer.status {
        case 401, 403, 404:
            attempt?.inFlight = false
            fail(.catalogue(WajubError.Code.sessionNotFound, language, httpStatus: answer.status))
        case 410:
            attempt?.inFlight = false
            expire(.catalogue(WajubError.Code.sessionTerminalExpired, language, httpStatus: 410))
        default:
            otherwise()
        }
    }

    // MARK: Watching (README §13)

    private func startWatching() {
        guard watcher == nil, result == nil, let session else { return }
        var deadline = (attempt?.startedAt ?? clock.now).addingTimeInterval(Timing.pollOverallCap)
        if let expiresAt = session.transaction.expiresAt.flatMap(CheckoutController.parseDate), expiresAt < deadline {
            deadline = expiresAt
        }
        let watcher = StatusWatcher(client: client, clock: clock, random: client.random, deadline: deadline)
        watcher.onUpdate = { [weak self] update in self?.statusUpdated(update) }
        watcher.onRefusal = { [weak self] answer in
            guard let self else { return }
            self.watcher = nil
            self.watchRefusalOrRetry(answer) {}
        }
        watcher.onCap = { [weak self] in self?.capReached() }
        if let endpoint = RealtimeEndpoint(echo: session.echo, override: options.realtime, transactionId: session.transaction.id) {
            watcher.attach(realtime: endpoint, connect: connectWebSocket)
        }
        self.watcher = watcher
        watcher.start()
    }

    private func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    /// Decides on a status from a poll or the socket (README §13.2).
    private func statusUpdated(_ update: StatusUpdate) {
        guard result == nil, attempt != nil, !showsOutcome else { return }
        let status = update.status
        if let transaction = lastTransaction {
            var copy = transaction
            copy.status = status
            lastTransaction = copy
        }
        switch status {
        case let status where status.isPaid:
            if let transaction = lastTransaction { succeed(transaction) }
        case .failed:
            attempt?.inFlight = false
            fail(.catalogue(WajubError.Code.paymentFailed, language))
        case .cancelled:
            attempt?.inFlight = false
            stopWatching()
            let error = WajubError.catalogue(WajubError.Code.paymentCancelled, language)
            screen = .cancelled(error)
            self.update()
            emit { try self.options.callbacks.onError?(error) }
        case .expired:
            attempt?.inFlight = false
            expire(.catalogue(WajubError.Code.sessionExpired, language))
        case .pending:
            guard attempt?.seenProcessing == true else { return }
            attempt?.inFlight = false
            fail(attemptEndedError(update))
        case .processing, .partial:
            attempt?.seenProcessing = true
        default:
            break
        }
    }

    /// `pending` after `processing`: the attempt ended without charging.
    private func attemptEndedError(_ update: StatusUpdate) -> WajubError {
        guard let code = update.errorCode else { return .catalogue(WajubError.Code.paymentAttemptEnded, language) }
        var error: WajubError
        if let entry = ErrorCatalogue.entries[code] {
            error = WajubError(type: entry.type, code: code, message: entry.message(language), retryable: true)
        } else {
            // A provider's own decline code: the same text as a 402 with that code (errors.md §3.4).
            error = WajubError(type: .paymentError, code: code, message: ErrorCatalogue.genericDecline.message(language), retryable: true)
        }
        error.declineCode = code
        error.apiMessage = update.payerMessage
        return error
    }

    private func capReached() {
        guard result == nil else { return }
        watcher = nil
        screen = .pending(PendingScreen(continueURL: attempt?.continueURL, capReached: true))
        update()
    }

    private func rereadStatus(orFail fallback: WajubError) {
        workTask = Task { [weak self] in
            guard let self else { return }
            let answer = try? await self.client.send(.status)
            guard self.result == nil else { return }
            guard let answer, answer.isSuccess else {
                self.fail(fallback)
                return
            }
            let update = StatusResponse(json: answer.body ?? .null).transaction
            if update.status.isPaid || [.failed, .cancelled, .expired].contains(update.status) {
                self.attempt = self.attempt ?? Attempt(family: "unknown", channel: "", startedAt: self.clock.now)
                self.statusUpdated(update)
            } else {
                self.fail(fallback)
            }
        }
    }

    // MARK: Outcomes

    private func succeed(_ transaction: SessionTransaction) {
        guard result == nil, !showsOutcome else { return }
        workTask?.cancel()
        stopWatching()
        threeDSTimer?.cancel()
        isBusy = false
        attempt?.inFlight = false
        lastTransaction = transaction
        let payment = PaymentSuccess(transaction: transaction, method: attempt?.family ?? "unknown", now: clock.now)
        screen = .success(payment)
        update()
        emit { try self.options.callbacks.onSuccess?(payment) }
        scheduleAutoClose()
    }

    private func fail(_ error: WajubError) {
        guard result == nil, !showsOutcome else { return }
        workTask?.cancel()
        stopWatching()
        threeDSTimer?.cancel()
        isBusy = false
        screen = .failed(error)
        update()
        emit { try self.options.callbacks.onError?(error) }
    }

    private func expire(_ error: WajubError) {
        guard result == nil, !showsOutcome else { return }
        workTask?.cancel()
        stopWatching()
        threeDSTimer?.cancel()
        isBusy = false
        screen = .expired(error)
        update()
        emit { try self.options.callbacks.onError?(error) }
    }

    private func scheduleAutoClose() {
        guard options.autoCloseSuccess > 0 else { return }
        let delay = Double(options.autoCloseSuccess) / 1000
        autoCloseTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.clock.sleep(seconds: delay) } catch { return }
            self.close()
        }
    }

    /// The confirmation-step codes of errors.md §3.5.
    static let stepCodes: Set<String> = [
        WajubError.Code.invalidOTP, WajubError.Code.otpExpired, WajubError.Code.invalidPIN, WajubError.Code.pinExpired,
        WajubError.Code.invalidPhone, WajubError.Code.phoneExpired, WajubError.Code.invalidBirthday, WajubError.Code.birthdayExpired,
        WajubError.Code.invalidAddress, WajubError.Code.addressExpired, WajubError.Code.maxAttemptsExceeded, WajubError.Code.invalidCode,
        WajubError.Code.threeDSFailed, WajubError.Code.threeDSRejected, WajubError.Code.threeDSCancelled, WajubError.Code.threeDSTimeout,
    ]

    /// The sheet shows an outcome: answers that arrive later change nothing.
    private var showsOutcome: Bool {
        switch screen {
        case .success, .failed, .expired, .cancelled, .ended: return true
        default: return false
        }
    }

    /// An answer belongs to the attempt still on screen.
    private func isCurrent(_ key: String?) -> Bool {
        result == nil && !showsOutcome && attempt?.key == key
    }

    /// "Try again" from a retryable failure: back to the method's form (to the method list after a
    /// confirmation step), a new `Idempotency-Key` on the next Pay.
    public func tryAgain() {
        guard result == nil, canTryAgain, case .failed(let error) = screen else { return }
        if let availableAt = retryAvailableAt, clock.now < availableAt { return }
        retryAvailableAt = nil
        if error.code == WajubError.Code.redirectUnavailable, attempt?.continueURL != nil {
            continuePayment()
            return
        }
        attempt = nil
        banner = nil
        fieldErrors = [:]
        // A confirmation step that ended sends the payer back to the method list (errors.md §3.5).
        let stepEnded = CheckoutController.stepCodes.contains(error.code)
        if stepEnded, methods.count > 1 {
            screen = .methods
        } else if let method = currentMethod {
            openForm(method)
            screen = .form
        } else if methods.count == 1, let method = methods.first, method.isEnabled {
            openForm(method)
            screen = .form
        } else {
            screen = .methods
        }
        update()
    }

    // MARK: Closing (README §14, states.md §4–5)

    /// "Cancel payment": `POST /pay/cancel`, then the sheet closes as `cancelled`.
    public func cancelPayment() {
        guard canCancelPayment else { return }
        isClosing = true
        isCancelling = true
        update()
        workTask = Task { [weak self] in
            guard let self else { return }
            let answer = try? await self.client.send(.cancel)
            guard self.result == nil else { return }
            self.isCancelling = false
            if let answer, answer.status == 400 {
                await self.resolveRefusedCancel(reason: .payerCancelled)
                return
            }
            let redirect = answer.flatMap { $0.isSuccess ? CancelResponse(json: $0.body ?? .null).redirectURL : nil }
            self.screen = .cancelled(nil)
            self.update()
            self.finish(.cancelled(reason: .payerCancelled, redirectURL: redirect))
        }
    }

    /// A cancel answered `400`: the status says what happened.
    private func resolveRefusedCancel(reason: CancelReason) async {
        let answer = try? await client.send(.status)
        guard result == nil else { return }
        isCancelling = false
        let status = answer.flatMap { $0.isSuccess ? StatusResponse(json: $0.body ?? .null).transaction.status : nil }
        var transaction = lastTransaction ?? session?.transaction
        if let status { transaction?.status = status }
        switch status {
        case let status? where status.isPaid:
            guard let transaction else { return finish(.processing(transaction: nil)) }
            if reason == .payerCancelled, !showsOutcome {
                isClosing = false
                succeed(transaction)
            } else {
                let payment = PaymentSuccess(transaction: transaction, method: attempt?.family ?? "unknown", now: clock.now)
                emit { try self.options.callbacks.onSuccess?(payment) }
                finish(.complete(payment: payment, transaction: transaction))
            }
        case .failed?, .expired?:
            let error = WajubError.catalogue(status == .failed ? WajubError.Code.paymentFailed : WajubError.Code.sessionExpired, language)
            emit { try self.options.callbacks.onError?(error) }
            finish(.failed(error: error, transaction: transaction))
        case .pending?, .cancelled?:
            if reason == .payerCancelled {
                screen = .cancelled(nil)
                self.update()
            }
            finish(.cancelled(reason: reason, redirectURL: nil))
        default:
            // `processing`, `partial`, or no readable answer: money may move.
            if reason == .payerCancelled {
                isClosing = false
                attempt = Attempt(family: attempt?.family ?? "unknown", channel: attempt?.channel ?? "", startedAt: clock.now,
                                  seenProcessing: status != nil)
                screen = .pending(PendingScreen())
                self.update()
                startWatching()
            } else {
                finish(.processing(transaction: transaction))
            }
        }
    }

    /// The payer closed the sheet (swipe down, close button). Before any attempt this cancels the
    /// payment unless `cancelOnDismiss` is `false`; while an attempt runs it resolves `processing`.
    public func dismiss() {
        guard result == nil else { return }
        isClosing = true
        if let settled = settledResult() {
            finish(settled)
            return
        }
        guard session != nil, isReady, options.cancelOnDismiss else {
            finish(.cancelled(reason: .dismissed, redirectURL: nil))
            return
        }
        stopWatching()
        workTask?.cancel()
        workTask = Task { [weak self] in
            guard let self else { return }
            let answer = try? await self.client.send(.cancel)
            guard self.result == nil else { return }
            if let answer, answer.status == 400 {
                await self.resolveRefusedCancel(reason: .dismissed)
                return
            }
            let redirect = answer.flatMap { $0.isSuccess ? CancelResponse(json: $0.body ?? .null).redirectURL : nil }
            self.finish(.cancelled(reason: .dismissed, redirectURL: redirect))
        }
    }

    /// The Close button of a final screen: the same as a dismiss.
    public func close() {
        dismiss()
    }

    /// The presenting screen went away: settle at once, never call `/pay/cancel`.
    public func hostGone() {
        guard result == nil else { return }
        finish(settledResult() ?? .cancelled(reason: .hostGone, redirectURL: nil))
    }

    /// The result when the sheet closes now without cancelling anything; `nil` when nothing was attempted.
    private func settledResult() -> CheckoutResult? {
        switch screen {
        case .success(let payment):
            return .complete(payment: payment, transaction: lastTransaction)
        case .failed(let error) where attempt?.inFlight != true, .expired(let error), .loadError(let error),
             .ended(let error, _):
            return .failed(error: error, transaction: session == nil ? nil : lastTransaction)
        case .cancelled(let error?):
            return .failed(error: error, transaction: lastTransaction)
        case .cancelled(nil):
            return .cancelled(reason: .payerCancelled, redirectURL: nil)
        default:
            return attempt?.inFlight == true ? .processing(transaction: lastTransaction) : nil
        }
    }

    private func finish(_ result: CheckoutResult) {
        guard self.result == nil else { return }
        self.result = result
        stopWatching()
        for task in [loadTask, readyTimer, autoCloseTask, threeDSTimer, workTask] { task?.cancel() }
        altchaTask?.cancel()
        isBusy = false
        isCancelling = false
        isCollectingCard = false
        if case .cancelled(let reason, let redirectURL) = result {
            emit { try self.options.callbacks.onCancel?(CancelEvent(reason: reason, redirectURL: redirectURL)) }
        }
        emit { try self.options.callbacks.onComplete?(result) }
        onChange?()
        onFinish?(result)
    }

    // MARK: Plumbing

    /// Recomputes the state, reports a change once, and lets the UI redraw.
    private func update() {
        state = derivedState()
        if isReady, let state, state != emittedState, result == nil {
            emittedState = state
            let event = StateChangeEvent(state: state, method: attempt?.family ?? currentMethod?.family ?? "unknown")
            emit { try self.options.callbacks.onStateChange?(event) }
        }
        onChange?()
    }

    private func derivedState() -> CheckoutState? {
        switch screen {
        case .loading, .loadError: return nil
        case .methods: return .initiated
        case .form: return isBusy ? .processing : .collectingDetails
        case .approval: return .approvalRequired
        case .ussd: return .ussdRequired
        case .step(let step):
            if isBusy { return .verifying }
            switch step.kind {
            case .otp: return .otpRequired
            case .pin: return .pinRequired
            case .phone: return .phoneRequired
            case .birthday: return .birthdayRequired
            case .address: return .addressRequired
            }
        case .threeDS(let challenge): return isBusy || challenge.accepted ? .verifying : .threeDSRequired
        case .pending(let pending): return pending.threeDS && isBrowserOpen ? .threeDSRequired : .pending
        case .success: return .success
        case .failed: return .failed
        case .ended(_, let state): return state
        case .expired: return .expired
        case .cancelled: return .cancelled
        }
    }

    /// Runs a host callback; one that throws is logged and the sheet carries on.
    private func emit(_ callback: () throws -> Void) {
        do {
            try callback()
        } catch {
            print("WajubMobile: a checkout callback threw: \(error)")
        }
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
