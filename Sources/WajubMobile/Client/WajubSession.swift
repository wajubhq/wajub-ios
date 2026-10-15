import Foundation

/// The lower-level client of one payment, for apps that draw their own UI.
///
/// `WajubCheckout.present(_:from:)` and `CheckoutController` use it for you. `status()` reads the
/// payment's status, for example at the next launch after the app was closed during a payment.
public final class WajubSession: @unchecked Sendable {
    let token: String
    let baseURL: URL
    let transport: HTTPTransport
    let clock: WajubClock
    let device: DeviceEnvironment
    let random: @Sendable () -> Double
    /// The language of the messages of the errors this client throws.
    public let language: WajubLanguage

    /// - Parameters:
    ///   - sessionToken: the payment's `authorization_token`, from your server.
    ///   - language: the language of error messages; the device's by default.
    public convenience init(sessionToken: String, language: WajubLanguage? = nil) {
        let device = DeviceEnvironment.current
        self.init(sessionToken: sessionToken, baseURL: WajubSDK.apiURL, transport: URLSessionTransport(), clock: SystemClock(),
                  device: device, random: { Double.random(in: 0..<1) },
                  language: language ?? WajubLanguage(tag: device.language))
    }

    init(sessionToken: String, baseURL: URL, transport: HTTPTransport, clock: WajubClock, device: DeviceEnvironment,
         random: @escaping @Sendable () -> Double, language: WajubLanguage) {
        self.token = sessionToken
        self.baseURL = baseURL
        self.transport = transport
        self.clock = clock
        self.device = device
        self.random = random
        self.language = language
    }

    // MARK: Typed calls

    /// The payment: amount, currency, payment methods, branding and language.
    public func session() async throws -> SessionResponse {
        let answer = try await call(.session, phase: .loading)
        guard let body = answer.body, let session = try? SessionResponse(json: body) else { throw unreadable(answer) }
        return session
    }

    /// How each payment method of the payment is collected.
    public func sdkConfig() async throws -> SdkConfigResponse {
        let answer = try await call(.sdkConfig, phase: .loading)
        return SdkConfigResponse(json: answer.body ?? .null)
    }

    /// The payment's status. Its `reference` is Wajub's payment id, not your reference.
    public func status() async throws -> StatusResponse {
        let answer = try await call(.status, phase: .payment)
        return StatusResponse(json: answer.body ?? .null)
    }

    /// Pays with a channel and the fields it needs.
    ///
    /// An outcome that is not known yet comes back as `.processing(kind: .pending)`: read the status,
    /// never show it as a failure.
    public func process(channel: String, data: [String: JSONValue] = [:],
                        idempotencyKey: String = UUID().uuidString.lowercased()) async -> ProcessOutcome {
        var data = data
        data["_client"] = await device.clientSignals()
        let body: JSONValue = .object(["channel": .string(channel), "data": .object(data)])
        do {
            let answer = try await send(.process, body: body, idempotencyKey: idempotencyKey)
            return ProcessOutcome(PaymentAnswer.classify(answer, mobileMoney: false, allowsClientSession: false), language: language)
        } catch {
            return .processing(transaction: nil, instruction: nil, kind: .pending)
        }
    }

    /// Opens the card provider's own payment page (live only).
    public func startClientSession(fields: [String: String] = [:], returnURL: String? = nil, restart: Bool = false,
                                   altcha: AltchaSolution? = nil) async -> ProcessOutcome {
        let body = WajubSession.clientSessionBody(fields: fields, returnURL: returnURL, restart: restart, altcha: altcha)
        do {
            let answer = try await send(.clientSession, body: body)
            return ProcessOutcome(PaymentAnswer.classify(answer, mobileMoney: false, allowsClientSession: true), language: language)
        } catch {
            return .failed(error: WajubSession.transportError(error, language), transaction: nil)
        }
    }

    /// Asks for the outcome once the payer is back from the provider's page.
    public func completeClientSession(id: String) async -> ProcessOutcome {
        do {
            let answer = try await send(.clientSessionComplete, body: ["client_session_id": .string(id)])
            return ProcessOutcome(PaymentAnswer.classify(answer, mobileMoney: false, allowsClientSession: false), language: language)
        } catch {
            return .processing(transaction: nil, instruction: nil, kind: .pending)
        }
    }

    /// Cancels the payment for good.
    public func cancel() async throws -> CancelResponse {
        let answer = try await call(.cancel, phase: .payment)
        return CancelResponse(json: answer.body ?? .null)
    }

    /// Answers a confirmation step: its id and fields (`code`, `pin`, `phone`, `birthday`, or the address fields).
    /// `verifyStep(_:id:fields:)` also says what the payment does next.
    public func verify(_ kind: ConfirmStepKind, id: String, fields: [String: String]) async throws -> StepVerifyResponse {
        try await verifyStep(kind, id: id, fields: fields).response
    }

    /// Answers a confirmation step, and says what the payment does next: another step the provider
    /// asks for (a code after a date of birth, its page after a PIN), paid, or still under way.
    public func verifyStep(_ kind: ConfirmStepKind, id: String, fields: [String: String]) async throws -> StepAnswer {
        let answer = try await call(.verify(kind), phase: .payment, body: WajubSession.verifyBody(kind, id: id, fields: fields))
        let response = StepVerifyResponse(json: answer.body ?? .null)
        guard case .success(let transaction) = response else { return StepAnswer(response: response, next: nil) }
        if transaction?.status == .failed, answer.body?["action"]?.nonEmptyString == nil {
            return StepAnswer(response: response,
                              next: .failed(error: .catalogue(WajubError.Code.paymentFailed, language), transaction: transaction))
        }
        let next = ProcessOutcome(PaymentAnswer.classify(answer, mobileMoney: false, allowsClientSession: false), language: language)
        return StepAnswer(response: response, next: next)
    }

    /// Asks for a new code for a confirmation step.
    public func resend(_ kind: ConfirmStepKind, id: String) async throws {
        _ = try await call(.resend(kind), phase: .payment, body: [kind.idKey: .string(id)])
    }

    /// Sandbox 3-D Secure: sends a new code by email.
    public func send3DSCode(threeDSId: String) async throws -> ResendResponse {
        let answer = try await call(.threeDSSend, phase: .payment, body: ["three_ds_id": .string(threeDSId)])
        return ResendResponse(json: answer.body ?? .null)
    }

    /// Sandbox 3-D Secure: checks the code. A wrong code throws `invalid_code`: keep the code screen.
    /// Other codes (`3ds_failed`, `3ds_timeout`, …) end the attempt.
    public func verify3DSCode(threeDSId: String, code: String) async throws {
        let answer = try await send(.threeDSVerify, body: ["three_ds_id": .string(threeDSId), "code": .string(code)])
        if answer.isSuccess { return }
        throw WajubSession.threeDSError(answer, language)
    }

    /// Used by the sheet for the payment's live updates; your app does not need it.
    public func broadcastingAuth(socketId: String, channelName: String) async throws -> String {
        let answer = try await call(.broadcastingAuth, phase: .payment,
                                    body: ["socket_id": .string(socketId), "channel_name": .string(channelName)])
        guard let auth = answer.body?["auth"]?.nonEmptyString else { throw unreadable(answer) }
        return auth
    }

    // MARK: Transport

    /// A call whose non-2xx answers are thrown as `WajubError`.
    func call(_ endpoint: Endpoint, phase: ErrorPhase, body: JSONValue? = nil) async throws -> APIAnswer {
        let answer: APIAnswer
        do {
            answer = try await send(endpoint, body: body)
        } catch {
            throw WajubSession.transportError(error, language)
        }
        guard answer.isSuccess else { throw WajubError.from(answer, phase: phase, language: language) }
        return answer
    }

    /// Sends a call with its retry policy and returns the last HTTP answer, whatever its status.
    /// Throws `TransportError` (no answer after the retries) or `CancellationError`. `onSend` hears
    /// when each try is sent (monotonic seconds).
    func send(_ endpoint: Endpoint, body: JSONValue? = nil, idempotencyKey: String? = nil,
              policy: RetryPolicy? = nil, onSend: (@Sendable (TimeInterval) -> Void)? = nil) async throws -> APIAnswer {
        let policy = policy ?? endpoint.retryPolicy
        // Encoded once: an automatic retry resends exactly the same bytes.
        let bodyData = body?.serialized()
        var retries = 0
        while true {
            try Task.checkCancellation()
            let request = HTTPRequest(method: endpoint.method, url: baseURL.appendingPathComponent(endpoint.path),
                                      headers: headers(hasBody: bodyData != nil, idempotencyKey: idempotencyKey),
                                      body: bodyData, connectTimeout: Timing.connectTimeout, timeout: endpoint.timeout)
            do {
                onSend?(clock.uptime)
                let answer = APIAnswer(try await timedSend(request))
                guard retries < policy.maxRetries, policy.statuses.contains(answer.status) else { return answer }
                if answer.status == 429 {
                    guard policy.waitsRetryAfter,
                          let wait = answer.header("Retry-After").flatMap({ TimeInterval($0.trimmingCharacters(in: .whitespaces)) }),
                          wait <= Timing.maxRetryAfterWait else { return answer }
                    try await clock.sleep(seconds: wait)
                } else {
                    try await clock.sleep(seconds: backoff(retries))
                }
                retries += 1
            } catch let error as TransportError {
                if error == .cancelled { throw CancellationError() }
                guard policy.retriesTransportErrors, retries < policy.maxRetries else { throw error }
                try await clock.sleep(seconds: backoff(retries))
                retries += 1
            }
        }
    }

    /// One HTTP request under the contract's two timeouts (README §2.4), measured on the SDK's clock:
    /// not connected within `connectTimeout` (when the transport can tell), or not answered within
    /// `timeout`, is `TransportError.timeout`.
    func timedSend(_ request: HTTPRequest) async throws -> HTTPResponse {
        let transport = self.transport
        let clock = self.clock
        let connection = ConnectionFlag()
        let watchesConnection = transport.reportsConnection(for: request)
        return try await withThrowingTaskGroup(of: HTTPResponse.self) { group in
            group.addTask {
                try await transport.send(request, connected: { connection.set() })
            }
            group.addTask {
                guard watchesConnection else {
                    try await clock.sleep(seconds: request.timeout)
                    throw TransportError.timeout
                }
                try await clock.sleep(seconds: request.connectTimeout)
                guard connection.isSet else { throw TransportError.timeout }
                try await clock.sleep(seconds: max(request.timeout - request.connectTimeout, 0))
                throw TransportError.timeout
            }
            defer { group.cancelAll() }
            guard let response = try await group.next() else { throw TransportError.timeout }
            return response
        }
    }

    /// `min(1 s × 2^n, 10 s) ± 30 %`.
    func backoff(_ retry: Int) -> TimeInterval {
        let base = min(Timing.retryBaseDelay * pow(2, Double(retry)), Timing.retryMaxDelay)
        return base * (1 + Timing.retryJitter * (2 * random() - 1))
    }

    private func headers(hasBody: Bool, idempotencyKey: String?) -> [String: String] {
        var headers = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "Accept-Language": device.acceptLanguage,
            "X-Request-Id": UUID().uuidString.lowercased(),
            "X-Wajub-Client": device.clientIdentifier,
            "User-Agent": device.userAgent,
        ]
        if hasBody { headers["Content-Type"] = "application/json" }
        if let idempotencyKey { headers["Idempotency-Key"] = idempotencyKey }
        return headers
    }

    private func unreadable(_ answer: APIAnswer) -> WajubError {
        var error = WajubError.catalogue(WajubError.Code.serverError, language, httpStatus: answer.status)
        error.apiMessage = "Unreadable response"
        error.correlationId = answer.header("X-Request-Id")
        return error
    }

    // MARK: Bodies and helpers shared with the checkout

    static func transportError(_ error: Error, _ language: WajubLanguage) -> WajubError {
        if let error = error as? WajubError { return error }
        if case TransportError.timeout = error { return .timedOut(language) }
        return .network(language)
    }

    static func verifyBody(_ kind: ConfirmStepKind, id: String, fields: [String: String]) -> JSONValue {
        var members: [String: JSONValue] = [kind.idKey: .string(id)]
        for (key, value) in fields { members[key] = .string(value) }
        return .object(members)
    }

    static func clientSessionBody(fields: [String: String], returnURL: String?, restart: Bool, altcha: AltchaSolution?) -> JSONValue {
        var builder = JSONObjectBuilder()
        builder.set("channel", "card")
        for (key, value) in fields where !value.isEmpty { builder.set(key, value) }
        builder.set("return_url", returnURL)
        if restart { builder.set("restart", true) }
        builder.set("altcha", altcha?.json)
        return builder.value
    }

    /// `/pay/3ds/verify` refusals: a `422` carries `error {code, retryable}`; any 5xx is today's
    /// answer to a wrong code (an API bug) and reads as `invalid_code`.
    static func threeDSError(_ answer: APIAnswer, _ language: WajubLanguage) -> WajubError {
        if answer.status >= 500 {
            var error = WajubError.catalogue(WajubError.Code.invalidCode, language, httpStatus: answer.status)
            error.correlationId = answer.header("X-Request-Id")
            return error
        }
        return WajubError.from(answer, phase: .payment, language: language)
    }

    /// Whether a `/pay/3ds/verify` refusal keeps the code screen: a 5xx, or `error.retryable: true`.
    static func threeDSKeepsScreen(_ answer: APIAnswer) -> Bool {
        answer.status >= 500 || answer.body.map(APIErrorBody.init(json:))?.nestedError?.retryable == true
    }
}

/// Set once the transport reports the connection.
private final class ConnectionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
