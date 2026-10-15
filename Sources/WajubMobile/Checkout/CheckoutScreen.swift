import Foundation

/// What the sheet draws. `CheckoutController.state` is derived from it.
public enum CheckoutScreen: Equatable, Sendable {
    /// The loader (skeleton or spinner) before the first screen.
    case loading
    /// A load error (`session_not_found`, `load_error`, `ready_timeout`, `no_payment_method`…):
    /// Retry when `retryable`, and Close.
    case loadError(WajubError)
    /// The method list.
    case methods
    /// The form of `CheckoutController.currentMethod`.
    case form
    /// "Approve the payment on your phone".
    case approval(ApprovalScreen)
    /// "Dial this code".
    case ussd(instruction: String?)
    /// A confirmation step (OTP, PIN, phone, birthday, address).
    case step(StepScreen)
    /// The sandbox 3-D Secure email code.
    case threeDS(ThreeDSScreen)
    /// "Payment in progress".
    case pending(PendingScreen)
    case success(PaymentSuccess)
    /// "Try again" when the error is retryable, and Close.
    case failed(WajubError)
    /// A session that had already ended when the sheet opened.
    case ended(WajubError, state: CheckoutState)
    case expired(WajubError)
    /// Cancelled by the payer, or a `cancelled` status seen (with `payment_cancelled`).
    case cancelled(WajubError?)
}

public struct ApprovalScreen: Equatable, Sendable {
    /// The number the push was sent to, when the sheet knows it.
    public var phone: String?
    /// The operator's instruction (English), which may give a code to dial.
    public var instruction: String?
}

public struct StepScreen: Equatable, Sendable {
    public var kind: ConfirmStepKind
    public var id: String
    /// Where the code was sent, or the step's instruction (English).
    public var hint: String?
    public var attemptsRemaining: Int?
    /// The last refusal, shown inline.
    public var error: WajubError?
    public var resendAvailableAt: Date
}

public struct ThreeDSScreen: Equatable, Sendable {
    public var id: String
    public var maskedEmail: String?
    public var expiresAt: Date?
    public var error: WajubError?
    public var resendAvailableAt: Date
    /// The code was accepted: the sheet waits for the payment (`VERIFYING`).
    public var accepted: Bool
}

public struct PendingScreen: Equatable, Sendable {
    /// A provider page "Continue payment" reopens.
    public var continueURL: String?
    /// 3-D Secure runs in the browser (`3DS_REQUIRED` while it is open).
    public var threeDS: Bool
    /// The sheet stopped waiting for the outcome: the payer is told they will be notified.
    public var capReached: Bool

    public init(continueURL: String? = nil, threeDS: Bool = false, capReached: Bool = false) {
        self.continueURL = continueURL
        self.threeDS = threeDS
        self.capReached = capReached
    }
}

/// The card form: the contact fields a provider asks for, or the sandbox test card.
public struct CardForm: Equatable, Sendable {
    public static let sandboxFields = ["card.number", "card_holder", "expiry_month", "expiry_year", "cvv"]

    public let flavour: CardFlavour
    /// The fields to collect, in order.
    public let fields: [String]
    public internal(set) var values: [String: String]

    init(flavour: CardFlavour, customer: Customer?) {
        self.flavour = flavour
        let fields: [String]
        switch flavour {
        case .clientSession(let contactFields), .hostedRedirect(let contactFields): fields = contactFields
        case .sandboxForm: fields = CardForm.sandboxFields
        case .stripe: fields = []
        }
        self.fields = fields
        var values: [String: String] = [:]
        if let email = customer?.email { values["email"] = email }
        if let name = customer?.name {
            let parts = name.split(separator: " ", maxSplits: 1).map(String.init)
            values["first_name"] = parts.first
            if parts.count > 1 { values["last_name"] = parts[1] }
        }
        self.values = values.filter { fields.contains($0.key) }
    }

    /// `field_required`, `invalid_email`, or a country that is not ISO-2, per field.
    func validate(_ language: WajubLanguage) -> [String: WajubError] {
        var errors: [String: WajubError] = [:]
        for field in fields {
            let value = (values[field] ?? "").trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                errors[field] = .catalogue(WajubError.Code.fieldRequired, language)
            } else if field == "email", !CardForm.isEmail(value) {
                errors[field] = .catalogue(WajubError.Code.invalidEmail, language)
            } else if field == "country", value.count != 2 || !value.allSatisfy(\.isLetter) {
                errors[field] = .catalogue(WajubError.Code.validationError, language)
            }
        }
        return errors
    }

    /// The values to send, trimmed (the country upper-cased).
    var payload: [String: String] {
        var payload: [String: String] = [:]
        for field in fields {
            let value = (values[field] ?? "").trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            payload[field] = field == "country" ? value.uppercased() : value
        }
        return payload
    }

    static func isEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !parts[1].hasPrefix(".")
            && !parts[1].hasSuffix(".") && !text.contains(" ")
    }
}
