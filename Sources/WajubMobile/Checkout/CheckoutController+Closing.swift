import Foundation

/// Outcomes, "Try again", cancel, dismiss, and the result.
extension CheckoutController {
    // MARK: Outcomes

    func succeed(_ transaction: SessionTransaction) {
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

    func fail(_ error: WajubError) {
        guard result == nil, !showsOutcome else { return }
        workTask?.cancel()
        stopWatching()
        // Nothing to continue after a failure, unless the page never opened ("Try again" reopens it).
        if error.code != WajubError.Code.redirectUnavailable { attempt?.continueURL = nil }
        threeDSTimer?.cancel()
        isBusy = false
        screen = .failed(error)
        update()
        emit { try self.options.callbacks.onError?(error) }
    }

    func expire(_ error: WajubError) {
        guard result == nil, !showsOutcome else { return }
        workTask?.cancel()
        stopWatching()
        attempt?.continueURL = nil
        threeDSTimer?.cancel()
        isBusy = false
        screen = .expired(error)
        update()
        emit { try self.options.callbacks.onError?(error) }
    }

    func scheduleAutoClose() {
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
    var showsOutcome: Bool {
        switch screen {
        case .success, .failed, .expired, .cancelled, .ended: return true
        default: return false
        }
    }

    /// An answer belongs to the attempt still on screen.
    func isCurrent(_ key: String?) -> Bool {
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
        runCancel(reason: .payerCancelled)
    }

    /// `POST /pay/cancel`, then the result. It runs to its end: nothing interrupts it, so the API hears
    /// of the cancel and its `redirect_url` is kept.
    func runCancel(reason: CancelReason) {
        guard cancelTask == nil else { return }
        // Whoever asked (the X, a swipe, "Cancel payment"), nothing is paid while the cancel runs.
        isCancelling = true
        update()
        cancelTask = Task { [weak self] in
            guard let self else { return }
            let answer = try? await self.client.send(.cancel)
            guard self.result == nil else { return }
            if let answer, answer.status == 400 {
                await self.resolveRefusedCancel(reason: reason)
                // The sheet stayed open (paid, or a payment still running): later closes are ordinary.
                self.cancelTask = nil
                return
            }
            self.isCancelling = false
            let redirect = answer.flatMap { $0.isSuccess ? CancelResponse(json: $0.body ?? .null).redirectURL : nil }
            if reason == .payerCancelled {
                self.screen = .cancelled(nil)
                self.update()
            }
            self.finish(.cancelled(reason: reason, redirectURL: redirect))
        }
    }

    /// A cancel answered `400`: the status says what happened.
    func resolveRefusedCancel(reason: CancelReason) async {
        let answer = try? await client.send(.status)
        guard result == nil else { return }
        isCancelling = false
        let status = answer.flatMap { answer -> TransactionStatus? in
            guard answer.isSuccess else { return nil }
            let update = StatusResponse(json: answer.body ?? .null).transaction
            return update.isInformative ? update.status : nil
        }
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
            // `processing`, `partial`, or no readable answer: money may move (CN-04).
            finish(.processing(transaction: transaction))
        }
    }

    /// The payer closed the sheet (swipe down, close button). Before any attempt this cancels the
    /// payment unless `cancelOnDismiss` is `false`; while an attempt runs it resolves `processing`.
    public func dismiss() {
        guard result == nil else { return }
        isClosing = true
        // A cancel is on its way: its answer settles the sheet.
        guard cancelTask == nil else { return }
        if let settled = settledResult() {
            finish(settled)
            return
        }
        // The session has not answered: nothing to cancel.
        guard let loaded = session ?? answeredSession else {
            finish(.cancelled(reason: .dismissed, redirectURL: nil))
            return
        }
        // Once it has answered, the last status known decides at once (sdk-config may still be loading).
        let status = lastKnownStatus ?? loaded.transaction.status
        if status == .processing || status == .partial {
            finish(.processing(transaction: lastTransaction ?? loaded.transaction))
            return
        }
        guard options.cancelOnDismiss, mayCancel else {
            finish(.cancelled(reason: .dismissed, redirectURL: nil))
            return
        }
        stopWatching()
        workTask?.cancel()
        runCancel(reason: .dismissed)
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
    func settledResult() -> CheckoutResult? {
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

    func finish(_ result: CheckoutResult) {
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
}
