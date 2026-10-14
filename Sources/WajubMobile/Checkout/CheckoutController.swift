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
    func open(_ url: URL, mode: BrowserMode, onClose: @escaping @MainActor @Sendable () -> Void) async -> Bool
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

    public internal(set) var screen: CheckoutScreen = .loading
    /// `nil` until the sheet is ready.
    public internal(set) var state: CheckoutState?
    public internal(set) var language: WajubLanguage
    public internal(set) var session: SessionResponse?
    public internal(set) var methods: [CheckoutMethod] = []
    public internal(set) var currentMethod: CheckoutMethod?
    public internal(set) var mobileMoney: MobileMoneyForm?
    public internal(set) var cardForm: CardForm?
    /// Field errors, keyed by field (`data.phone`, `data.operator`, `email`, `code`…).
    public internal(set) var fieldErrors: [String: WajubError] = [:]
    /// A form-level error not tied to a field.
    public internal(set) var banner: WajubError?
    /// Sandbox only: an operator mismatch that does not block.
    public internal(set) var warning: WajubError?
    /// A payment request or a verification is running (`PROCESSING` / `VERIFYING`).
    public internal(set) var isBusy = false
    /// The cancel call of "Cancel payment" is running.
    public internal(set) var isCancelling = false
    /// The host's `CardCollector` is collecting a card.
    public internal(set) var isCollectingCard = false
    /// "Try again" waits until then (`rate_limited`).
    public internal(set) var retryAvailableAt: Date?
    public internal(set) var isBrowserOpen = false
    /// The payer asked to leave (dismiss or "Cancel payment"); the result follows the cancel call.
    public internal(set) var isClosing = false
    public internal(set) var result: CheckoutResult?

    /// Called after every change, for the UI to redraw.
    public var onChange: (@MainActor () -> Void)?
    /// Called once with the result, when the sheet must close.
    public var onFinish: (@MainActor (CheckoutResult) -> Void)?

    var config: SdkConfigResponse?
    var isReady = false
    var emittedState: CheckoutState?
    var attempt: Attempt?
    var lastTransaction: SessionTransaction?
    var watcher: StatusWatcher?
    var loadTask: Task<Void, Never>?
    var readyTimer: Task<Void, Never>?
    var altchaTask: Task<AltchaSolution?, Never>?
    var altchaSpent = false
    var autoCloseTask: Task<Void, Never>?
    var threeDSTimer: Task<Void, Never>?
    var workTask: Task<Void, Never>?
    var started = false
    var clientSessionFailed = false

    /// The payment attempt under way.
    struct Attempt {
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
        /// `POST /pay/process` got no answer after its retries; the last try was sent then.
        var unansweredSince: Date?
        /// The `error_code` the payment already carried when this attempt was sent (a refusal left by an
        /// earlier try).
        var priorErrorCode: String?
    }

    /// The last `error_code` the payment was seen with (a refused try stays on it until the next one).
    var lastErrorCode: String?
    /// The `Idempotency-Key` the next Pay reuses, after a request that may never have reached the API.
    var reusableKey: String?
    /// The provider page is open in the in-app browser (not handed to another app).
    var browserInApp = false
    var cancelTask: Task<Void, Never>?

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

    var clock: WajubClock { client.clock }

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
    public var isWorking: Bool { isBusy || isCancelling || isCollectingCard || cancelTask != nil }

    /// A payment is being made (Pay shows its spinner).
    public var isPaying: Bool { isBusy || isCollectingCard }

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

    func load() {
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

    func performLoad() async {
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

    func readyTimedOut(_ milliseconds: Int) {
        guard !isReady, result == nil else { return }
        let error = WajubError.readyTimeout(after: milliseconds, language)
        screen = .loadError(error)
        update()
        emit { try self.options.callbacks.onLoadError?(error) }
    }

    func loadFailed(_ error: WajubError) {
        guard !isReady, result == nil else { return }
        readyTimer?.cancel()
        screen = .loadError(error)
        update()
        emit { try self.options.callbacks.onLoadError?(error) }
    }

    func sessionLoaded(_ session: SessionResponse, config: SdkConfigResponse?) {
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

    func endedAtLoad(_ code: String, state: CheckoutState) {
        let error = WajubError.catalogue(code, language)
        becomeReady(.ended(error, state: state), shown: [])
        emit { try self.options.callbacks.onLoadError?(error) }
    }

    /// `processing` / `partial` at load: the screen of `processing_context`, then watch.
    func restore(_ session: SessionResponse) {
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

    func becomeReady(_ screen: CheckoutScreen, shown: [SessionChannel]) {
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

    // MARK: Plumbing

    /// Recomputes the state, reports a change once, and lets the UI redraw.
    func update() {
        state = derivedState()
        if isReady, let state, state != emittedState, result == nil {
            emittedState = state
            let event = StateChangeEvent(state: state, method: attempt?.family ?? currentMethod?.family ?? "unknown")
            emit { try self.options.callbacks.onStateChange?(event) }
        }
        onChange?()
    }

    func derivedState() -> CheckoutState? {
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
    func emit(_ callback: () throws -> Void) {
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
