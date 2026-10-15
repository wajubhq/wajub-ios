import Foundation

/// Paying: `/pay/process` and `/pay/client-session`, their answers, Altcha, provider pages.
extension CheckoutController {
    // MARK: Paying (README §9)

    /// Raw card fields the API refuses in live (`RawCardDataGuard`).
    static let rawCardKeys: Set<String> = ["card.number", "card_number", "number", "cvv", "cvc", "card_holder", "card.holder",
                                                   "expiry_month", "expiry_year", "exp", "pin"]

    func pay(channel: String, data: [String: JSONValue], family: String, mobileMoney: Bool, phone: String? = nil,
                     securityRetry: Bool = false) {
        guard result == nil else { return }
        // Card numbers, CVCs and PINs never leave the device in live.
        if !isSandbox, !Set(data.keys).isDisjoint(with: CheckoutController.rawCardKeys) {
            fail(.catalogue(WajubError.Code.rawCardDataNotAccepted, language))
            return
        }
        var attempt = Attempt(family: family, channel: channel, startedAt: clock.uptime)
        if let reusableKey {
            attempt.key = reusableKey
            self.reusableKey = nil
        }
        attempt.phone = phone
        attempt.priorErrorCode = lastErrorCode
        attempt.priorErrorCodeKnown = lastErrorCodeKnown
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
            switch await self.nextAltcha() {
            case .off:
                break
            case .solved(let solution):
                data["altcha"] = solution.json
            case .unavailable:
                guard self.isCurrent(key) else { return }
                self.notSent(.catalogue(WajubError.Code.securityCheckFailed, self.language))
                return
            }
            data["_client"] = await self.client.device.clientSignals()
            // Solving and reading the device take time: nothing is sent once the sheet moved on.
            guard self.isCurrent(key) else { return }
            let body: JSONValue = .object(["channel": .string(channel), "data": .object(data)])
            let lastSent = SentTime()
            let answer: APIAnswer
            do {
                answer = try await self.client.send(.process, body: body, idempotencyKey: key, onSend: { lastSent.record($0) })
            } catch is CancellationError {
                return
            } catch {
                // No answer after the retries: the outcome is unknown, never a failure.
                guard self.isCurrent(key) else { return }
                self.attempt?.unansweredSince = lastSent.value ?? self.clock.uptime
                self.unknownOutcome()
                return
            }
            guard self.isCurrent(key) else { return }
            // A 5xx is no answer to decide on either: the 60 s rule applies as after a timeout.
            if answer.status >= 500 { self.attempt?.unansweredSince = lastSent.value ?? self.clock.uptime }
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

    func handlePaymentAnswer(_ answer: APIAnswer, mobileMoney: Bool, clientSession: Bool) {
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
        case .unconfirmed:
            // A 2xx that says nothing of the payment: watch, as for a request without an answer.
            paymentStarted(nil, seenProcessing: false)
            screen = .pending(PendingScreen())
            update()
            startWatching()
        case .refused(let answer):
            handleRefusal(answer, clientSession: clientSession)
        }
    }

    func handleRefusal(_ answer: APIAnswer, clientSession: Bool) {
        let error = WajubError.from(answer, phase: .payment, language: language)
        let body = answer.body.map(APIErrorBody.init(json:))
        if let transaction = body?.transaction { lastTransaction = transaction }
        // A decline stays on the payment until the next try starts.
        if answer.status == 402, let code = body?.errorCode { lastErrorCode = code }
        switch answer.status {
        case 400:
            // Still busy, and the attempt undecided, until the status says what happened: no Pay, no
            // "Cancel payment", and a dismiss or the host going away resolves `processing` meanwhile.
            isBusy = true
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
            if answer.status == 402 { pendingAgain() } else { attempt?.inFlight = false }
            if clientSession { clientSessionFailed = true }
            if answer.status == 429, let seconds = error.retryAfterSeconds {
                retryAvailableAt = clock.now.addingTimeInterval(TimeInterval(seconds))
            }
            fail(error)
        }
    }

    /// A 422: back to the form with field errors (README §9.1).
    func showFieldErrors(_ answer: APIAnswer, error: WajubError) {
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
    func unknownOutcome() {
        guard result == nil else { return }
        isBusy = false
        attempt?.inFlight = true
        screen = .pending(PendingScreen())
        update()
        startWatching()
    }

    /// The first 2xx of an attempt. `seenProcessing` is false when the answer said nothing of the payment.
    func paymentStarted(_ transaction: SessionTransaction?, seenProcessing: Bool = true) {
        if let transaction { lastTransaction = transaction }
        guard var attempt, !attempt.started else { return }
        attempt.started = true
        if seenProcessing { attempt.seenProcessing = true }
        self.attempt = attempt
        let event = PaymentStartedEvent(method: attempt.family, channel: attempt.channel)
        emit { try self.options.callbacks.onPaymentStarted?(event) }
    }

    // MARK: Altcha (README §15)

    func solveAltcha(_ challenge: AltchaChallenge) {
        altchaTask?.cancel()
        altchaTask = Task.detached(priority: .userInitiated) { AltchaSolver.solve(challenge) }
    }

    /// What the next submission sends for Altcha.
    enum AltchaReadiness {
        case off
        case solved(AltchaSolution)
        /// No fresh solution (the session could not be reloaded, or the challenge not solved): send nothing.
        case unavailable
    }

    /// A solution for one submission: a solved number is spent once, so the next submission reloads the
    /// session for a new challenge first. While Altcha is on, nothing is sent without a fresh solution.
    func nextAltcha() async -> AltchaReadiness {
        guard session?.altcha != nil || altchaTask != nil else { return .off }
        if altchaSpent {
            guard await renewAltcha() else { return .unavailable }
            if session?.altcha == nil { return .off }
        }
        guard let solution = await altchaTask?.value else { return .unavailable }
        altchaSpent = true
        return .solved(solution)
    }

    /// The submission could not be made (no fresh Altcha solution): back to the form, nothing sent,
    /// and Pay can be pressed again.
    func notSent(_ error: WajubError) {
        isBusy = false
        attempt = nil
        banner = error
        fieldErrors = [:]
        update()
        emit { try self.options.callbacks.onError?(error) }
    }

    /// The 422 that refuses a missing or wrong Altcha solution: its `error_code` `security_check_failed`;
    /// from an older API, its `altcha` validation key, else (with no field at fault) its message.
    func isSecurityRefusal(_ answer: APIAnswer) -> Bool {
        guard answer.status == 422 else { return false }
        let body = answer.body.map(APIErrorBody.init(json:))
        if body?.errorCode == WajubError.Code.securityCheckFailed { return true }
        guard session?.altcha != nil || altchaTask != nil else { return false }
        let keys = Set(body?.errors.keys.map { $0 } ?? [])
        if keys.contains("altcha") || keys.contains("data.altcha") { return true }
        guard keys.isSubset(of: ["request"]) else { return false }
        let texts = [body?.message] + (body?.errors["request"] ?? []).map(Optional.some)
        return texts.contains { ($0 ?? "").lowercased().contains("security challenge") }
    }

    /// Reloads the session for a new challenge and solves it.
    /// Reloads the session (with the usual read retries) for a new challenge and solves it. `false` when
    /// the session could not be reloaded.
    @discardableResult
    func renewAltcha() async -> Bool {
        guard let answer = try? await client.send(.session), answer.isSuccess, let body = answer.body,
              let session = try? SessionResponse(json: body) else { return false }
        self.session?.altcha = session.altcha
        altchaSpent = false
        if let challenge = session.altcha { solveAltcha(challenge) } else { altchaTask = nil }
        return true
    }

    // MARK: Redirects (README §12)

    func openRedirect(_ urlString: String, threeDS: Bool) {
        attempt?.continueURL = urlString
        screen = .pending(PendingScreen(continueURL: urlString, threeDS: threeDS))
        update()
        startWatching()
        launchBrowser(urlString)
    }

    func launchBrowser(_ urlString: String) {
        emit { try self.options.callbacks.onRedirect?(RedirectEvent(url: urlString)) }
        let mode: BrowserMode = attempt?.family == "card" ? .inApp : .external
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            fail(.catalogue(WajubError.Code.redirectUnavailable, language))
            return
        }
        isBrowserOpen = true
        browserInApp = mode == .inApp
        update()
        Task { [weak self] in
            guard let self else { return }
            let opened = await self.browser.open(url, mode: mode, onClose: { [weak self] in self?.browserClosed() })
            guard !opened, self.result == nil else { return }
            self.isBrowserOpen = false
            self.browserInApp = false
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
            attempt?.startedAt = clock.uptime
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
        browserInApp = false
        update()
        payerReturned()
    }

    /// The app came back from the background (a wallet's app, the browser) or a deep link arrived: the
    /// payment is checked at once.
    public func appWillEnterForeground() {
        guard result == nil else { return }
        if watcher == nil {
            // After the watch cap: one look at the status.
            if case .pending = screen, attempt != nil { checkStatusOnce() }
            return
        }
        if isBrowserOpen && browserInApp {
            // The payer went to their bank's app or messages while the provider page is still open:
            // look at the status, but the page is not done (a client session completes when it closes).
            watcher?.pollNow()
            return
        }
        isBrowserOpen = false
        update()
        payerReturned()
    }

    func checkStatusOnce() {
        workTask = Task { [weak self] in
            guard let self, let answer = try? await self.client.send(.status), answer.isSuccess, self.result == nil else { return }
            self.statusUpdated(StatusResponse(json: answer.body ?? .null).transaction)
        }
    }

    func payerReturned() {
        guard result == nil else { return }
        if let session = attempt?.clientSession {
            completeClientSession(session)
        } else {
            watcher?.pollNow()
        }
    }

    /// `POST /pay/client-session/complete`, one at a time (two quick returns send one). Its verdict
    /// decides over a refused try the watch reads meanwhile; without a verdict (still processing, or no
    /// answer), that refused try stands, and the watch decides from then on.
    func completeClientSession(_ session: ClientSession) {
        guard attempt?.completingClientSession == false else { return }
        attempt?.completingClientSession = true
        attempt?.clientSessionAnswered = false
        attempt?.heldRefusal = nil
        let key = attempt?.key
        workTask = Task { [weak self] in
            guard let self else { return }
            let answer: APIAnswer
            do {
                answer = try await self.client.send(.clientSessionComplete, body: ["client_session_id": .string(session.id)])
            } catch {
                guard self.isCurrent(key) else { return }
                self.clientSessionUndecided()
                return
            }
            guard self.isCurrent(key) else { return }
            self.attempt?.completingClientSession = false
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
                    self.clientSessionUndecided()
                }
            case 402, 422:
                if let transaction = body?.transaction { self.lastTransaction = transaction }
                if answer.status == 402, let code = body?.errorCode { self.lastErrorCode = code }
                self.pendingAgain()
                self.clientSessionFailed = true
                self.fail(WajubError.from(answer, phase: .payment, language: self.language))
            case 410:
                self.attempt?.inFlight = false
                self.expire(WajubError.from(answer, phase: .payment, language: self.language))
            default:
                self.clientSessionUndecided()
            }
        }
    }

    /// `/complete` gave no verdict: a refused try read meanwhile stands, else the watch looks at once.
    func clientSessionUndecided() {
        attempt?.completingClientSession = false
        attempt?.clientSessionAnswered = true
        if let held = attempt?.heldRefusal {
            attempt?.heldRefusal = nil
            statusUpdated(held)
        } else {
            watcher?.pollNow()
        }
    }
}

/// When the last try of a request was sent (monotonic seconds).
final class SentTime: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval?

    var value: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return time
    }

    func record(_ time: TimeInterval) {
        lock.lock()
        self.time = time
        lock.unlock()
    }
}
