import XCTest
@testable import WajubMobile

/// What `present()` resolved with, in order.
@MainActor
final class Resolutions {
    var values: [String] = []
    var errors: [String] = []
}

/// The cross-SDK scenarios: settling, cancel rules, unanswered payments, watching, loading, client
/// sessions and Altcha, each against the real controller and the fake HTTP layer.
final class ScenarioTests: XCTestCase {
    // MARK: helpers

    @MainActor private func present(_ controller: CheckoutController, _ presenter: CheckoutPresenting, into box: Resolutions) {
        Task { @MainActor in
            do {
                let result = try await Checkout.present(controller, presenter: presenter)
                box.values.append(result.status)
            } catch let error as WajubError {
                box.errors.append(error.code)
            } catch {
                box.errors.append("\(error)")
            }
        }
    }

    /// Wakes every sleeper for a while (retries, backoffs, timers).
    @MainActor private func drain(_ harness: Harness, steps: Int = 40) async {
        for _ in 0..<steps {
            await settle()
            guard let wake = harness.clock.nextWake else { continue }
            await harness.clock.advance(by: max(wake, 0))
        }
        await settle()
    }

    private static let statusPending: JSONValue = ["transaction": ["reference": "trx", "status": "pending"]]
    private static func status(_ s: String) -> JSONValue { ["transaction": ["reference": "trx", "status": .string(s)]] }

    // MARK: 1. Settling never hangs

    /// ST-04 settles when the host goes away
    /// While "Cancel payment" runs, whatever the cancel answers.
    @MainActor func test_ST_04_settlesWhenTheHostGoesAwayWhileACancelRuns() async {
        let cases: [(String, FakeTransport.Reply, FakeTransport.Reply?)] = [
            ("200", .fixture("cancel-200"), nil),
            ("400+expired", .fixture("cancel-400-not-cancellable"), .json(200, Self.status("expired"))),
            ("400+failed", .fixture("cancel-400-not-cancellable"), .json(200, Self.status("failed"))),
            ("400+pending", .fixture("cancel-400-not-cancellable"), .json(200, Self.statusPending)),
            ("400+succeeded", .fixture("cancel-400-not-cancellable"), .fixture("status-succeeded")),
            ("network", .failure(.network("offline")), nil),
        ]
        for (label, cancel, status) in cases {
            let harness = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
            let gate = Gate()
            harness.transport.on("POST", "/pay/cancel", .gated(gate, cancel))
            if let status { harness.transport.on("GET", "/pay/status", status) }
            let controller = harness.makeController()
            let box = Resolutions()
            present(controller, FakePresenter(), into: box)
            await waitUntil("ready \(label)") { controller.state != nil }
            controller.cancelPayment()
            await waitUntil("cancel sent \(label)") { harness.transport.requests("POST", "/pay/cancel").count == 1 }
            controller.hostGone()
            await waitUntil("resolved \(label)") { box.values.count == 1 }
            let eventsAtComplete = harness.recorder.events
            gate.open()
            await drain(harness)
            XCTAssertEqual(box.values, ["cancelled"], label)
            XCTAssertEqual(harness.recorder.completions.count, 1, label)
            XCTAssertEqual(harness.recorder.events, eventsAtComplete, "\(label): no callback after onComplete")
            XCTAssertEqual(controller.result, .cancelled(reason: .hostGone, redirectURL: nil), label)
        }
    }

    /// ST-04 settles when the host goes away
    /// The presenter's host watch: while "Cancel payment" runs its answer settles; a refused cancel that
    /// leaves the sheet open (a paid payment's success screen) is then settled by the host being gone.
    @MainActor func test_ST_04_watchesTheHostUntilARefusedCancelSettles() async {
        let cases: [(String, FakeTransport.Reply, FakeTransport.Reply?, Int, String)] = [
            ("200", .fixture("cancel-200"), nil, 3000, "cancelled"),
            ("400+expired", .fixture("cancel-400-not-cancellable"), .json(200, Self.status("expired")), 3000, "failed"),
            ("400+failed", .fixture("cancel-400-not-cancellable"), .json(200, Self.status("failed")), 3000, "failed"),
            ("400+pending", .fixture("cancel-400-not-cancellable"), .json(200, Self.statusPending), 3000, "cancelled"),
            ("400+succeeded autoClose 3000", .fixture("cancel-400-not-cancellable"), .fixture("status-succeeded"), 3000, "complete"),
            ("400+succeeded autoClose 0", .fixture("cancel-400-not-cancellable"), .fixture("status-succeeded"), 0, "complete"),
            ("network", .failure(.network("offline")), nil, 3000, "cancelled"),
        ]
        for (label, cancel, status, autoClose, expected) in cases {
            let harness = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
            let gate = Gate()
            harness.transport.on("POST", "/pay/cancel", .gated(gate, cancel))
            if let status { harness.transport.on("GET", "/pay/status", status) }
            let controller = harness.makeController { $0.autoCloseSuccess = autoClose }
            let box = Resolutions()
            present(controller, FakePresenter(), into: box)
            await waitUntil("ready \(label)") { controller.state != nil }
            controller.cancelPayment()
            await waitUntil("cancel sent \(label)") { harness.transport.requests("POST", "/pay/cancel").count == 1 }
            // The sheet left the screen with its host: the presenter's watch runs, and waits for the cancel.
            XCTAssertTrue(controller.isClosing, label)
            controller.watchHost { .gone }
            await harness.advance(by: 2)
            XCTAssertNil(controller.result, "\(label): the cancel's answer settles first")
            gate.open()
            await drain(harness)
            XCTAssertEqual(box.values, [expected], "\(label): present() must resolve (screen=\(controller.screen))")
            XCTAssertEqual(harness.recorder.completions.count, 1, label)
            XCTAssertTrue(harness.recorder.cancels.allSatisfy { $0.reason == .payerCancelled }, label)
        }

        // The sheet shown again ends the watch; covered (by Safari) is not gone.
        let shown = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        let controller = await shown.start()
        var presence: SheetPresence = .covered
        controller.watchHost { presence }
        await drain(shown, steps: 10)
        XCTAssertNil(controller.result, "covered is not gone")
        presence = .shown
        await drain(shown, steps: 2)
        presence = .gone
        await drain(shown, steps: 10)
        XCTAssertNil(controller.result, "the watch ended when the sheet was shown")
        controller.watchHost { nil }
        await drain(shown, steps: 4)
        XCTAssertEqual(controller.result, .cancelled(reason: .hostGone, redirectURL: nil), "a sheet that no longer exists is gone")
    }

    /// ST-04 settles when the host goes away
    /// During the status re-read after a 400: the attempt is undecided, so `processing`, no cancel.
    @MainActor func test_ST_04_settlesProcessingWhenTheHostGoesAwayDuringAReread() async {
        let harness = await Harness.mobileMoney(answers: "process-400-not-processable")
        let gate = Gate()
        harness.transport.on("GET", "/pay/status", .gated(gate, .json(200, Self.statusPending)))
        let box = Resolutions()
        // The harness's controller is already started: drive it through hostGone directly, and check present() with a fresh one.
        harness.controller.submitMobileMoney()
        await waitUntil("re-reading") { harness.transport.requests("GET", "/pay/status").count == 1 }
        harness.controller.hostGone()
        XCTAssertNotNil(harness.controller.result)
        let events = harness.recorder.events
        gate.open()
        await drain(harness)
        XCTAssertEqual(harness.recorder.completions.count, 1)
        XCTAssertEqual(harness.recorder.events, events, "no callback after onComplete")
        XCTAssertTrue(harness.transport.requests("POST", "/pay/cancel").isEmpty)
        XCTAssertEqual(harness.controller.result?.status, "processing")

        // Through present().
        let second = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        let gate2 = Gate()
        second.transport.answer("process-400-not-processable")
        second.transport.on("GET", "/pay/status", .gated(gate2, .json(200, Self.statusPending)))
        let controller = second.makeController()
        present(controller, FakePresenter(), into: box)
        await waitUntil("ready") { controller.state != nil }
        controller.setPhone("670000000")
        controller.submitMobileMoney()
        await waitUntil("re-reading") { second.transport.requests("GET", "/pay/status").count == 1 }
        controller.hostGone()
        await waitUntil("resolved") { box.values.count == 1 }
        gate2.open()
        await drain(second)
        XCTAssertEqual(box.values, ["processing"])
        XCTAssertEqual(second.recorder.completions.count, 1)
        XCTAssertTrue(second.transport.requests("POST", "/pay/cancel").isEmpty)
    }

    /// ST-04 settles when the host goes away
    /// While loading, during an attempt, and when the host is already gone at `present()`.
    @MainActor func test_ST_04_settlesWhenTheHostGoesAwayWhileLoadingOrPaying() async {
        let loading = Harness()
        let gate = Gate()
        loading.transport.on("GET", "/pay/session", .gated(gate, .fixture("session-cm-aggregate")))
        let controller = loading.makeController()
        let box = Resolutions()
        present(controller, FakePresenter(), into: box)
        await waitUntil("session asked") { loading.transport.requests("GET", "/pay/session").count == 1 }
        controller.hostGone()
        await waitUntil("resolved") { box.values.count == 1 }
        gate.open()
        await drain(loading)
        XCTAssertEqual(box.values, ["cancelled"])
        XCTAssertEqual(loading.recorder.events, ["cancel:host_gone", "complete:cancelled"], "no callback after onComplete")

        let attempt = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        let processGate = Gate()
        attempt.transport.on("POST", "/pay/process", .gated(processGate, .fixture("process-processing-mobile-money-sandbox")))
        attempt.transport.answer("status-processing")
        let paying = attempt.makeController()
        let box2 = Resolutions()
        present(paying, FakePresenter(), into: box2)
        await waitUntil("ready") { paying.state != nil }
        paying.setPhone("670000000")
        paying.submitMobileMoney()
        await waitUntil("sent") { attempt.transport.requests("POST", "/pay/process").count == 1 }
        paying.hostGone()
        await waitUntil("resolved") { box2.values.count == 1 }
        let events = attempt.recorder.events
        processGate.open()
        await drain(attempt)
        XCTAssertEqual(box2.values, ["processing"])
        XCTAssertEqual(attempt.recorder.events, events, "no callback after onComplete")
        XCTAssertTrue(attempt.transport.requests("POST", "/pay/cancel").isEmpty)
        XCTAssertTrue(attempt.transport.requests("GET", "/pay/status").isEmpty, "no watch after settling")

        // Already gone.
        let gone = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        let result = try? await Checkout.present(gone.makeController(), presenter: NoHostPresenter())
        XCTAssertEqual(result, .cancelled(reason: .hostGone, redirectURL: nil))
        XCTAssertFalse(Checkout.isPresenting)
    }

    /// ST-05 rejects a second present
    /// Only while a sheet is open: `present()` called from `onComplete`, or right after the host went
    /// away, waits for the settled sheet to be gone and presents.
    @MainActor func test_ST_05_presentsAgainOnceTheSheetHasSettled() async {
        let next = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        let nextController = next.makeController()
        let nextPresenter = FakePresenter()
        let fromComplete = Resolutions()
        let first = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        let controller = first.makeController { options in
            let original = options.callbacks.onComplete
            options.callbacks.onComplete = { [unowned self] result in
                try original?(result)
                self.present(nextController, nextPresenter, into: fromComplete)
            }
        }
        let box = Resolutions()
        present(controller, FakePresenter(), into: box)
        await waitUntil("ready") { controller.state != nil }
        controller.hostGone()
        await waitUntil("first resolved") { box.values.count == 1 }
        await waitUntil("second settled or presented") { !fromComplete.errors.isEmpty || !fromComplete.values.isEmpty || nextController.state != nil }
        XCTAssertEqual(fromComplete.errors, [], "present() from onComplete is not a second sheet")
        XCTAssertEqual(nextPresenter.presented.count, 1)
        if nextController.state != nil { nextController.hostGone() }
        await waitUntil("second resolved") { fromComplete.errors.count + fromComplete.values.count == 1 }
        XCTAssertEqual(box.values, ["cancelled"])
        XCTAssertEqual(first.recorder.completions.count, 1)

        // Host swap: the old sheet settles host_gone; a present() right after it.
        let old = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        let oldController = old.makeController()
        let oldBox = Resolutions()
        present(oldController, FakePresenter(), into: oldBox)
        await waitUntil("ready") { oldController.state != nil }
        let swapped = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        let swappedController = swapped.makeController()
        let swappedBox = Resolutions()
        oldController.hostGone()
        present(swappedController, FakePresenter(), into: swappedBox)
        await waitUntil("both settled or presented") {
            oldBox.values.count == 1 && (swappedBox.errors.count == 1 || swappedController.state != nil)
        }
        XCTAssertEqual(swappedBox.errors, [])
        if swappedController.state != nil { swappedController.hostGone() }
        await waitUntil("swapped resolved") { swappedBox.errors.count + swappedBox.values.count == 1 }
        XCTAssertEqual(oldBox.values, ["cancelled"])
        XCTAssertFalse(Checkout.isPresenting)

        // A present() while the closing sheet's dismissal is still running waits for it to end.
        let closing = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        let closingController = closing.makeController()
        let holding = FakePresenter()
        holding.holdsDismissal = true
        let closingBox = Resolutions()
        present(closingController, holding, into: closingBox)
        await waitUntil("ready") { closingController.state != nil }
        closingController.hostGone()
        let queued = Harness(session: "session-cm-aggregate", config: "sdk-config-cm-stripe")
        let queuedController = queued.makeController()
        let queuedPresenter = FakePresenter()
        let queuedBox = Resolutions()
        present(queuedController, queuedPresenter, into: queuedBox)
        await settle()
        XCTAssertTrue(queuedPresenter.presented.isEmpty, "waits for the closing sheet")
        XCTAssertEqual(queuedBox.errors, [])
        holding.finishDismissal()
        await waitUntil("queued presented") { queuedPresenter.presented.count == 1 }
        XCTAssertEqual(closingBox.values, ["cancelled"])
        queuedController.hostGone()
        await waitUntil("queued resolved") { queuedBox.values.count == 1 }
        XCTAssertFalse(Checkout.isPresenting)
    }

    // MARK: 2. Cancel rules

    /// CN-04 handles a refused cancel
    /// A dismiss (the X stays enabled while busy) during the status re-read after a 400 cancels nothing.
    @MainActor func test_CN_04_neverCancelsDuringTheRereadAfterA400() async {
        let harness = await Harness.mobileMoney(answers: "process-400-not-processable", "cancel-200")
        let gate = Gate()
        harness.transport.on("GET", "/pay/status", .gated(gate, .fixture("status-processing")))
        harness.controller.submitMobileMoney()
        await waitUntil("re-reading") { harness.transport.requests("GET", "/pay/status").count == 1 }
        XCTAssertTrue(harness.controller.isWorking, "busy during the re-read")
        XCTAssertFalse(harness.controller.canCancelPayment)
        harness.controller.close() // the header's X: enabled unless isCancelling (CheckoutSheetView.swift:58-67)
        await settle()
        gate.open()
        await drain(harness)
        XCTAssertEqual(harness.transport.requests("POST", "/pay/cancel").count, 0,
                       "/pay/cancel sent while the 400's outcome is undecided (status was processing)")
        XCTAssertEqual(harness.controller.result?.status, "processing")
    }

    /// CN-04 handles a refused cancel
    /// "Cancel payment" is offered again after a step failed for good; closing the failure releases the order.
    @MainActor func test_CN_04_offersCancelAgainAfterAStepFailedForGood() async {
        let harness = Harness(session: "session-cm-aggregate", config: "sdk-config-card-kkiapay")
        harness.transport.answer("process-requires-otp", "status-processing", "otp-verify-max-attempts", "cancel-200")
        let controller = await harness.start()
        controller.selectMethod("card")
        controller.submitCard()
        await waitUntil("otp") { controller.state == .otpRequired }
        XCTAssertFalse(controller.canCancelPayment)
        controller.submitStep(["code": "123456"])
        await waitUntil("failed") { controller.state == .failed }
        guard case .failed(let error) = controller.screen else { return XCTFail("not failed") }
        XCTAssertEqual(error.code, WajubError.Code.maxAttemptsExceeded)
        XCTAssertEqual(controller.lastKnownStatus, .pending, "pending again")
        XCTAssertTrue(controller.canCancelPayment, "a step failed for good is a definitive refusal: Cancel payment offered again")
        controller.close()
        await settle()
        XCTAssertEqual(controller.result?.status, "failed")
        XCTAssertEqual(harness.transport.requests("POST", "/pay/cancel").count, 1, "closing the failure releases the order")
    }

    /// CN-03 dismiss after start resolves processing
    /// On the approval, USSD, pending, step, 3-D Secure and verifying screens, and after a 2xx that says nothing.
    @MainActor func test_CN_03_neverCancelsWhileAnAttemptIsInFlight() async {
        let ussd = Fixtures.body("process-processing-mobile-money-live").setting(["transaction", "processing_context", "is_mobile_money"], to: false)
            .setting(["transaction", "processing_context", "is_ussd"], to: true)
        let cases: [(String, FakeTransport.Reply, CheckoutState)] = [
            ("approval", .fixture("process-processing-mobile-money-sandbox"), .approvalRequired),
            ("ussd", .json(202, ussd), .ussdRequired),
            ("pending (redirect)", .fixture("process-redirect-card-hosted"), .pending),
            ("step", .fixture("process-requires-otp"), .otpRequired),
            ("3ds", .fixture("process-requires-3ds-sandbox"), .threeDSRequired),
            ("2xx without anything", .json(202, [:]), .pending),
        ]
        for (label, reply, state) in cases {
            let harness = await Harness.mobileMoney(answers: "status-processing", "cancel-200")
            harness.transport.on("POST", "/pay/process", reply)
            harness.controller.submitMobileMoney()
            await waitUntil(label) { harness.controller.state == state }
            XCTAssertFalse(harness.controller.canCancelPayment, label)
            harness.controller.cancelPayment()
            harness.controller.dismiss()
            await settle()
            XCTAssertEqual(harness.controller.result?.status, "processing", label)
            XCTAssertTrue(harness.transport.requests("POST", "/pay/cancel").isEmpty, label)
        }

        // VERIFYING.
        let verifying = await Harness.mobileMoney(answers: "process-requires-otp", "status-processing", "cancel-200")
        let gate = Gate()
        verifying.transport.on("POST", "/pay/otp/verify", .gated(gate, .fixture("otp-verify-success")))
        verifying.controller.submitMobileMoney()
        await waitUntil("otp") { verifying.controller.state == .otpRequired }
        verifying.controller.submitStep(["code": "123456"])
        await waitUntil("verifying") { verifying.controller.state == .verifying }
        XCTAssertFalse(verifying.controller.canCancelPayment)
        verifying.controller.dismiss()
        XCTAssertEqual(verifying.controller.result?.status, "processing")
        gate.open()
        await settle()
        XCTAssertTrue(verifying.transport.requests("POST", "/pay/cancel").isEmpty)
    }

    /// ST-03 resolves present once
    /// Closing on FAILED resolves `failed` with the error seen (states.md §4); after `unsupported_action`
    /// the payment may still run, so nothing is cancelled.
    @MainActor func test_ST_03_resolvesFailedWhenClosingOnAnUnsupportedAction() async {
        let body = Fixtures.body("process-requires-otp").setting(["action"], to: "confirm_magic")
        let harness = await Harness.mobileMoney(answers: "cancel-200")
        harness.transport.on("POST", "/pay/process", .json(202, body))
        harness.controller.submitMobileMoney()
        await waitUntil("failed") { harness.controller.state == .failed }
        XCTAssertFalse(harness.controller.canCancelPayment)
        harness.controller.close()
        await settle()
        XCTAssertTrue(harness.transport.requests("POST", "/pay/cancel").isEmpty)
        XCTAssertEqual(harness.controller.result?.status, "failed", "states.md §4: closing on FAILED resolves failed with the error seen")
    }

    /// CN-04 handles a refused cancel
    /// Closing on FAILED after a 402, by every control (X/Close → close(), swipe → dismiss()): `failed`,
    /// and the order released; while loading, "Cancel payment" does nothing.
    @MainActor func test_CN_04_releasesTheOrderWhenClosingOnADecline() async {
        for control in ["close", "swipe"] {
            let harness = await Harness.mobileMoney(answers: "process-failed-402", "cancel-200")
            harness.controller.submitMobileMoney()
            await waitUntil("declined") { harness.controller.state == .failed }
            XCTAssertTrue(harness.controller.canCancelPayment, control)
            guard case .failed(let seen) = harness.controller.screen else { return XCTFail(control) }
            if control == "close" { harness.controller.close() } else { harness.controller.dismiss() }
            XCTAssertEqual(harness.controller.result, .failed(error: seen, transaction: harness.controller.transaction), control)
            await waitUntil("released") { harness.transport.requests("POST", "/pay/cancel").count == 1 }
            XCTAssertTrue(harness.recorder.cancels.isEmpty, control)
        }
        // While loading: "Cancel payment" does nothing.
        let loading = Harness()
        loading.transport.on("GET", "/pay/session", .gated(Gate(), .fixture("session-cm-aggregate")))
        let controller = loading.makeController()
        controller.start()
        controller.cancelPayment()
        await settle()
        XCTAssertNil(controller.result)
        XCTAssertTrue(loading.transport.requests("POST", "/pay/cancel").isEmpty)
        controller.hostGone()
    }

    /// CN-04 handles a refused cancel
    /// A dismiss while Altcha is being solved cancels nothing and sends nothing.
    @MainActor func test_CN_04_neverCancelsWhileAltchaIsSolved() async {
        // Unsolvable within maxnumber: the solver runs until cancelled.
        let altcha: JSONValue = ["algorithm": "SHA-256", "challenge": .string(String(repeating: "0", count: 64)), "salt": "s",
                                 "signature": "sig", "maxnumber": 50_000_000]
        let session = Fixtures.body("session-cm-aggregate").setting(["altcha"], to: altcha)
        let harness = Harness(config: "sdk-config-cm-stripe")
        harness.transport.on("GET", "/pay/session", .json(200, session))
        harness.transport.answer("process-processing-mobile-money-sandbox", "cancel-200")
        let controller = await harness.start()
        controller.setPhone("670000000")
        controller.submitMobileMoney()
        await settle()
        XCTAssertTrue(controller.isPaying)
        XCTAssertFalse(controller.canCancelPayment)
        controller.dismiss()
        XCTAssertEqual(controller.result?.status, "processing")
        await settle()
        XCTAssertTrue(harness.processBodies().isEmpty)
        XCTAssertTrue(harness.transport.requests("POST", "/pay/cancel").isEmpty)
    }

    // MARK: 3. Unanswered payment

    /// TR-09 treats an unanswered process as pending
    /// Network error, timeout, 502/503/504 after the retries, 500: PENDING and watching; retries resend body and key.
    @MainActor func test_TR_09_treatsEveryUnansweredProcessAsPending() async {
        let cases: [(String, FakeTransport.Reply, Int)] = [
            ("network", .failure(.network("offline")), 3), ("timeout", .failure(.timeout), 3),
            ("502", .json(502, ["code": 502]), 3), ("503", .json(503, ["code": 503]), 3), ("504", .json(504, ["code": 504]), 3),
            ("500", .fixture("error-500-production"), 1),
        ]
        for (label, reply, tries) in cases {
            let harness = await Harness.mobileMoney(answers: "status-processing")
            harness.transport.on("POST", "/pay/process", reply)
            harness.controller.submitMobileMoney()
            await harness.drive(until: "pending \(label)") { harness.controller.state == .pending }
            let requests = harness.transport.requests("POST", "/pay/process")
            XCTAssertEqual(requests.count, tries, label)
            XCTAssertEqual(Set(requests.map(\.body)).count, 1, "\(label): identical body")
            XCTAssertEqual(Set(requests.compactMap { $0.header("Idempotency-Key") }).count, 1, "\(label): identical key")
            XCTAssertTrue(harness.recorder.errors.isEmpty, label)
            XCTAssertFalse(harness.controller.canCancelPayment, label)
            await harness.advance(by: 5)
            XCTAssertFalse(harness.transport.requests("GET", "/pay/status").isEmpty, "\(label): watching")
            harness.controller.hostGone()
        }
    }

    /// TR-09 treats an unanswered process as pending
    /// After an unanswered request, a `pending` with an `error_code` newer than the one before the attempt
    /// says it reached the API and was refused: FAILED at once (README §14).
    @MainActor func test_TR_09_failsOnARefusalNewerThanAnUnansweredAttempt() async {
        let harness = await Harness.mobileMoney(answers: "status-pending-attempt-refused", "cancel-200")
        harness.transport.on("POST", "/pay/process", .failure(.timeout))
        harness.controller.submitMobileMoney()
        await harness.drive(until: "pending") { harness.controller.state == .pending }
        await harness.advance(by: 5)
        XCTAssertEqual(harness.controller.state, .failed, "a refusal newer than the attempt decides it")
        guard case .failed(let error) = harness.controller.screen else { return XCTFail("not failed") }
        XCTAssertEqual(error.code, "insufficient_funds")
        XCTAssertTrue(harness.controller.canCancelPayment, "refused: pending again, cancellable")
        harness.controller.hostGone()

        // The refusal the payment already carried is not news: the 60 s rule applies.
        let leftover = Harness(config: "sdk-config-cm-stripe")
        leftover.transport.on("GET", "/pay/session", .json(200, Fixtures.body("session-cm-aggregate")
            .setting(["transaction", "error_code"], to: "insufficient_funds")))
        leftover.transport.answer("status-pending-attempt-refused")
        leftover.transport.on("POST", "/pay/process", .failure(.timeout))
        let controller = await leftover.start()
        controller.setPhone("670000000")
        controller.submitMobileMoney()
        await leftover.drive(until: "pending") { controller.state == .pending }
        await leftover.advance(by: 5)
        XCTAssertEqual(controller.state, .pending)
        await leftover.drive(until: "back on the form", maxSteps: 40) { controller.state == .collectingDetails }
        XCTAssertEqual(controller.banner?.code, WajubError.Code.networkError)
        controller.hostGone()
    }

    /// TR-09 treats an unanswered process as pending
    /// The 60 s are counted from the last try (retries included), and the next Pay reuses the key.
    @MainActor func test_TR_09_countsTheSixtySecondsFromTheLastTry() async {
        let harness = await Harness.mobileMoney()
        harness.transport.on("POST", "/pay/process", .failure(.timeout))
        harness.transport.on("GET", "/pay/status", .json(200, Self.statusPending))
        harness.controller.submitMobileMoney()
        await harness.drive(until: "pending") { harness.controller.state == .pending }
        let lastTry = harness.clock.uptime
        let tries = harness.transport.requests("POST", "/pay/process")
        XCTAssertEqual(tries.count, 3)
        await harness.drive(until: "back on form", maxSteps: 40) { harness.controller.state == .collectingDetails }
        let waited = harness.clock.uptime - lastTry
        XCTAssertEqual(harness.recorder.errors.map(\.code), [WajubError.Code.networkError])
        XCTAssertGreaterThanOrEqual(waited, 60)
        XCTAssertLessThan(waited, 66)
        // The next Pay reuses the key.
        harness.transport.answer("process-processing-mobile-money-sandbox")
        harness.controller.submitMobileMoney()
        await waitUntil("approval") { harness.controller.state == .approvalRequired }
        XCTAssertEqual(harness.transport.requests("POST", "/pay/process").last?.header("Idempotency-Key"),
                       tries.first?.header("Idempotency-Key"))
        harness.controller.hostGone()
    }

    // MARK: 4. Watching

    /// WT-02 decides on status
    /// The watch stops on 401, 403, 404 and 410.
    @MainActor func test_WT_02_stopsOnSessionRefusals() async {
        for status in [401, 403, 404, 410] {
            let harness = await Harness.mobileMoney(answers: "process-processing-mobile-money-sandbox")
            harness.transport.on("GET", "/pay/status", .json(status, ["code": .number(Double(status)), "message": "no"]))
            harness.controller.submitMobileMoney()
            await waitUntil("approval") { harness.controller.state == .approvalRequired }
            await harness.advance(by: 5)
            let polls = harness.transport.requests("GET", "/pay/status").count
            XCTAssertEqual(polls, 1, "\(status): not retried by the watch")
            XCTAssertTrue(harness.controller.showsOutcome, "\(status) ends the watch")
            await harness.clock.advance(by: 120)
            await settle()
            XCTAssertEqual(harness.transport.requests("GET", "/pay/status").count, polls, "\(status): stopped")
            harness.controller.hostGone()
        }
    }

    /// WT-01 polls on schedule
    /// The error backoff, then back to 5 s.
    @MainActor func test_WT_01_backsOffOnErrorsThenReturnsToFiveSeconds() async {
        var schedule = PollSchedule(start: 0, random: { 0.5 })
        XCTAssertEqual(schedule.nextDelay(now: 0, socketConnected: false), 5)
        schedule.recordError()
        XCTAssertEqual(schedule.nextDelay(now: 5, socketConnected: false), 10)
        schedule.recordError()
        XCTAssertEqual(schedule.nextDelay(now: 15, socketConnected: false), 20)
        for _ in 0..<5 { schedule.recordError() }
        XCTAssertEqual(schedule.nextDelay(now: 35, socketConnected: false), 60)
        schedule.recordStatus(.processing, now: 95)
        XCTAssertEqual(schedule.nextDelay(now: 95, socketConnected: false), 5)
    }

    // MARK: 5. 400 re-read

    /// PA-09 handles ended sessions during payment
    /// The outcomes of the re-read after a 400: failed, cancelled, expired, paid.
    @MainActor func test_PA_09_decidesOnTheRereadStatus() async {
        let cases: [(String, CheckoutState)] = [("failed", .failed), ("cancelled", .cancelled), ("expired", .expired), ("refunded", .success)]
        for (status, state) in cases {
            let harness = await Harness.mobileMoney(answers: "process-400-not-processable")
            harness.transport.on("GET", "/pay/status", .json(200, Self.status(status)))
            harness.controller.submitMobileMoney()
            await waitUntil(status) { harness.controller.state == state }
            harness.controller.hostGone()
        }
    }

    // MARK: 6. Load

    /// LD-06 restores a pending approval
    /// From the session alone, at once, even when sdk-config hangs: no ready_timeout.
    @MainActor func test_LD_06_restoresAProcessingSessionWithoutSdkConfig() async {
        let harness = Harness(session: "session-processing-mobile-money")
        harness.transport.on("GET", "/pay/sdk-config", .gated(Gate(), .fixture("sdk-config-sandbox")))
        harness.transport.answer("status-processing")
        let controller = harness.makeController()
        controller.start()
        await waitUntil("session answered") { controller.answeredSession != nil }
        await settle()
        XCTAssertEqual(controller.state, .approvalRequired, "restored from the session alone")
        // The ready timer (15 s) fires while sdk-config hangs.
        await harness.clock.advance(by: 15)
        await settle()
        XCTAssertTrue(harness.recorder.loadErrors.isEmpty)
        XCTAssertEqual(controller.state, .approvalRequired)
        XCTAssertFalse(harness.transport.requests("GET", "/pay/status").isEmpty, "watching")
        controller.hostGone()
    }

    /// LD-05 reports ended sessions with Wajub.js codes
    /// Ended and paid sessions do not wait for sdk-config, even when it hangs.
    @MainActor func test_LD_05_reportsEndedSessionsWithoutWaitingForSdkConfig() async {
        for fixture in ["session-terminal-succeeded", "session-terminal-failed", "session-terminal-cancelled", "session-terminal-expired"] {
            let harness = Harness(session: fixture)
            harness.transport.on("GET", "/pay/sdk-config", .gated(Gate(), .fixture("sdk-config-sandbox")))
            let controller = harness.makeController()
            controller.start()
            await waitUntil(fixture) { controller.state != nil }
            controller.hostGone()
        }
    }

    /// LD-01 loads session and sdk-config in parallel
    /// A card-only or wallet-only session whose sdk-config fails: a retryable load_error, never no_payment_method.
    @MainActor func test_LD_01_reportsAFailedSdkConfigAsALoadErrorWhenNothingElseIsOffered() async {
        let cardOnly = Fixtures.body("session-cm-aggregate").setting(["channels"], to: .array([Fixtures.body("session-cm-aggregate")["channels"]!.array![0]]))
        let walletOnly = Fixtures.body("session-ci-xof-wallets").setting(["channels"], to: .array([Fixtures.body("session-ci-xof-wallets")["channels"]!.array![0]]))
        for (label, body) in [("card", cardOnly), ("wallet", walletOnly)] {
            let harness = Harness()
            harness.transport.on("GET", "/pay/session", .json(200, body))
            harness.transport.on("GET", "/pay/sdk-config", .json(500, ["code": 500, "message": "boom"]))
            let controller = harness.makeController { $0.readyTimeout = 0 }
            controller.start()
            await harness.drive(until: "\(label) load error") { if case .loadError = controller.screen { return true }; return false }
            guard case .loadError(let error) = controller.screen else { XCTFail(label); continue }
            XCTAssertEqual(error.code, WajubError.Code.loadError, label)
            XCTAssertTrue(error.retryable, label)
            controller.hostGone()
        }

        // A session without any channel: no_payment_method still.
        let none = Harness()
        none.transport.on("GET", "/pay/session", .json(200, Fixtures.body("session-cm-aggregate").setting(["channels"], to: .array([]))))
        none.transport.on("GET", "/pay/sdk-config", .json(500, ["code": 500, "message": "boom"]))
        let empty = none.makeController { $0.readyTimeout = 0 }
        empty.start()
        await none.drive(until: "no method") { if case .loadError = empty.screen { return true }; return false }
        guard case .loadError(let error) = empty.screen else { return XCTFail("no load error") }
        XCTAssertEqual(error.code, WajubError.Code.noPaymentMethod)
        empty.hostGone()
    }

    // MARK: 7. Client session

    /// CS-02 completes a client session
    /// Two quick returns while /complete runs send one /complete: one outcome, onSuccess once.
    @MainActor func test_CS_02_completesOnceForTwoQuickReturns() async {
        let harness = Harness(session: "session-cm-aggregate", config: "sdk-config-card-paystack")
        harness.transport.answer("client-session-start-202", "status-processing")
        let gate = Gate()
        harness.transport.on("POST", "/pay/client-session/complete", .gated(gate, .fixture("client-session-complete-200")))
        let controller = await harness.start()
        controller.selectMethod("card")
        controller.submitCard()
        await waitUntil("browser") { !harness.browser.opened.isEmpty }
        harness.controller.appWillEnterForeground() // page still in front: no /complete
        await settle()
        XCTAssertTrue(harness.transport.requests("POST", "/pay/client-session/complete").isEmpty)
        harness.browser.close()
        harness.controller.appWillEnterForeground()
        await settle()
        XCTAssertEqual(harness.transport.requests("POST", "/pay/client-session/complete").count, 1, "one in flight at a time")
        gate.open()
        await waitUntil("paid") { controller.state == .success }
        await settle()
        XCTAssertEqual(harness.recorder.successes.count, 1)
        controller.close()
        XCTAssertEqual(harness.recorder.completions.count, 1)

        // Back from the page reopened while /complete was on its way, and no verdict yet: asked once more.
        let again = Harness(session: "session-cm-aggregate", config: "sdk-config-card-paystack")
        again.transport.answer("client-session-start-202", "status-processing")
        let first = Gate()
        again.transport.on("POST", "/pay/client-session/complete", .gated(first, .fixture("client-session-complete-202")))
        let paying = await again.start()
        paying.selectMethod("card")
        paying.submitCard()
        await waitUntil("browser") { !again.browser.opened.isEmpty }
        again.browser.close()
        await waitUntil("completing") { again.transport.requests("POST", "/pay/client-session/complete").count == 1 }
        paying.continuePayment()
        await waitUntil("reopened") { again.browser.opened.count == 2 }
        again.browser.close()
        await settle()
        XCTAssertEqual(again.transport.requests("POST", "/pay/client-session/complete").count, 1, "one in flight at a time")
        first.open()
        await waitUntil("asked again") { again.transport.requests("POST", "/pay/client-session/complete").count == 2 }
        XCTAssertEqual(paying.state, .pending)
        paying.hostGone()
    }

    // MARK: 8. Altcha

    /// AL-01 solves altcha challenges
    /// A refresh that fails: a retryable error and nothing sent; an unsolvable challenge: nothing sent.
    @MainActor func test_AL_01_sendsNothingWithoutAFreshSolution() async {
        func challenge(_ salt: String, _ number: Int) -> JSONValue {
            ["algorithm": "SHA-256", "challenge": .string(Digest.sha256Hex(salt + String(number))), "salt": .string(salt),
             "signature": "sig", "maxnumber": 5000]
        }
        let session = Fixtures.body("session-cm-aggregate").setting(["altcha"], to: challenge("one", 321))
        let harness = Harness(config: "sdk-config-cm-stripe")
        harness.transport.on("GET", "/pay/session", .json(200, session), .json(503, [:]))
        harness.transport.answer("process-failed-402")
        let controller = await harness.start()
        controller.setPhone("670000000")
        controller.submitMobileMoney()
        await waitUntil("declined") { controller.state == .failed }
        XCTAssertEqual(harness.processBodies().count, 1)
        controller.tryAgain()
        controller.submitMobileMoney()
        await harness.drive(until: "not sent") { controller.banner != nil }
        XCTAssertEqual(controller.banner?.code, WajubError.Code.securityCheckFailed)
        XCTAssertTrue(controller.banner?.retryable ?? false)
        XCTAssertEqual(harness.processBodies().count, 1, "nothing sent without a fresh solution")
        XCTAssertEqual(harness.recorder.errors.last?.code, WajubError.Code.securityCheckFailed)
        XCTAssertFalse(controller.isPaying)
        controller.hostGone()

        // Unsolvable challenge: nothing sent.
        let bad: JSONValue = ["algorithm": "SHA-256", "challenge": .string(String(repeating: "0", count: 64)), "salt": "s",
                              "signature": "sig", "maxnumber": 10]
        let unsolvable = Harness(config: "sdk-config-cm-stripe")
        unsolvable.transport.on("GET", "/pay/session", .json(200, Fixtures.body("session-cm-aggregate").setting(["altcha"], to: bad)))
        let form = await unsolvable.start()
        form.setPhone("670000000")
        form.submitMobileMoney()
        await waitUntil("not sent") { form.banner != nil }
        XCTAssertTrue(unsolvable.processBodies().isEmpty)
        form.hostGone()
    }

    /// LD-06 restores a pending approval
    /// sdk-config hanging past readyTimeout: closing resolves `processing`, never `failed`.
    @MainActor func test_LD_06_neverResolvesFailedForAProcessingSession() async {
        let harness = Harness(session: "session-processing-mobile-money")
        harness.transport.on("GET", "/pay/sdk-config", .gated(Gate(), .fixture("sdk-config-sandbox")))
        harness.transport.answer("status-processing")
        let controller = harness.makeController()
        controller.start()
        await waitUntil("session answered") { controller.answeredSession != nil }
        await harness.clock.advance(by: 15)
        await settle()
        controller.close()
        XCTAssertTrue(harness.transport.requests("POST", "/pay/cancel").isEmpty)
        XCTAssertEqual(controller.result?.status, "processing", "a processing payment must never resolve failed")
    }

    /// LD-06 restores a pending approval
    /// sdk-config failing (500 and its retries): restored at once, not after the config's retries.
    @MainActor func test_LD_06_restoresAtOnceWhenSdkConfigFails() async {
        let harness = Harness(session: "session-processing-mobile-money")
        harness.transport.on("GET", "/pay/sdk-config", .json(500, ["code": 500]))
        harness.transport.answer("status-processing")
        let controller = harness.makeController()
        controller.start()
        await waitUntil("session answered") { controller.answeredSession != nil }
        await settle()
        XCTAssertEqual(controller.state, .approvalRequired, "restored right after the session")
        await harness.drive(until: "config given up", maxSteps: 20) { harness.transport.requests("GET", "/pay/sdk-config").count == 4 }
        await settle()
        XCTAssertEqual(controller.state, .approvalRequired)
        XCTAssertTrue(harness.recorder.loadErrors.isEmpty)
        controller.hostGone()
    }

    /// CS-02 completes a client session
    /// /complete answers 202 (no verdict): a refused try read by the watch then decides.
    @MainActor func test_CS_02_appliesARefusalOnceCompleteHasNoVerdict() async {
        let harness = Harness(session: "session-cm-aggregate", config: "sdk-config-card-paystack")
        harness.transport.answer("client-session-start-202", "client-session-complete-202")
        harness.transport.on("GET", "/pay/status", .fixture("status-processing"), .fixture("status-pending-attempt-refused"))
        let controller = await harness.start()
        controller.selectMethod("card")
        controller.submitCard()
        await waitUntil("browser") { !harness.browser.opened.isEmpty }
        harness.browser.close()
        await waitUntil("completed") { harness.transport.requests("POST", "/pay/client-session/complete").count == 1 }
        await harness.drive(until: "refused", maxSteps: 20) { controller.state == .failed }
        guard case .failed(let error) = controller.screen else { return XCTFail("not failed") }
        XCTAssertEqual(error.code, "insufficient_funds", "the provider gave no verdict: the refused try stands")
        controller.hostGone()

        // A refused try read while /complete runs is held, and stands once /complete answers 202.
        let held = Harness(session: "session-cm-aggregate", config: "sdk-config-card-paystack")
        held.transport.answer("client-session-start-202")
        let gate = Gate()
        held.transport.on("POST", "/pay/client-session/complete", .gated(gate, .fixture("client-session-complete-202")))
        held.transport.on("GET", "/pay/status", .fixture("status-pending-attempt-refused"))
        let paying = await held.start()
        paying.selectMethod("card")
        paying.submitCard()
        await waitUntil("browser") { !held.browser.opened.isEmpty }
        held.browser.close()
        await waitUntil("completing") { held.transport.requests("POST", "/pay/client-session/complete").count == 1 }
        await held.advance(by: 5)
        XCTAssertFalse(held.transport.requests("GET", "/pay/status").isEmpty)
        XCTAssertEqual(paying.state, .pending, "/complete decides first")
        gate.open()
        await waitUntil("refused") { paying.state == .failed }
        paying.hostGone()

        // ...but a payment /complete says is paid wins over it.
        let paid = Harness(session: "session-cm-aggregate", config: "sdk-config-card-paystack")
        paid.transport.answer("client-session-start-202")
        let paidGate = Gate()
        paid.transport.on("POST", "/pay/client-session/complete", .gated(paidGate, .fixture("client-session-complete-200")))
        paid.transport.on("GET", "/pay/status", .fixture("status-pending-attempt-refused"))
        let winning = await paid.start()
        winning.selectMethod("card")
        winning.submitCard()
        await waitUntil("browser") { !paid.browser.opened.isEmpty }
        paid.browser.close()
        await waitUntil("completing") { paid.transport.requests("POST", "/pay/client-session/complete").count == 1 }
        await paid.advance(by: 5)
        paidGate.open()
        await waitUntil("paid") { winning.state == .success }
        XCTAssertTrue(paid.recorder.errors.isEmpty)
        winning.close()
    }
}
