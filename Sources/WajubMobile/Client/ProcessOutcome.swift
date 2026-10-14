import Foundation

/// What a `202` without anything for the payer to do is waiting for.
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
    /// `confirm_url`, or `client_session.hosted_url`.
    public var url: String?
    /// `otp_id`, `pin_id`, `phone_id`, `birthday_id`, `address_id` or `three_ds_id`.
    public var stepId: String?
    /// `otp_masked_contact`, a `*_instruction`, or `masked_email`.
    public var hint: String?
    public var clientSession: ClientSession?
    public var transaction: SessionTransaction?
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
        default:
            guard let kind = ConfirmStepKind(action: action) else { return .unsupportedAction(response) }
            let body = answer.body ?? .null
            guard let id = body[kind.idKey]?.nonEmptyString else { return .unsupportedAction(response) }
            return .step(ConfirmStep(kind: kind, id: id, hint: body[kind.hintKey]?.nonEmptyString), response)
        }
    }
}

/// An Altcha solution, sent as `data.altcha` / `altcha`.
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

/// Solves Altcha proof-of-work challenges: the integer `n` in `[0, maxnumber]` with
/// `lowercase_hex(SHA-256(salt + decimal(n))) == challenge`.
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
