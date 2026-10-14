import Foundation

/// The family of a `WajubError` (Wajub.js's `type`).
public enum WajubErrorType: String, Sendable, CaseIterable {
    case apiError = "api_error"
    case authenticationError = "authentication_error"
    case invalidRequestError = "invalid_request_error"
    case paymentError = "payment_error"
    case rateLimitError = "rate_limit_error"
}

/// Every failure the SDK reports: Wajub.js's `WajubError` plus the mobile fields.
///
/// `message` is for the payer, in the sheet's language; `apiMessage` keeps the API's own
/// (English) text for your logs.
public struct WajubError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Always `"WajubError"`.
    public var name: String { "WajubError" }
    public var type: WajubErrorType
    /// A code of the catalogue (`WajubError.Code`), or an API code passed through.
    public var code: String
    public var message: String
    /// On a `402`: the API's `error_code`.
    public var declineCode: String?
    public var retryable: Bool
    /// The field at fault, e.g. `data.phone`.
    public var param: String?
    public var httpStatus: Int?
    /// The response's `X-Request-Id`.
    public var correlationId: String?
    /// On a `429`.
    public var retryAfterSeconds: Int?
    /// The API's `errors`, first message per key.
    public var details: [String: String]?
    /// On a `403 shield_blocked`.
    public var blockReference: String?
    public var apiMessage: String?

    public init(type: WajubErrorType, code: String, message: String, declineCode: String? = nil, retryable: Bool,
                param: String? = nil, httpStatus: Int? = nil, correlationId: String? = nil, retryAfterSeconds: Int? = nil,
                details: [String: String]? = nil, blockReference: String? = nil, apiMessage: String? = nil) {
        self.type = type
        self.code = code
        self.message = message
        self.declineCode = declineCode
        self.retryable = retryable
        self.param = param
        self.httpStatus = httpStatus
        self.correlationId = correlationId
        self.retryAfterSeconds = retryAfterSeconds
        self.details = details
        self.blockReference = blockReference
        self.apiMessage = apiMessage
    }

    public var description: String { "WajubError(\(type.rawValue), \(code)): \(message)" }

    /// The shape of errors.md §1, with its snake_case keys.
    public func toJSON() -> JSONValue {
        func optional(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
        func optional(_ value: Int?) -> JSONValue { value.map { .number(Double($0)) } ?? .null }
        return .object([
            "name": .string(name),
            "type": .string(type.rawValue),
            "code": .string(code),
            "message": .string(message),
            "decline_code": optional(declineCode),
            "retryable": .bool(retryable),
            "param": optional(param),
            "http_status": optional(httpStatus),
            "correlation_id": optional(correlationId),
            "retry_after_seconds": optional(retryAfterSeconds),
            "details": details.map { .object($0.mapValues(JSONValue.string)) } ?? .null,
            "block_reference": optional(blockReference),
            "api_message": optional(apiMessage),
        ])
    }
}

extension WajubError: LocalizedError {
    public var errorDescription: String? { message }
}

extension WajubError {
    /// The codes of the error catalogue (errors.md §3). Unknown API codes are passed through.
    public enum Code {
        public static let sessionNotFound = "session_not_found"
        public static let sessionTerminalExpired = "session_terminal_expired"
        public static let sessionTerminalCancelled = "session_terminal_cancelled"
        public static let sessionTerminalFailed = "session_terminal_failed"
        public static let loadError = "load_error"
        public static let readyTimeout = "ready_timeout"
        public static let noPaymentMethod = "no_payment_method"
        public static let networkError = "network_error"
        public static let timeout = "timeout"
        public static let serverError = "server_error"
        public static let rateLimited = "rate_limited"
        public static let requestFailed = "request_failed"
        public static let phoneRequired = "phone_required"
        public static let invalidPhone = "invalid_phone"
        public static let operatorMismatch = "operator_mismatch"
        public static let operatorRequired = "operator_required"
        public static let operatorUnavailable = "operator_unavailable"
        public static let fieldRequired = "field_required"
        public static let invalidEmail = "invalid_email"
        public static let validationError = "validation_error"
        public static let paymentDeclined = "payment_declined"
        public static let insufficientFunds = "insufficient_funds"
        public static let merchantNotVerified = "merchant_not_verified"
        public static let limitExceeded = "limit_exceeded"
        public static let shieldBlocked = "shield_blocked"
        public static let merchantRestricted = "merchant_restricted"
        public static let paymentMethodRestricted = "payment_method_restricted"
        public static let countryRestricted = "country_restricted"
        public static let currencyRestricted = "currency_restricted"
        public static let channelNotAccepted = "channel_not_accepted"
        public static let paymentFailed = "payment_failed"
        public static let paymentAttemptEnded = "payment_attempt_ended"
        public static let paymentCancelled = "payment_cancelled"
        public static let sessionExpired = "session_expired"
        public static let notProcessable = "not_processable"
        public static let orderNotValidated = "order_not_validated"
        public static let rawCardDataNotAccepted = "raw_card_data_not_accepted"
        public static let securityCheckFailed = "security_check_failed"
        public static let unsupportedAction = "unsupported_action"
        public static let redirectUnavailable = "redirect_unavailable"
        public static let invalidOTP = "invalid_otp"
        public static let otpExpired = "otp_expired"
        public static let invalidPIN = "invalid_pin"
        public static let pinExpired = "pin_expired"
        public static let phoneExpired = "phone_expired"
        public static let invalidBirthday = "invalid_birthday"
        public static let birthdayExpired = "birthday_expired"
        public static let invalidAddress = "invalid_address"
        public static let addressExpired = "address_expired"
        public static let maxAttemptsExceeded = "max_attempts_exceeded"
        public static let invalidCode = "invalid_code"
        public static let threeDSFailed = "3ds_failed"
        public static let threeDSRejected = "3ds_rejected"
        public static let threeDSCancelled = "3ds_cancelled"
        public static let threeDSTimeout = "3ds_timeout"
        public static let clientSessionUnavailable = "client_session_unavailable"
        public static let clientSessionExpired = "client_session_expired"
        public static let sheetAlreadyPresented = "sheet_already_presented"
        /// Not an error for the payer: the SDK waits for the charge in flight.
        public static let paymentInProgress = "payment_in_progress"
    }
}
