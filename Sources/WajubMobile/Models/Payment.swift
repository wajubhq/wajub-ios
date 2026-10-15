import Foundation

/// One entry of `GET /pay/sdk-config`, keyed by raw slug.
public struct SdkChannelConfig: Equatable, Sendable {
    public var available: Bool
    /// A prediction: the provider that charges is `ClientSession.provider` when there is one.
    public var provider: String?
    /// `form`, `stripe_elements`, `hosted_redirect`, `adyen_custom_card`, `psp_inline`, …
    public var sdk: String?
    public var publishableKey: String?
    public var requiredFields: [String]
    /// Absent means `false`.
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

/// `GET /pay/sdk-config`.
public struct SdkConfigResponse: Equatable, Sendable {
    /// Keyed by the session's slugs: an aggregate (`cm.mobile`) and its members (`cm.mtn`). An older answer had
    /// the members only, and more channels than offered: the session decides what is shown.
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

/// `GET /pay/status` `transaction`, and the data of a realtime `PaymentStatusUpdated` event.
public struct StatusUpdate: Equatable, Sendable {
    /// Wajub's payment id (= `SessionTransaction.id`), not the merchant's reference.
    public var reference: String?
    public var status: TransactionStatus
    /// Only when an attempt was refused and the payment is back at `pending`.
    public var errorCode: String?
    public var payerMessage: String?

    /// An answer without a `status` says nothing: the watch carries on.
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

/// `GET /pay/status`.
public struct StatusResponse: Equatable, Sendable {
    public var transaction: StatusUpdate

    public init(json: JSONValue) {
        transaction = StatusUpdate(json: json["transaction"] ?? .null)
    }
}

/// The realtime event `PaymentStatusUpdated`; its data arrives as a JSON string or an object.
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

/// `client_session` of a `202 action: "client_session"` answer.
public struct ClientSession: Equatable, Sendable {
    /// The processing id (`prc_…`): send it back as `client_session_id`.
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

/// An `action` of a payment answer. Unknown values are kept as they are.
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
}

/// The 2xx body of `/pay/process`, `/pay/client-session` and `/pay/client-session/complete`.
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
    }
}

/// A payer confirmation step (`confirm_otp`, `confirm_pin`, …).
public enum ConfirmStepKind: String, CaseIterable, Sendable {
    case otp, pin, phone, birthday, address

    /// The key of the step's id in the `202` and in the verify body: `otp_id`, `pin_id`, …
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

/// The answer of `POST /pay/{kind}/verify` (always HTTP 200 unless the body fails validation).
public enum StepVerifyResponse: Equatable, Sendable {
    case success(transaction: SessionTransaction?)
    case failed(code: String, message: String?, attemptsRemaining: Int?)

    public init(json: JSONValue) {
        if json["status"]?.string == "failed" || json["error"]?.object != nil {
            self = .failed(code: json["error"]?["code"]?.nonEmptyString ?? "request_failed",
                           message: json["error"]?["message"]?.nonEmptyString,
                           attemptsRemaining: json["attempts_remaining"]?.int)
        } else {
            self = .success(transaction: SessionTransaction.optional(json["transaction"]))
        }
    }
}

/// `POST /pay/cancel` 200.
public struct CancelResponse: Equatable, Sendable {
    /// The merchant callback with `status=cancelled`.
    public var redirectURL: String?

    public init(json: JSONValue) {
        redirectURL = json["redirect_url"]?.nonEmptyString
    }
}

/// `POST /pay/{kind}/resend` and `/pay/3ds/send`.
public struct ResendResponse: Equatable, Sendable {
    /// `/pay/3ds/send` only.
    public var maskedEmail: String?

    public init(json: JSONValue) {
        maskedEmail = json["masked_email"]?.nonEmptyString
    }
}

/// The API's error body: not the `WajubError` shape, which is built from it.
public struct APIErrorBody: Equatable, Sendable {
    public var code: Int?
    public var status: String?
    public var message: String?
    public var errorCode: String?
    /// `errors`: field → messages.
    public var errors: [String: [String]]
    public var transaction: SessionTransaction?
    public var blockReference: String?
    public var retryAfter: Int?
    /// The nested `error` of the 3-D Secure verify refusal and the step failures.
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
        attemptsRemaining = json["attempts_remaining"]?.int
    }

    /// `error: {code, message, retryable}`.
    public struct NestedError: Equatable, Sendable {
        public var code: String?
        public var message: String?
        public var retryable: Bool?
    }
}
