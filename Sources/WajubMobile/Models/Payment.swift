import Foundation

/// How one payment method is collected.
public struct SdkChannelConfig: Equatable, Sendable {
    public var available: Bool
    /// The payment provider expected to charge; `ClientSession.provider` says which one did.
    public var provider: String?
    /// How the payment details are collected; the sheet reads it, your app does not need it.
    public var sdk: String?
    public var publishableKey: String?
    public var requiredFields: [String]
    /// The card is paid on the provider's own payment page.
    public var clientSession: Bool

    public init(json: JSONValue) {
        available = json["available"]?.bool ?? true
        provider = json["provider"]?.nonEmptyString
        sdk = json["sdk"]?.nonEmptyString
        publishableKey = json["publishable_key"]?.nonEmptyString
        requiredFields = json["required_fields"]?.strings ?? []
        clientSession = json["client_session"]?.bool ?? false
    }

    public init(available: Bool = true, provider: String? = nil, sdk: String?, publishableKey: String? = nil,
                requiredFields: [String], clientSession: Bool = false) {
        self.available = available
        self.provider = provider
        self.sdk = sdk
        self.publishableKey = publishableKey
        self.requiredFields = requiredFields
        self.clientSession = clientSession
    }
}

/// How each payment method of the payment is collected.
public struct SdkConfigResponse: Equatable, Sendable {
    /// Keyed by the slug of a channel (`SessionChannel.slug`) or of one of its operators
    /// (`ChannelOperator.slug`). The payment's own channels decide what is offered.
    public var channels: [String: SdkChannelConfig]

    public init(json: JSONValue) {
        var channels: [String: SdkChannelConfig] = [:]
        for (slug, entry) in json["channels"]?.object ?? [:] where entry.object != nil {
            channels[slug] = SdkChannelConfig(json: entry)
        }
        self.channels = channels
    }

    public init(channels: [String: SdkChannelConfig]) {
        self.channels = channels
    }
}

/// A payment's status, as `WajubSession.status()` reads it.
public struct StatusUpdate: Equatable, Sendable {
    /// Wajub's payment id (= `SessionTransaction.id`), not the merchant's reference.
    public var reference: String?
    public var status: TransactionStatus
    /// Only when an attempt was refused and the payment is back at `pending`.
    public var errorCode: String?
    public var payerMessage: String?

    /// `false` when the answer said nothing about the status.
    public var isInformative: Bool { !status.rawValue.isEmpty }

    public init(json: JSONValue) {
        reference = json["reference"]?.nonEmptyString ?? json["uid"]?.nonEmptyString
        status = TransactionStatus(rawValue: json["status"]?.string ?? "")
        errorCode = json["error_code"]?.nonEmptyString
        payerMessage = json["payer_message"]?.nonEmptyString
    }

    public init(status: TransactionStatus, errorCode: String? = nil, payerMessage: String? = nil, reference: String? = nil) {
        self.status = status
        self.errorCode = errorCode
        self.payerMessage = payerMessage
        self.reference = reference
    }
}

/// What `WajubSession.status()` returns.
public struct StatusResponse: Equatable, Sendable {
    public var transaction: StatusUpdate

    public init(json: JSONValue) {
        transaction = StatusUpdate(json: json["transaction"] ?? .null)
    }
}

/// A live update of the payment's status, as the sheet receives it.
public struct PaymentStatusUpdatedEvent: Equatable, Sendable {
    public var update: StatusUpdate
    public var statusLabel: String?

    public init?(data: JSONValue) {
        var payload = data
        if case .string(let text) = data {
            guard let parsed = try? JSONValue.parse(text) else { return nil }
            payload = parsed
        }
        guard payload.object != nil, payload["status"]?.nonEmptyString != nil else { return nil }
        update = StatusUpdate(json: payload)
        statusLabel = payload["status_label"]?.nonEmptyString
    }
}

/// The card provider's own payment page, opened for this payment.
public struct ClientSession: Equatable, Sendable {
    /// Its id, for `WajubSession.completeClientSession(id:)`.
    public var id: String
    /// The provider that charges.
    public var provider: String?
    public var reference: String?
    /// In the provider's own units.
    public var amount: Double?
    public var currency: String?
    public var hostedURL: String?
    public var accessCode: String?
    public var publicKey: String?
    public var encryptionKey: String?
    public var customerEmail: String?
    public var customerName: String?

    public init(json: JSONValue) {
        id = json["id"]?.string ?? ""
        provider = json["provider"]?.nonEmptyString
        reference = json["reference"]?.nonEmptyString
        amount = json["amount"]?.double
        currency = json["currency"]?.nonEmptyString
        hostedURL = json["hosted_url"]?.nonEmptyString
        accessCode = json["access_code"]?.nonEmptyString
        publicKey = json["public_key"]?.nonEmptyString
        encryptionKey = json["encryption_key"]?.nonEmptyString
        customerEmail = json["customer_email"]?.nonEmptyString
        customerName = json["customer_name"]?.nonEmptyString
    }
}

/// What a payment asks for next. Unknown values are kept as they are.
public struct ProcessAction: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let redirect = ProcessAction(rawValue: "redirect")
    public static let confirm = ProcessAction(rawValue: "confirm")
    public static let confirm3DS = ProcessAction(rawValue: "confirm_3ds")
    public static let confirmOTP = ProcessAction(rawValue: "confirm_otp")
    public static let confirmPIN = ProcessAction(rawValue: "confirm_pin")
    public static let confirmPhone = ProcessAction(rawValue: "confirm_phone")
    public static let confirmBirthday = ProcessAction(rawValue: "confirm_birthday")
    public static let confirmAddress = ProcessAction(rawValue: "confirm_address")
    public static let clientSession = ProcessAction(rawValue: "client_session")
    /// The payer generates a code in their operator's menu, sent with the payment (`PayerOTPInstructions`).
    public static let payerOTP = ProcessAction(rawValue: "payer_otp")
}

/// How the payer generates the code their operator asks for, for the exact amount, before paying
/// (Orange in Burkina Faso, for instance).
public struct PayerOTPInstructions: Equatable, Sendable {
    /// One step to get the code: `text` as written, `template` with `{ussd_code}`, `{amount}`, `{currency}`.
    public struct Step: Equatable, Sendable {
        public var text: String
        public var template: String?
    }

    /// The channel that asks for the code.
    public var channel: String
    /// The code to dial in the operator's menu, when there is one.
    public var ussdCode: String?
    /// The code's exact number of digits; `nil`: 4 to 8.
    public var otpLength: Int?
    /// The exact amount to type, as written (never reformat it).
    public var amount: String
    public var currency: String
    /// The steps, by language (`en`, `fr`…).
    public var steps: [String: [Step]]
    /// Why the code is asked: `required`, `invalid` (malformed) or `refused` (the operator refused it).
    public var reason: String?
    /// How many more codes the operator may refuse for this payment on this channel.
    public var attemptsRemaining: Int?

    public init(json: JSONValue) {
        channel = json["channel"]?.string ?? ""
        ussdCode = json["ussd_code"]?.nonEmptyString
        // Outside 1 to 12 digits: no length given.
        otpLength = json["otp_length"]?.int.flatMap { (1...12).contains($0) ? $0 : nil }
        amount = json["amount"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
        currency = json["currency"]?.string ?? ""
        var steps: [String: [Step]] = [:]
        for (language, list) in json["steps"]?.object ?? [:] {
            let parsed = (list.array ?? []).compactMap { entry -> Step? in
                // A step given as a plain string is its text.
                if let text = entry.nonEmptyString { return Step(text: text, template: nil) }
                guard let text = entry["text"]?.nonEmptyString ?? entry["template"]?.nonEmptyString else { return nil }
                return Step(text: text, template: entry["template"]?.nonEmptyString)
            }
            // An empty list counts as none, so another language applies.
            if !parsed.isEmpty { steps[language] = parsed }
        }
        self.steps = steps
        reason = json["reason"]?.nonEmptyString
        attemptsRemaining = json["attempts_remaining"]?.int.map { max($0, 0) }
    }
}

/// A payment answer: its transaction and what it asks for next.
public struct ProcessResponse: Equatable, Sendable {
    /// Never used to decide anything.
    public var message: String?
    public var action: ProcessAction?
    public var transaction: SessionTransaction?
    public var confirmURL: String?
    public var threeDSId: String?
    public var threeDSMethod: String?
    public var maskedEmail: String?
    public var threeDSTimeout: Int?
    public var otpId: String?
    public var otpMaskedContact: String?
    public var pinId: String?
    public var pinInstruction: String?
    public var phoneId: String?
    public var phoneInstruction: String?
    public var birthdayId: String?
    public var birthdayInstruction: String?
    public var addressId: String?
    public var addressInstruction: String?
    public var clientSession: ClientSession?
    /// When the payment asks for the payer's own code (`ProcessAction.payerOTP`): how the payer gets it,
    /// why it is asked, the tries left.
    public var payerOTP: PayerOTPInstructions?

    public init(json: JSONValue) {
        message = json["message"]?.nonEmptyString
        action = json["action"]?.nonEmptyString.map(ProcessAction.init(rawValue:))
        transaction = SessionTransaction.optional(json["transaction"])
        confirmURL = json["confirm_url"]?.nonEmptyString
        threeDSId = json["three_ds_id"]?.nonEmptyString
        threeDSMethod = json["three_ds_method"]?.nonEmptyString
        maskedEmail = json["masked_email"]?.nonEmptyString
        threeDSTimeout = json["three_ds_timeout"]?.int
        otpId = json["otp_id"]?.nonEmptyString
        otpMaskedContact = json["otp_masked_contact"]?.nonEmptyString
        pinId = json["pin_id"]?.nonEmptyString
        pinInstruction = json["pin_instruction"]?.nonEmptyString
        phoneId = json["phone_id"]?.nonEmptyString
        phoneInstruction = json["phone_instruction"]?.nonEmptyString
        birthdayId = json["birthday_id"]?.nonEmptyString
        birthdayInstruction = json["birthday_instruction"]?.nonEmptyString
        addressId = json["address_id"]?.nonEmptyString
        addressInstruction = json["address_instruction"]?.nonEmptyString
        clientSession = json["client_session"].flatMap { $0.object == nil ? nil : ClientSession(json: $0) }
        payerOTP = json["payer_otp"].flatMap { $0.object == nil ? nil : PayerOTPInstructions(json: $0) }
    }
}

/// A confirmation step: a code, a PIN, a phone number, a date of birth or an address.
public enum ConfirmStepKind: String, CaseIterable, Sendable {
    case otp, pin, phone, birthday, address

    /// Where the step's id is read from in a payment answer; your app does not need it.
    public var idKey: String { "\(rawValue)_id" }

    var action: ProcessAction { ProcessAction(rawValue: "confirm_\(rawValue)") }

    /// The `202` key holding the step's hint.
    var hintKey: String { self == .otp ? "otp_masked_contact" : "\(rawValue)_instruction" }

    init?(action: ProcessAction) {
        guard action.rawValue.hasPrefix("confirm_"),
              let kind = ConfirmStepKind(rawValue: String(action.rawValue.dropFirst("confirm_".count))) else { return nil }
        self = kind
    }
}

/// The answer to a confirmation step: accepted, or refused with a code.
public enum StepVerifyResponse: Equatable, Sendable {
    case success(transaction: SessionTransaction?)
    case failed(code: String, message: String?, attemptsRemaining: Int?)

    public init(json: JSONValue) {
        if json["status"]?.string == "failed" || json["error"]?.object != nil {
            self = .failed(code: json["error"]?["code"]?.nonEmptyString ?? "request_failed",
                           message: json["error"]?["message"]?.nonEmptyString,
                           attemptsRemaining: json["attempts_remaining"]?.int.map { max($0, 0) })
        } else {
            self = .success(transaction: SessionTransaction.optional(json["transaction"]))
        }
    }
}

/// A confirmation step's answer and what follows it (`WajubSession.verifyStep(_:id:fields:)`).
public struct StepAnswer: Equatable, Sendable {
    /// Accepted, or refused with a code.
    public var response: StepVerifyResponse
    /// When accepted, what the payment does next: `.requiresAction` for another step or a page,
    /// `.complete` once paid, `.processing` while it runs, `.failed` when it failed. `nil` when refused.
    public var next: ProcessOutcome?

    public init(response: StepVerifyResponse, next: ProcessOutcome?) {
        self.response = response
        self.next = next
    }
}

/// What `WajubSession.cancel()` returns.
public struct CancelResponse: Equatable, Sendable {
    /// The merchant's page for a cancelled payment, when there is one.
    public var redirectURL: String?

    public init(json: JSONValue) {
        redirectURL = json["redirect_url"]?.nonEmptyString
    }
}

/// What a request for a new code returns.
public struct ResendResponse: Equatable, Sendable {
    /// Sandbox 3-D Secure: where the code was sent.
    public var maskedEmail: String?

    public init(json: JSONValue) {
        maskedEmail = json["masked_email"]?.nonEmptyString
    }
}

/// Wajub's error answer, from which `WajubError` is built.
public struct APIErrorBody: Equatable, Sendable {
    public var code: Int?
    public var status: String?
    public var message: String?
    public var errorCode: String?
    /// Field errors: field → messages.
    public var errors: [String: [String]]
    public var transaction: SessionTransaction?
    public var blockReference: String?
    public var retryAfter: Int?
    /// The detail of a refused confirmation step.
    public var nestedError: NestedError?
    public var attemptsRemaining: Int?

    public init(json: JSONValue) {
        code = json["code"]?.int
        status = json["status"]?.nonEmptyString
        message = json["message"]?.nonEmptyString
        errorCode = json["error_code"]?.nonEmptyString
        var errors: [String: [String]] = [:]
        for (key, value) in json["errors"]?.object ?? [:] {
            if let list = value.array {
                errors[key] = list.compactMap { $0.string }
            } else if let text = value.string {
                errors[key] = [text]
            }
        }
        self.errors = errors
        transaction = SessionTransaction.optional(json["transaction"])
        blockReference = json["block_reference"]?.nonEmptyString
        retryAfter = json["retry_after"]?.int
        if let nested = json["error"], nested.object != nil {
            nestedError = NestedError(code: nested["code"]?.nonEmptyString, message: nested["message"]?.nonEmptyString,
                                      retryable: nested["retryable"]?.bool)
        }
        attemptsRemaining = json["attempts_remaining"]?.int.map { max($0, 0) }
    }

    /// A refused step's code, message, and whether it can be tried again.
    public struct NestedError: Equatable, Sendable {
        public var code: String?
        public var message: String?
        public var retryable: Bool?
    }
}
