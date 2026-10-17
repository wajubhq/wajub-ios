import Foundation

/// Watching the payment's status and deciding on it.
extension CheckoutController {
    // MARK: Watching (README §13)

    func startWatching() {
        guard watcher == nil, result == nil, let session else { return }
        // 15 minutes of monotonic time from the attempt's start. Never a server timestamp against the
        // device's clock (a phone running fast would end the watch before its first poll): the API's
        // 410 says when the session is over.
        let capAt = (attempt?.startedAt ?? clock.uptime) + Timing.pollOverallCap
        let watcher = StatusWatcher(client: client, clock: clock, random: client.random, capAt: capAt)
        watcher.onUpdate = { [weak self] update in self?.statusUpdated(update) }
        watcher.onRefusal = { [weak self] answer in
            guard let self else { return }
            self.watcher = nil
            self.watchRefusalOrRetry(answer) {}
        }
        watcher.onCap = { [weak self] in self?.capReached() }
        if let endpoint = RealtimeEndpoint(echo: session.echo, override: options.realtimeOverride, transactionId: session.transaction.id) {
            watcher.attach(realtime: endpoint, connect: connectWebSocket)
        }
        self.watcher = watcher
        watcher.start()
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    /// Decides on a status from a poll or the socket (README §13.2).
    func statusUpdated(_ update: StatusUpdate) {
        if let code = update.errorCode { lastErrorCode = code }
        guard result == nil, attempt != nil, !showsOutcome, update.isInformative else { return }
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
            // Before the attempt was seen `processing`, a `pending` is the previous attempt's leftover.
            // After a request that got no answer, though, a refusal newer than the one the payment
            // carried before is this attempt refused: definitive (README §2.5, §14). Only when that
            // earlier code is known: without it, no code is taken as a refusal before the 60 s rule.
            let refusedNow = attempt?.unansweredSince != nil && attempt?.priorErrorCodeKnown == true
                && update.errorCode != nil && update.errorCode != attempt?.priorErrorCode
            guard attempt?.seenProcessing == true || refusedNow else {
                giveUpOnUnansweredRequest(update)
                return
            }
            // While the provider's page is open the payer may still pay there (another card, a retry):
            // a refused try is not the end yet. On a client session the provider's own verdict comes
            // from /pay/client-session/complete first: a payment made on the page always wins over a
            // refused try, which stands only once /complete has answered without a verdict.
            if update.errorCode == WajubError.Code.invalidOTP {
                if let instructions = attempt?.payerOTP {
                    // The operator refused the payer's code after the charge went on.
                    stopWatching()
                    pendingAgain()
                    showPayerOTP(instructions, message: strings.payerOTPRefused)
                } else {
                    // A code sent elsewhere was refused: back to the form, with the refused text.
                    backToMobileMoneyForm(payerOTPRefusal, reportsError: false)
                }
                return
            }
            if update.errorCode == WajubError.Code.otpAttemptsExceeded {
                backToMobileMoneyForm(.catalogue(WajubError.Code.otpAttemptsExceeded, language))
                return
            }
            if isBrowserOpen && browserInApp { return }
            if let attempt, attempt.clientSession != nil, !attempt.clientSessionAnswered {
                if attempt.completingClientSession { self.attempt?.heldRefusal = update }
                return
            }
            attempt?.inFlight = false
            fail(attemptEndedError(update))
        case .processing, .partial:
            attempt?.seenProcessing = true
        default:
            break
        }
    }

    /// A `POST /pay/process` that got no answer, and the payment still `pending` (never `processing`, no
    /// `error_code`) 60 s after its last try: the request most likely never reached the API. Back to the
    /// form with `network_error`; the next Pay reuses the same `Idempotency-Key` (README §2.5).
    func giveUpOnUnansweredRequest(_ status: StatusUpdate) {
        // An error_code from before this attempt is a leftover; only a newer one says the request arrived.
        // When the earlier code is unknown (an older API), no code says so: the 60 s rule applies.
        guard let attempt, let since = attempt.unansweredSince,
              status.errorCode == nil || !attempt.priorErrorCodeKnown || status.errorCode == attempt.priorErrorCode,
              clock.uptime - since >= Timing.unansweredRequestWait else { return }
        stopWatching()
        reusableKey = attempt.key
        self.attempt = nil
        let error = WajubError.catalogue(WajubError.Code.networkError, language)
        banner = error
        fieldErrors = [:]
        screen = currentMethod == nil ? .methods : .form
        update()
        emit { try self.options.callbacks.onError?(error) }
    }

    /// `pending` after `processing`: the attempt ended without charging.
    func attemptEndedError(_ update: StatusUpdate) -> WajubError {
        guard let code = update.errorCode else { return .catalogue(WajubError.Code.paymentAttemptEnded, language) }
        var error: WajubError
        if let entry = ErrorCatalogue.entries[code] {
            error = WajubError(type: entry.type, code: code, message: fill(entry.message(language), [:]), retryable: true)
        } else {
            // A provider's own decline code: the same text as a 402 with that code (errors.md §3.4).
            error = WajubError(type: .paymentError, code: code, message: ErrorCatalogue.genericDecline.message(language), retryable: true)
        }
        error.declineCode = code
        error.apiMessage = update.payerMessage
        return error
    }

    func capReached() {
        guard result == nil else { return }
        watcher = nil
        screen = .pending(PendingScreen(continueURL: attempt?.continueURL, capReached: true))
        update()
    }

    /// A `400` on `/pay/process`: the status decides (README §9).
    func rereadStatus(orFail fallback: WajubError) {
        let key = attempt?.key
        workTask = Task { [weak self] in
            guard let self else { return }
            let answer: APIAnswer?
            do {
                answer = try await self.client.send(.status)
            } catch is CancellationError {
                return
            } catch {
                answer = nil
            }
            // A dismiss, a cancel or a new attempt meanwhile: this answer is not theirs.
            guard !Task.isCancelled, self.isCurrent(key), !self.isClosing else { return }
            self.isBusy = false
            let update = answer.flatMap { $0.isSuccess ? StatusResponse(json: $0.body ?? .null).transaction : nil }
                ?? StatusUpdate(status: TransactionStatus(rawValue: ""))
            if !update.isInformative {
                // Unreadable (the read failed after its retries, or said nothing): wait for the status.
                // No information: wait for the status rather than refuse.
                self.attempt = self.attempt ?? Attempt(family: "unknown", channel: "", startedAt: self.clock.uptime)
                self.attempt?.inFlight = true
                self.screen = .pending(PendingScreen())
                self.update()
                self.startWatching()
            } else if update.status.isPaid || CheckoutController.endedStatuses.contains(update.status) {
                self.attempt = self.attempt ?? Attempt(family: "unknown", channel: "", startedAt: self.clock.uptime)
                self.statusUpdated(update)
            } else if update.status == .processing || update.status == .partial {
                // An attempt is running: money may move.
                self.attempt = self.attempt ?? Attempt(family: "unknown", channel: "", startedAt: self.clock.uptime)
                self.attempt?.inFlight = true
                self.attempt?.seenProcessing = true
                self.screen = .pending(PendingScreen())
                self.update()
                self.startWatching()
            } else {
                // Still `pending`: the request was refused, and the payment can be cancelled again.
                self.pendingAgain()
                self.fail(fallback)
            }
        }
    }
}
