import Foundation

/// The payer confirmation steps and the sandbox 3-D Secure code.
extension CheckoutController {
    // MARK: Confirmation steps (README §10)

    /// Verifies a step: `code` (OTP), `pin`, `phone`, `birthday` (`YYYY-MM-DD`), or `address`, `city`, `state`, `zip_code`.
    public func submitStep(_ fields: [String: String]) {
        guard result == nil, !isWorking, case .step(var step) = screen else { return }
        let fields = fields.mapValues { Digits.ascii($0).trimmingCharacters(in: .whitespaces) }
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

    func handleStepAnswer(_ answer: APIAnswer, step: StepScreen) {
        isBusy = false
        var step = step
        switch answer.status {
        case 200...299:
            switch StepVerifyResponse(json: answer.body ?? .null) {
            case .success(let transaction):
                if let transaction { lastTransaction = transaction }
                if let transaction, transaction.status.isPaid {
                    succeed(transaction)
                } else if answer.body?["action"]?.nonEmptyString != nil {
                    // The provider chains another step (a birthday then an OTP, a PIN then a bank page):
                    // the answer is followed as a payment answer.
                    handlePaymentAnswer(answer, mobileMoney: attempt?.family == "mobile_money", clientSession: false)
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
                    // A step failed for good: the attempt is refused.
                    pendingAgain()
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
        case 500...:
            // As for a network failure: the payer stays on the step, and the status may say more.
            step.error = WajubError.from(answer, phase: .payment, language: language)
            screen = .step(step)
            update()
            watcher?.pollNow()
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
            guard Digits.isASCIIDigits(value), range.contains(value.count) else {
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
                && parts.allSatisfy { Digits.isASCIIDigits($0) }
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

    func threeDSScreen(id: String, maskedEmail: String?, timeout: Int?) -> ThreeDSScreen {
        ThreeDSScreen(id: id, maskedEmail: maskedEmail, expiresAt: timeout.map { clock.now.addingTimeInterval(TimeInterval($0)) },
                      error: nil, resendAvailableAt: clock.now.addingTimeInterval(Timing.resendAfter), accepted: false)
    }

    func startThreeDSTimer(_ challenge: ThreeDSScreen) {
        threeDSTimer?.cancel()
        guard let expiresAt = challenge.expiresAt else { return }
        threeDSTimer = Task { [weak self] in
            guard let self else { return }
            do { try await self.clock.sleep(seconds: expiresAt.timeIntervalSince(self.clock.now)) } catch { return }
            guard self.result == nil, case .threeDS(let current) = self.screen, current.id == challenge.id, !current.accepted else { return }
            self.pendingAgain()
            self.fail(.catalogue(WajubError.Code.threeDSTimeout, self.language))
        }
    }

    public func submitThreeDSCode(_ code: String) {
        guard result == nil, !isWorking, case .threeDS(var challenge) = screen else { return }
        let code = Digits.ascii(code).trimmingCharacters(in: .whitespaces)
        guard Digits.isASCIIDigits(code), (4...8).contains(code.count) else {
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
                    self.pendingAgain()
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
    func watchRefusalOrRetry(_ answer: APIAnswer, otherwise: () -> Void) {
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
}
