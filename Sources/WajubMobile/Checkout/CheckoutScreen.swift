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
    /// The payer's own code was received: say so instead of asking to approve on the phone.
    public var payerOTPReceived = false

    /// What the screen says: its title, the line naming the amount and the phone the request went to,
    /// and the line waiting on the phone. After the payer's own code, only that it was received.
    package struct Texts: Equatable, Sendable {
        package var title: String
        package var phoneLine: String?
        package var waiting: String?
    }

    package func texts(_ strings: WajubStrings, amount: String) -> Texts {
        if payerOTPReceived {
            return Texts(title: strings.payerOTPApprovalMessage, phoneLine: nil, waiting: nil)
        }
        return Texts(title: strings.approvalTitle, phoneLine: strings.approvalBody(amount: amount, phone: phone),
                     waiting: strings.waitingForApproval)
    }
}

/// The code the payer generates in their operator's menu, for the exact amount, before paying.
/// While it is shown, `CheckoutController.screen` is `.form` and `stateName` is `PAYER_OTP_REQUIRED`.
public struct PayerOTPScreen: Equatable, Sendable {
    /// One step to get the code, in parts to draw: the code to dial and the amount stand out.
    public struct StepLine: Equatable, Sendable {
        public enum Part: Equatable, Sendable {
            case text(String)
            /// The code to dial (copy it; iOS cannot dial it from a link).
            case ussdCode(String)
            /// The exact amount, to show in bold.
            case amount(String)
        }

        public var parts: [Part]

        /// The step as plain text.
        public var text: String {
            parts.map { part -> String in
                switch part {
                case .text(let text), .ussdCode(let text), .amount(let text): return text
                }
            }.joined()
        }
    }

    public var instructions: PayerOTPInstructions
    /// The steps in the sheet's language.
    public var steps: [StepLine]
    /// Why the last code was not taken, shown on the screen.
    public var message: String?
    /// How many more codes the operator may refuse, when the answer said it.
    public var attemptsRemaining: Int?
    /// In a sandbox payment, the code the test operator takes.
    public var sandboxCode: String?
    /// The code's length: exactly `instructions.otpLength`, else 4 to 8 digits.
    public var lengthRange: ClosedRange<Int> {
        instructions.otpLength.map { $0...$0 } ?? 4...8
    }

    /// The exact amount to type, as the operator wants it; `nil` when none was given.
    public var exactAmount: String? {
        guard !instructions.amount.isEmpty else { return nil }
        return instructions.currency.isEmpty ? instructions.amount : "\(instructions.amount) \(instructions.currency)"
    }
    /// Increases with each answer that refused a code, so a drawn field can empty itself then.
    public var refusals = 0

    init(instructions: PayerOTPInstructions, language: WajubLanguage, sandbox: Bool) {
        self.instructions = instructions
        steps = PayerOTPScreen.lines(instructions, language: language)
        sandboxCode = sandbox ? PayerOTPScreen.sandboxCode : nil
    }

    /// The code the sandbox operator takes.
    static let sandboxCode = "123456"

    /// The steps of the sheet's language (else English, else French), from their template, or their text
    /// when the template names something else or misses a value; none: the generic steps.
    static func lines(_ instructions: PayerOTPInstructions, language: WajubLanguage) -> [StepLine] {
        let steps = instructions.steps[language.rawValue] ?? instructions.steps["en"] ?? instructions.steps["fr"] ?? []
        guard !steps.isEmpty else {
            return WajubStrings(language).payerOTPGenericSteps.map { template in
                // Without an amount, the step says it without one.
                let bare = template.replacingOccurrences(of: " : {amount}", with: "").replacingOccurrences(of: ": {amount}", with: "")
                return line(template, ussdCode: instructions.ussdCode, amount: instructions.amount, currency: instructions.currency,
                            genericAmount: true) ?? StepLine(parts: [.text(bare)])
            }
        }
        return steps.map { step in
            step.template.flatMap {
                line($0, ussdCode: instructions.ussdCode, amount: instructions.amount, currency: instructions.currency, genericAmount: false)
            } ?? StepLine(parts: [.text(step.text)])
        }
    }

    /// A template's parts, or `nil` when it names another placeholder or one without a value.
    private static func line(_ template: String, ussdCode: String?, amount: String, currency: String, genericAmount: Bool) -> StepLine? {
        var parts: [StepLine.Part] = []
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            guard let close = rest[open...].firstIndex(of: "}") else { break }
            if open > rest.startIndex { parts.append(.text(String(rest[rest.startIndex..<open]))) }
            switch rest[rest.index(after: open)..<close] {
            case "ussd_code":
                guard let ussdCode else { return nil }
                parts.append(.ussdCode(ussdCode))
            case "amount":
                guard !amount.isEmpty else { return nil }
                parts.append(.amount(genericAmount && !currency.isEmpty ? "\(amount) \(currency)" : amount))
            case "currency":
                guard !currency.isEmpty else { return nil }
                parts.append(.text(currency))
            default:
                return nil
            }
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty { parts.append(.text(String(rest))) }
        return StepLine(parts: parts)
    }
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

    /// The values to send, trimmed, with ASCII digits (the country upper-cased).
    var payload: [String: String] {
        var payload: [String: String] = [:]
        for field in fields {
            let value = Digits.ascii(values[field] ?? "").trimmingCharacters(in: .whitespaces)
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
