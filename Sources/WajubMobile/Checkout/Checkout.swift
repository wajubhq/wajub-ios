import Foundation

/// Shows and hides the sheet of a `CheckoutController`. WajubMobileUI implements it with UIKit.
@MainActor
public protocol CheckoutPresenting: AnyObject {
    /// Shows the sheet. When it cannot be shown (no screen to present from), call `controller.hostGone()`.
    func present(_ controller: CheckoutController)
    /// Hides the sheet once the checkout has settled, and calls `completion` once it is gone
    /// (at once when it already is).
    func dismiss(_ controller: CheckoutController, completion: @escaping @MainActor @Sendable () -> Void)
}

/// The UI-agnostic `present()`: WajubMobileUI's `WajubCheckout.present(_:)` calls it with its own presenter.
@MainActor
public enum Checkout {
    /// Whether a sheet is open (only one at a time).
    public private(set) static var isPresenting = false

    /// How long `present()` waits for the sheet's dismissal to finish before resolving anyway.
    static let dismissalGrace: UInt64 = 2_000_000_000

    /// Presents a checkout and resolves exactly once, when the sheet is gone: a new `present()` can
    /// follow at once. It creates the `CheckoutController` from `options`, hands it to
    /// `presenter.present(_:)`, starts it, and calls `presenter.dismiss(_:completion:)` once it settles.
    ///
    /// Throws `WajubError` `sheet_already_presented` at once when a sheet is already open (the open
    /// sheet is left alone). A sheet that has settled and is closing is not open: called from
    /// `onComplete`, or right after the host went away, `present()` waits for it to be gone.
    public static func present(_ options: PresentOptions, presenter: CheckoutPresenting,
                               browser: BrowserOpening) async throws -> CheckoutResult {
        try await waitForTheClosingSheet()
        return try await present(CheckoutController(options: options, browser: browser), presenter: presenter)
    }

    static func present(_ controller: CheckoutController, presenter: CheckoutPresenting) async throws -> CheckoutResult {
        try await waitForTheClosingSheet()
        isPresenting = true
        current = controller
        defer {
            isPresenting = false
            current = nil
            let waiting = whenGone
            whenGone = []
            for waiter in waiting { waiter.resume() }
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<CheckoutResult, Never>) in
            controller.onFinish = { [weak presenter, weak controller] result in
                let once = Once()
                let resume: @MainActor @Sendable () -> Void = {
                    if once.claim() { continuation.resume(returning: result) }
                }
                if let presenter, let controller {
                    presenter.dismiss(controller, completion: resume)
                } else {
                    resume()
                }
                // A dismissal that never reports its end must not leave present() hanging.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: dismissalGrace)
                    resume()
                }
            }
            presenter.present(controller)
            controller.start()
        }
    }

    /// The checkout of the sheet on screen.
    private static var current: CheckoutController?
    /// `present()` calls waiting for a settled sheet to be gone.
    private static var whenGone: [CheckedContinuation<Void, Never>] = []

    /// Returns once no sheet is on screen; throws `sheet_already_presented` while one is open (not settled).
    private static func waitForTheClosingSheet() async throws {
        while isPresenting {
            guard current?.result != nil else { throw alreadyPresented }
            await withCheckedContinuation { whenGone.append($0) }
        }
    }

    private static var alreadyPresented: WajubError {
        WajubError.catalogue(WajubError.Code.sheetAlreadyPresented, .en)
    }
}

/// True the first time only.
@MainActor
private final class Once {
    private var done = false

    func claim() -> Bool {
        defer { done = true }
        return !done
    }
}
