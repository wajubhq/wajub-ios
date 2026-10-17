import Foundation

/// The sheet's state; its raw value is the state's name (`INITIATED`, `3DS_REQUIRED`…).
public enum CheckoutState: String, Sendable, CaseIterable {
    case initiated = "INITIATED"
    case collectingDetails = "COLLECTING_DETAILS"
    case processing = "PROCESSING"
    case otpRequired = "OTP_REQUIRED"
    case pinRequired = "PIN_REQUIRED"
    case phoneRequired = "PHONE_REQUIRED"
    case birthdayRequired = "BIRTHDAY_REQUIRED"
    case addressRequired = "ADDRESS_REQUIRED"
    case threeDSRequired = "3DS_REQUIRED"
    case ussdRequired = "USSD_REQUIRED"
    case approvalRequired = "APPROVAL_REQUIRED"
    case verifying = "VERIFYING"
    case pending = "PENDING"
    case success = "SUCCESS"
    case failed = "FAILED"
    case expired = "EXPIRED"
    case cancelled = "CANCELLED"
}

/// A successful payment. Confirm it on your server (`GET /payments/{id}` or the
/// `payment.succeeded` webhook) before you deliver.
public struct PaymentSuccess: Equatable, Sendable {
    /// Wajub's payment id, what `GET /payments/{id}` takes.
    public var id: String
    /// The merchant's reference.
    public var reference: String?
    /// What the payer paid, fee included, in major units.
    public var amount: Double
    public var currency: String
    /// `mobile_money`, `card`, `wallet`, or `unknown` when the session was already paid at load.
    public var method: String
    /// Always `"success"`.
    public var status: String { "success" }
    /// When the payment succeeded, ISO 8601.
    public var timestamp: String
    public var receiptURL: String?

    public init(id: String, reference: String?, amount: Double, currency: String, method: String, timestamp: String, receiptURL: String?) {
        self.id = id
        self.reference = reference
        self.amount = amount
        self.currency = currency
        self.method = method
        self.timestamp = timestamp
        self.receiptURL = receiptURL
    }

    init(transaction: SessionTransaction, method: String, now: Date) {
        let formatter = ISO8601DateFormatter()
        self.init(id: transaction.id, reference: transaction.reference, amount: transaction.amountTotal,
                  currency: transaction.currency, method: method,
                  timestamp: transaction.terminalAt ?? transaction.updatedAt ?? formatter.string(from: now),
                  receiptURL: transaction.receiptURL)
    }
}

/// Why the sheet closed as `cancelled`.
public enum CancelReason: String, Sendable {
    /// "Cancel payment".
    case payerCancelled = "payer_cancelled"
    /// A swipe down or the close button before any attempt.
    case dismissed
    /// The presenting screen went away before any attempt.
    case hostGone = "host_gone"
}

/// What `present()` resolves with, exactly once.
public enum CheckoutResult: Equatable, Sendable {
    /// The sheet closed after `SUCCESS`.
    case complete(payment: PaymentSuccess, transaction: SessionTransaction?)
    /// The sheet closed while a payment was under way (money may still move), or it stopped waiting for the outcome.
    case processing(transaction: SessionTransaction?)
    /// The sheet closed on `FAILED`, `EXPIRED`, a load error, or a payment cancelled elsewhere.
    case failed(error: WajubError, transaction: SessionTransaction?)
    /// "Cancel payment", a dismiss before any attempt, or the host going away before any attempt.
    case cancelled(reason: CancelReason, redirectURL: String?)

    /// `complete`, `processing`, `failed` or `cancelled`.
    public var status: String {
        switch self {
        case .complete: return "complete"
        case .processing: return "processing"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }
}

public struct ReadyEvent: Equatable, Sendable {
    public var sessionId: String
    /// `sandbox` or `live`.
    public var environment: String
    public var amount: Double
    public var currency: String
    /// The slugs of the channels shown.
    public var methods: [String]
}

public struct StateChangeEvent: Equatable, Sendable {
    /// While the payer generates their operator's code, `.collectingDetails`: `name` says `PAYER_OTP_REQUIRED`.
    public var state: CheckoutState
    /// `mobile_money`, `card`, `wallet` or `unknown`.
    public var method: String?
    /// The state's name: `state`'s, or `PAYER_OTP_REQUIRED` while the payer generates their operator's code.
    public var name: String = ""
}

public struct PaymentStartedEvent: Equatable, Sendable {
    public var method: String
    public var channel: String
}

/// A provider page the sheet is about to open in the browser.
public struct RedirectEvent: Equatable, Sendable {
    public var url: String
    /// Always `"GET"`.
    public var method: String { "GET" }
}

public struct CancelEvent: Equatable, Sendable {
    public var reason: CancelReason
    public var redirectURL: String?
}

/// The checkout's callbacks, all optional, all called on the main thread in this order:
/// `onReady` → `onStateChange`… → (`onPaymentStarted`, `onRedirect`) → `onSuccess`/`onError`/`onCancel`
/// → `onComplete` exactly once. A callback that throws is caught and logged; the sheet carries on.
public struct CheckoutCallbacks {
    public var onReady: (@MainActor (ReadyEvent) throws -> Void)?
    public var onStateChange: (@MainActor (StateChangeEvent) throws -> Void)?
    public var onLoadError: (@MainActor (WajubError) throws -> Void)?
    public var onPaymentStarted: (@MainActor (PaymentStartedEvent) throws -> Void)?
    public var onRedirect: (@MainActor (RedirectEvent) throws -> Void)?
    public var onSuccess: (@MainActor (PaymentSuccess) throws -> Void)?
    public var onError: (@MainActor (WajubError) throws -> Void)?
    public var onCancel: (@MainActor (CancelEvent) throws -> Void)?
    public var onComplete: (@MainActor (CheckoutResult) throws -> Void)?

    public init(onReady: (@MainActor (ReadyEvent) throws -> Void)? = nil,
                onStateChange: (@MainActor (StateChangeEvent) throws -> Void)? = nil,
                onLoadError: (@MainActor (WajubError) throws -> Void)? = nil,
                onPaymentStarted: (@MainActor (PaymentStartedEvent) throws -> Void)? = nil,
                onRedirect: (@MainActor (RedirectEvent) throws -> Void)? = nil,
                onSuccess: (@MainActor (PaymentSuccess) throws -> Void)? = nil,
                onError: (@MainActor (WajubError) throws -> Void)? = nil,
                onCancel: (@MainActor (CancelEvent) throws -> Void)? = nil,
                onComplete: (@MainActor (CheckoutResult) throws -> Void)? = nil) {
        self.onReady = onReady
        self.onStateChange = onStateChange
        self.onLoadError = onLoadError
        self.onPaymentStarted = onPaymentStarted
        self.onRedirect = onRedirect
        self.onSuccess = onSuccess
        self.onError = onError
        self.onCancel = onCancel
        self.onComplete = onComplete
    }
}

/// Deprecated: the payment's live updates need no setting, and this option will be removed.
@available(*, deprecated, message: "The payment's live updates need no setting; this option will be removed.")
public struct RealtimeOptions: Equatable, Sendable {
    public var enabled: Bool
    public var host: String?
    public var port: Int?
    public var tls: Bool?

    public init(enabled: Bool = true, host: String? = nil, port: Int? = nil, tls: Bool? = nil) {
        self.enabled = enabled
        self.host = host
        self.port = port
        self.tls = tls
    }
}

/// Where the live updates connect, when the deprecated `PresentOptions.realtime` says so.
struct RealtimeOverride: Equatable, Sendable {
    var enabled = true
    var host: String?
    var port: Int?
    var tls: Bool?
}

/// What `present()` takes.
public struct PresentOptions {
    /// The payment's `authorization_token`, from your server.
    public var sessionToken: String
    /// `fr` or `en`; else the session's locale, else the device's.
    public var locale: String?
    public var appearance: Appearance?
    public var loader: LoaderStyle
    /// Milliseconds before an unready sheet reports `ready_timeout`; `0` disables it.
    public var readyTimeout: Int
    /// An `https` universal link that brings the payer back to your app from a provider's page.
    public var returnURL: String?
    public var mobileMoney: MobileMoneyOptions
    /// Deprecated: the payment's live updates need no setting, and this option will be removed.
    @available(*, deprecated, message: "The payment's live updates need no setting; this option will be removed.")
    public var realtime: RealtimeOptions? {
        get { realtimeOverride.map { RealtimeOptions(enabled: $0.enabled, host: $0.host, port: $0.port, tls: $0.tls) } }
        set { realtimeOverride = newValue.map { RealtimeOverride(enabled: $0.enabled, host: $0.host, port: $0.port, tls: $0.tls) } }
    }
    var realtimeOverride: RealtimeOverride?
    /// A dismiss before any attempt cancels the payment. Default `true`.
    public var cancelOnDismiss: Bool
    /// Milliseconds before the success screen closes itself; `0` keeps it. Default 3000.
    public var autoCloseSuccess: Int
    public var callbacks: CheckoutCallbacks
    /// Collects cards with Stripe's SDK. Without one, Stripe card payments are not offered.
    public var cardCollector: CardCollector?

    public init(sessionToken: String, locale: String? = nil, appearance: Appearance? = nil, loader: LoaderStyle = .skeleton,
                readyTimeout: Int = 15_000, returnURL: String? = nil, mobileMoney: MobileMoneyOptions = MobileMoneyOptions(),
                cancelOnDismiss: Bool = true, autoCloseSuccess: Int = 3_000,
                callbacks: CheckoutCallbacks = CheckoutCallbacks(), cardCollector: CardCollector? = nil) {
        self.sessionToken = sessionToken
        self.locale = locale
        self.appearance = appearance
        self.loader = loader
        self.readyTimeout = readyTimeout
        self.returnURL = returnURL
        self.mobileMoney = mobileMoney
        self.cancelOnDismiss = cancelOnDismiss
        self.autoCloseSuccess = autoCloseSuccess
        self.callbacks = callbacks
        self.cardCollector = cardCollector
    }

    /// Deprecated: the same without `realtime`, which needs no setting and will be removed.
    @available(*, deprecated, message: "The payment's live updates need no setting; drop `realtime:`, which will be removed.")
    public init(sessionToken: String, locale: String? = nil, appearance: Appearance? = nil, loader: LoaderStyle = .skeleton,
                readyTimeout: Int = 15_000, returnURL: String? = nil, mobileMoney: MobileMoneyOptions = MobileMoneyOptions(),
                realtime: RealtimeOptions? = nil, cancelOnDismiss: Bool = true, autoCloseSuccess: Int = 3_000,
                callbacks: CheckoutCallbacks = CheckoutCallbacks(), cardCollector: CardCollector? = nil) {
        self.init(sessionToken: sessionToken, locale: locale, appearance: appearance, loader: loader, readyTimeout: readyTimeout,
                  returnURL: returnURL, mobileMoney: mobileMoney, cancelOnDismiss: cancelOnDismiss,
                  autoCloseSuccess: autoCloseSuccess, callbacks: callbacks, cardCollector: cardCollector)
        self.realtime = realtime
    }
}

/// What a card collector receives.
public struct CardCollectionRequest: Equatable, Sendable {
    /// The Stripe publishable key to use (`pk_…`).
    public var publishableKey: String
    public var amount: Double
    public var currency: String
    public var customerEmail: String?
    public var customerName: String?
    /// The sheet's language.
    public var language: WajubLanguage
}

/// Collects a card with a provider SDK the host ships (Stripe), so WajubMobile does not depend on it.
///
/// Implement it with Stripe's card field and `STPAPIClient.createPaymentMethod` and return the
/// `pm_…` id; the sheet sends it to Wajub. Return `nil` when the payer backs out.
public protocol CardCollector: AnyObject {
    @MainActor func collectPaymentMethod(_ request: CardCollectionRequest) async throws -> String?
}
