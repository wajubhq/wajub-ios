import Foundation

/// Shows and hides the sheet of a `CheckoutController`. WajubMobileUI implements it with UIKit.
@MainActor
public protocol CheckoutPresenting: AnyObject {
    /// Shows the sheet.
    func present(_ controller: CheckoutController)
    /// Hides the sheet once the checkout has settled (a no-op when it is already gone).
    func dismiss(_ controller: CheckoutController)
}

/// The UI-agnostic `present()`: WajubMobileUI's `WajubCheckout.present(_:)` calls it with its own presenter.
@MainActor
public enum Checkout {
    /// Whether a sheet is open (only one at a time).
    public private(set) static var isPresenting = false

    /// Presents a checkout and resolves exactly once, when the sheet closes.
    ///
    /// Throws `WajubError` `sheet_already_presented` at once when a sheet is already open (the open
    /// sheet is left alone).
    public static func present(_ options: PresentOptions, presenter: CheckoutPresenting,
                               browser: BrowserOpening) async throws -> CheckoutResult {
        try await present(CheckoutController(options: options, browser: browser), presenter: presenter)
    }

    static func present(_ controller: CheckoutController, presenter: CheckoutPresenting) async throws -> CheckoutResult {
        guard !isPresenting else {
            throw WajubError.catalogue(WajubError.Code.sheetAlreadyPresented, .en)
        }
        isPresenting = true
        defer { isPresenting = false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<CheckoutResult, Never>) in
            controller.onFinish = { [weak presenter, weak controller] result in
                if let controller { presenter?.dismiss(controller) }
                continuation.resume(returning: result)
            }
            presenter.present(controller)
            controller.start()
        }
    }
}
