import Foundation

/// Watching the payment's status and deciding on it.
extension CheckoutController {
    // MARK: Watching (README §13)

    func startWatching() {
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

    func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    /// Decides on a status from a poll or the socket (README §13.2).
    func statusUpdated(_ update: StatusUpdate) {
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
            guard attempt?.seenProcessing == true else {
                giveUpOnUnansweredRequest(update)
                return
            }
            // While the provider's page is open the payer may still pay there (another card, a retry):
            // a refused try is not the end yet.
            if isBrowserOpen && browserInApp { return }
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
        guard let attempt, let since = attempt.unansweredSince, status.errorCode == nil,
              clock.now.timeIntervalSince(since) >= Timing.unansweredRequestWait else { return }
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
            error = WajubError(type: entry.type, code: code, message: entry.message(language), retryable: true)
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
            guard self.result == nil else { return }
            guard let answer, answer.isSuccess else {
                self.fail(fallback)
                return
            }
            let update = StatusResponse(json: answer.body ?? .null).transaction
            if !update.isInformative {
                // No information: wait for the status rather than refuse.
                self.attempt = self.attempt ?? Attempt(family: "unknown", channel: "", startedAt: self.clock.now)
                self.attempt?.inFlight = true
                self.screen = .pending(PendingScreen())
                self.update()
                self.startWatching()
            } else if update.status.isPaid || CheckoutController.endedStatuses.contains(update.status) {
                self.attempt = self.attempt ?? Attempt(family: "unknown", channel: "", startedAt: self.clock.now)
                self.statusUpdated(update)
            } else if update.status == .processing || update.status == .partial {
                // An attempt is running: money may move.
                self.attempt = self.attempt ?? Attempt(family: "unknown", channel: "", startedAt: self.clock.now)
                self.attempt?.inFlight = true
                self.attempt?.seenProcessing = true
                self.screen = .pending(PendingScreen())
                self.update()
                self.startWatching()
            } else {
                self.fail(fallback)
            }
        }
    }
}
