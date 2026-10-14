import Foundation

/// The timing constants of the contract (README §2.4, §2.5, §13; `types.ts`).
enum Timing {
    static let connectTimeout: TimeInterval = 10
    static let requestTimeout: TimeInterval = 30
    /// `/pay/process`, `/pay/client-session(/complete)`, the verify calls: they reach a provider synchronously.
    static let paymentRequestTimeout: TimeInterval = 60

    static let retryBaseDelay: TimeInterval = 1
    static let retryMaxDelay: TimeInterval = 10
    static let retryJitter = 0.3
    /// A `429 Retry-After` longer than this is not waited for.
    static let maxRetryAfterWait: TimeInterval = 10

    static let pollInterval: TimeInterval = 5
    static let pollSlowAfter: TimeInterval = 120
    static let pollSlowFactor = 1.5
    static let pollMaxInterval: TimeInterval = 15
    static let pollWithSocket: TimeInterval = 15
    static let socketConnectGrace: TimeInterval = 10
    static let pollErrorBase: TimeInterval = 5
    static let pollErrorMax: TimeInterval = 60
    static let pollErrorJitter = 0.2
    static let pollOverallCap: TimeInterval = 900
    /// A `POST /pay/process` without an answer whose payment still reads `pending` this long after its
    /// last try most likely never reached the API.
    static let unansweredRequestWait: TimeInterval = 60

    static let readyTimeoutMs = 15_000
    static let resendAfter: TimeInterval = 60
    static let autoCloseSuccessMs = 3_000
}

/// When a call is retried automatically (README §2.5).
struct RetryPolicy: Equatable, Sendable {
    var maxRetries: Int
    var retriesTransportErrors: Bool
    var statuses: Set<Int>
    /// GETs wait a `429`'s `Retry-After` when it is short enough.
    var waitsRetryAfter: Bool

    /// GETs: network error, timeout, 408, 429, 500, 502, 503, 504; three times.
    static let reads = RetryPolicy(maxRetries: 3, retriesTransportErrors: true, statuses: [408, 429, 500, 502, 503, 504], waitsRetryAfter: true)
    /// `/pay/process` and the client-session calls: network error, timeout, 502, 503, 504; twice, same body and key.
    static let payment = RetryPolicy(maxRetries: 2, retriesTransportErrors: true, statuses: [502, 503, 504], waitsRetryAfter: false)
    /// `/pay/cancel`: network error and timeout; twice.
    static let cancel = RetryPolicy(maxRetries: 2, retriesTransportErrors: true, statuses: [], waitsRetryAfter: false)
    /// The verify calls, resends and the broadcasting auth.
    static let noRetry = RetryPolicy(maxRetries: 0, retriesTransportErrors: false, statuses: [], waitsRetryAfter: false)
}

/// The `/pay/*` endpoints the SDK calls.
enum Endpoint: Equatable, Sendable {
    case session
    case sdkConfig
    case status
    case process
    case cancel
    case verify(ConfirmStepKind)
    case resend(ConfirmStepKind)
    case threeDSSend
    case threeDSVerify
    case clientSession
    case clientSessionComplete
    case broadcastingAuth

    var method: String {
        switch self {
        case .session, .sdkConfig, .status: return "GET"
        default: return "POST"
        }
    }

    var path: String {
        switch self {
        case .session: return "/pay/session"
        case .sdkConfig: return "/pay/sdk-config"
        case .status: return "/pay/status"
        case .process: return "/pay/process"
        case .cancel: return "/pay/cancel"
        case .verify(let kind): return "/pay/\(kind.rawValue)/verify"
        case .resend(let kind): return "/pay/\(kind.rawValue)/resend"
        case .threeDSSend: return "/pay/3ds/send"
        case .threeDSVerify: return "/pay/3ds/verify"
        case .clientSession: return "/pay/client-session"
        case .clientSessionComplete: return "/pay/client-session/complete"
        case .broadcastingAuth: return "/pay/broadcasting/auth"
        }
    }

    /// The whole-request timeout: 60 s for the calls that reach a provider, 30 s otherwise.
    var timeout: TimeInterval {
        switch self {
        case .process, .clientSession, .clientSessionComplete, .verify, .threeDSVerify:
            return Timing.paymentRequestTimeout
        default:
            return Timing.requestTimeout
        }
    }

    var retryPolicy: RetryPolicy {
        switch self {
        case .session, .sdkConfig, .status: return .reads
        case .process, .clientSession, .clientSessionComplete: return .payment
        case .cancel: return .cancel
        case .verify, .resend, .threeDSSend, .threeDSVerify, .broadcastingAuth: return .noRetry
        }
    }
}

/// Time, injectable so tests run on a virtual clock.
protocol WajubClock: Sendable {
    var now: Date { get }
    /// Suspends for `seconds`; throws `CancellationError` when the task is cancelled.
    func sleep(seconds: TimeInterval) async throws
}

struct SystemClock: WajubClock {
    var now: Date { Date() }

    func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else {
            try Task.checkCancellation()
            return
        }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
