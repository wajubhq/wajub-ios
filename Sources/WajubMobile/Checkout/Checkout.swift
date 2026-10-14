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
    /// follow at once.
    ///
    /// Throws `WajubError` `sheet_already_presented` at once when a sheet is already open (the open
    /// sheet is left alone).
    public static func present(_ options: PresentOptions, presenter: CheckoutPresenting,
                               browser: BrowserOpening) async throws -> CheckoutResult {
        guard !isPresenting else { throw alreadyPresented }
        return try await present(CheckoutController(options: options, browser: browser), presenter: presenter)
    }

    static func present(_ controller: CheckoutController, presenter: CheckoutPresenting) async throws -> CheckoutResult {
        guard !isPresenting else { throw alreadyPresented }
        isPresenting = true
        defer { isPresenting = false }
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
