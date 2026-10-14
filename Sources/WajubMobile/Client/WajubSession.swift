import Foundation

/// The low-level client of `https://api.wajub.com/pay/*`, for hosts that draw their own UI.
///
/// It sends the contract's headers, timeouts, retries and `Idempotency-Key`, and returns the
/// API's shapes. `WajubCheckout.present(_:)` (WajubMobileUI) drives it for you.
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

    /// `GET /pay/session`.
    public func session() async throws -> SessionResponse {
        let answer = try await call(.session, phase: .loading)
        guard let body = answer.body, let session = try? SessionResponse(json: body) else { throw unreadable(answer) }
        return session
    }

    /// `GET /pay/sdk-config`.
    public func sdkConfig() async throws -> SdkConfigResponse {
        let answer = try await call(.sdkConfig, phase: .loading)
        return SdkConfigResponse(json: answer.body ?? .null)
    }

    /// `GET /pay/status`. Its `reference` is Wajub's payment id, not your reference.
    public func status() async throws -> StatusResponse {
        let answer = try await call(.status, phase: .payment)
        return StatusResponse(json: answer.body ?? .null)
    }

    /// `POST /pay/process`, with `data._client` added. Retries resend the same body under the same key.
    ///
    /// A request whose outcome is unknown after its retries (network error, timeout, 5xx) comes back
    /// as `.processing(kind: .pending)`: watch the status, never show it as a failure.
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

    /// `POST /pay/client-session`: opens a provider-hosted card session (live only).
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

    /// `POST /pay/client-session/complete`, once the payer is back from the provider's page.
    public func completeClientSession(id: String) async -> ProcessOutcome {
        do {
            let answer = try await send(.clientSessionComplete, body: ["client_session_id": .string(id)])
            return ProcessOutcome(PaymentAnswer.classify(answer, mobileMoney: false, allowsClientSession: false), language: language)
        } catch {
            return .processing(transaction: nil, instruction: nil, kind: .pending)
        }
    }

    /// `POST /pay/cancel`: the payment is cancelled for good.
    public func cancel() async throws -> CancelResponse {
        let answer = try await call(.cancel, phase: .payment)
        return CancelResponse(json: answer.body ?? .null)
    }

    /// `POST /pay/{kind}/verify` with the step's id and its fields (`code`, `pin`, `phone`, `birthday`, or the address fields).
    public func verify(_ kind: ConfirmStepKind, id: String, fields: [String: String]) async throws -> StepVerifyResponse {
        let answer = try await call(.verify(kind), phase: .payment, body: WajubSession.verifyBody(kind, id: id, fields: fields))
        return StepVerifyResponse(json: answer.body ?? .null)
    }

    /// `POST /pay/{kind}/resend` (a no-op for the providers of today).
    public func resend(_ kind: ConfirmStepKind, id: String) async throws {
        _ = try await call(.resend(kind), phase: .payment, body: [kind.idKey: .string(id)])
    }

    /// `POST /pay/3ds/send` (sandbox): a new email code.
    public func send3DSCode(threeDSId: String) async throws -> ResendResponse {
        let answer = try await call(.threeDSSend, phase: .payment, body: ["three_ds_id": .string(threeDSId)])
        return ResendResponse(json: answer.body ?? .null)
    }

    /// `POST /pay/3ds/verify` (sandbox). A wrong code throws `invalid_code` (also when the API answers a 5xx):
    /// keep the code screen. Other codes (`3ds_failed`, `3ds_timeout`, …) end the attempt.
    public func verify3DSCode(threeDSId: String, code: String) async throws {
        let answer = try await send(.threeDSVerify, body: ["three_ds_id": .string(threeDSId), "code": .string(code)])
        if answer.isSuccess { return }
        throw WajubSession.threeDSError(answer, language)
    }

    /// `POST /pay/broadcasting/auth`: the Pusher signature for a private channel.
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
    /// Throws `TransportError` (no answer after the retries) or `CancellationError`.
    func send(_ endpoint: Endpoint, body: JSONValue? = nil, idempotencyKey: String? = nil,
              policy: RetryPolicy? = nil) async throws -> APIAnswer {
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
                let answer = APIAnswer(try await transport.send(request))
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
