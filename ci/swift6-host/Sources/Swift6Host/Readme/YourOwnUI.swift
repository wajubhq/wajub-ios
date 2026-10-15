// README › Your own UI, verbatim (ReadmeTests compares them).
import Foundation
import WajubMobile

@MainActor
final class MySheet: CheckoutPresenting {
    private var controller: CheckoutController?

    func present(_ controller: CheckoutController) {
        self.controller = controller
        controller.onChange = { [weak self] in self?.render() }
        // Show your sheet; its buttons call the controller's actions.
    }

    func dismiss(_ controller: CheckoutController, completion: @escaping @MainActor @Sendable () -> Void) {
        // Hide your sheet, then:
        self.controller = nil
        completion()
    }

    private func render() {
        guard let controller else { return }
        print(controller.state?.rawValue ?? "loading") // draw controller.screen
    }
}

@MainActor
final class MyBrowser: BrowserOpening {
    func open(_ url: URL, mode: BrowserMode, onClose: @escaping @MainActor @Sendable () -> Void) async -> Bool {
        // .inApp: present an SFSafariViewController and call onClose() once it is closed.
        // .external: return await UIApplication.shared.open(url).
        false // nothing could open the page
    }
}

@MainActor
func payWithMySheet(_ options: PresentOptions) async throws -> CheckoutResult {
    try await Checkout.present(options, presenter: MySheet(), browser: MyBrowser())
}
