import Foundation

/// What a payment under way is waiting for.
public enum ProcessingKind: String, Sendable {
    /// A push was sent to the payer's phone.
    case approval
    /// The payer dials a USSD code.
    case ussd
    /// Nothing for the payer to do.
    case pending
}

/// A step the payer must take before the payment can finish.
public struct RequiredAction: Equatable, Sendable {
    public var action: ProcessAction
    /// The page to open, when the step is a page.
    public var url: String?
    /// The step's id, for `WajubSession.verify(_:id:fields:)` or the 3-D Secure calls.
    public var stepId: String?
    /// Where the code was sent, or the step's instruction.
    public var hint: String?
    public var clientSession: ClientSession?
    public var transaction: SessionTransaction?
    /// With `.payerOTP`: how the payer gets the code their operator asks for. Nothing was charged: pay
    /// again with the code the payer generated, as `otp` in `data`.
    public var payerOTP: PayerOTPInstructions? = nil
}

/// The mapping of one payment answer, for hosts that draw their own UI (`WajubSession.process(…)`).
public enum ProcessOutcome: Equatable, Sendable {
    case complete(transaction: SessionTransaction)
    case processing(transaction: SessionTransaction?, instruction: String?, kind: ProcessingKind)
    case requiresAction(RequiredAction)
    case failed(error: WajubError, transaction: SessionTransaction?)

    init(_ answer: PaymentAnswer, language: WajubLanguage) {
        switch answer {
        case .succeeded(let transaction):
            self = .complete(transaction: transaction)
        case .processing(let kind, let response):
            self = .processing(transaction: response.transaction,
                               instruction: response.transaction?.processingContext?.payerInstruction, kind: kind)
        case .redirect(let url, _, let response):
            self = .requiresAction(RequiredAction(action: response.action ?? .redirect, url: url, stepId: response.threeDSId,
                                                  transaction: response.transaction))
        case .threeDSCode(let challenge, let response):
            self = .requiresAction(RequiredAction(action: .confirm3DS, stepId: challenge.id, hint: challenge.maskedEmail,
                                                  transaction: response.transaction))
        case .step(let step, let response):
            self = .requiresAction(RequiredAction(action: step.kind.action, stepId: step.id, hint: step.hint,
                                                  transaction: response.transaction))
        case .clientSession(let session, let response):
            self = .requiresAction(RequiredAction(action: .clientSession, url: session.hostedURL, clientSession: session,
                                                  transaction: response.transaction))
        case .payerOTP(let instructions, let response):
            self = .requiresAction(RequiredAction(action: .payerOTP, transaction: response.transaction, payerOTP: instructions))
        case .unsupportedAction(let response):
            self = .failed(error: .catalogue(WajubError.Code.unsupportedAction, language), transaction: response.transaction)
        case .unconfirmed:
            self = .processing(transaction: nil, instruction: nil, kind: .pending)
        case .refused(let answer):
            let body = answer.body.map(APIErrorBody.init(json:))
            if answer.status == 409, body?.errorCode == WajubError.Code.paymentInProgress {
                self = .processing(transaction: nil, instruction: nil, kind: .pending)
            } else if answer.status >= 500 {
                self = .processing(transaction: nil, instruction: nil, kind: .pending)
            } else {
                self = .failed(error: .from(answer, phase: .payment, language: language), transaction: body?.transaction)
            }
        }
    }
}

/// The sandbox 3-D Secure email challenge.
struct ThreeDSChallenge: Equatable, Sendable {
    var id: String
    var maskedEmail: String?
    /// Seconds.
    var timeout: Int?
}

/// A confirmation step announced by a `202`.
struct ConfirmStep: Equatable, Sendable {
    var kind: ConfirmStepKind
    var id: String
    var hint: String?

    /// Where the OTP was sent: the masked number or address only (two comma-separated), `nil` when the
    /// provider names none. An older answer could carry the provider's whole sentence ("Please enter
    /// the OTP sent to 080******78"): only its contact is kept, never the sentence.
    static func otpContact(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.allSatisfy({ !$0.isEmpty && !$0.contains(" ") }) { return raw }
        let contacts = raw.split(whereSeparator: { $0 == " " || $0 == "," })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".:;!?()")) }
            .filter { token in token.contains("*") || token.contains("@") || token.filter(\.isNumber).count >= 4 }
        return contacts.isEmpty ? nil : contacts.joined(separator: ", ")
    }
}

/// How a payment answer is handled (README §9): decided on the HTTP status, `action` and
/// `transaction.status`, never on `message`.
enum PaymentAnswer: Sendable {
    case succeeded(SessionTransaction)
    case processing(ProcessingKind, ProcessResponse)
    /// `redirect`, `confirm`, or `confirm_3ds` with a `confirm_url`.
    case redirect(url: String, threeDS: Bool, ProcessResponse)
    case threeDSCode(ThreeDSChallenge, ProcessResponse)
    case step(ConfirmStep, ProcessResponse)
    case clientSession(ClientSession, ProcessResponse)
    /// `payer_otp`: the payer generates a code in the operator's menu; nothing was charged.
    case payerOTP(PayerOTPInstructions, ProcessResponse)
    case unsupportedAction(ProcessResponse)
    /// A 2xx with neither `action` nor `transaction`.
    case unconfirmed(ProcessResponse)
    /// Any non-2xx answer.
    case refused(APIAnswer)

    /// - Parameters:
    ///   - mobileMoney: the attempt was made on a Mobile Money channel.
    ///   - allowsClientSession: the answer comes from `/pay/client-session`.
    static func classify(_ answer: APIAnswer, mobileMoney: Bool, allowsClientSession: Bool) -> PaymentAnswer {
        guard answer.isSuccess else { return .refused(answer) }
        let response = ProcessResponse(json: answer.body ?? .null)
        guard let action = response.action else {
            // Nothing says what happened: an unknown outcome, to watch (never a failure).
            guard let transaction = response.transaction else { return .unconfirmed(response) }
            if transaction.status.isPaid {
                return .succeeded(transaction)
            }
            let context = response.transaction?.processingContext
            if context?.isUSSD == true { return .processing(.ussd, response) }
            if mobileMoney || context?.isMobileMoney == true { return .processing(.approval, response) }
            return .processing(.pending, response)
        }
        switch action {
        case .redirect, .confirm:
            guard let url = response.confirmURL else { return .unsupportedAction(response) }
            return .redirect(url: url, threeDS: false, response)
        case .confirm3DS:
            if let url = response.confirmURL { return .redirect(url: url, threeDS: true, response) }
            guard let id = response.threeDSId else { return .unsupportedAction(response) }
            return .threeDSCode(ThreeDSChallenge(id: id, maskedEmail: response.maskedEmail, timeout: response.threeDSTimeout), response)
        case .clientSession:
            guard allowsClientSession, let session = response.clientSession, !session.id.isEmpty, session.hostedURL != nil else {
                return .unsupportedAction(response)
            }
            return .clientSession(session, response)
        case .payerOTP:
            guard let instructions = response.payerOTP else { return .unsupportedAction(response) }
            return .payerOTP(instructions, response)
        default:
            guard let kind = ConfirmStepKind(action: action) else { return .unsupportedAction(response) }
            let body = answer.body ?? .null
            guard let id = body[kind.idKey]?.nonEmptyString else { return .unsupportedAction(response) }
            let hint = body[kind.hintKey]?.nonEmptyString
            return .step(ConfirmStep(kind: kind, id: id, hint: kind == .otp ? ConfirmStep.otpContact(hint) : hint), response)
        }
    }
}

/// A solved security check of the payment.
public struct AltchaSolution: Equatable, Sendable {
    public var algorithm: String
    public var challenge: String
    public var number: Int
    public var salt: String
    public var signature: String

    var json: JSONValue {
        .object(["algorithm": .string(algorithm), "challenge": .string(challenge), "number": .number(Double(number)),
                 "salt": .string(salt), "signature": .string(signature)])
    }
}

/// Solves the payment's security check (`SessionResponse.altcha`).
public enum AltchaSolver {
    public static func solve(_ challenge: AltchaChallenge) -> AltchaSolution? {
        let algorithm = challenge.algorithm.uppercased().replacingOccurrences(of: "-", with: "")
        guard algorithm == "SHA256", let target = Digest.bytes(hex: challenge.challenge), challenge.maxNumber >= 0 else {
            return nil
        }
        let salt = Array(challenge.salt.utf8)
        for number in 0...challenge.maxNumber {
            if number % 4096 == 0, Task.isCancelled { return nil }
            if Digest.sha256(Data(salt + Array(String(number).utf8))) == target {
                return AltchaSolution(algorithm: challenge.algorithm, challenge: challenge.challenge, number: number,
                                      salt: challenge.salt, signature: challenge.signature)
            }
        }
        return nil
    }
}
