import Foundation
import WajubMobile
import WajubMobileUI

/// A browser of the host's own: the close callback goes into a `@Sendable` system completion handler
/// (as with `ASWebAuthenticationSession`).
@MainActor
final class HostBrowser: BrowserOpening {
    private(set) var finish: (@Sendable () -> Void)?

    func open(_ url: URL, mode: BrowserMode, onClose: @escaping @MainActor @Sendable () -> Void) async -> Bool {
        finish = { Task { @MainActor in onClose() } }
        return true
    }
}

/// A presenter of the host's own: the dismissal completion goes into UIKit's completion handler.
@MainActor
final class HostPresenter: CheckoutPresenting {
    private(set) var whenGone: (@Sendable () -> Void)?

    func present(_ controller: CheckoutController) {
        controller.start()
    }

    func dismiss(_ controller: CheckoutController, completion: @escaping @MainActor @Sendable () -> Void) {
        whenGone = { Task { @MainActor in completion() } }
    }
}

/// A Stripe-style card collector.
final class HostCardCollector: CardCollector {
    @MainActor
    func collectPaymentMethod(_ request: CardCollectionRequest) async throws -> String? {
        request.publishableKey.isEmpty ? nil : "pm_123"
    }
}

/// Presenting with the host's own pieces, and reading the result.
@MainActor
func payWithHostPieces(token: String) async -> String {
    var options = PresentOptions(sessionToken: token)
    options.cardCollector = HostCardCollector()
    options.callbacks.onStateChange = { event in print(event.state.rawValue) }
    do {
        switch try await Checkout.present(options, presenter: HostPresenter(), browser: HostBrowser()) {
        case .complete(let payment, _): return payment.id
        case .processing: return "processing"
        case .failed(let error, _): return error.code
        case .cancelled(let reason, _): return reason.rawValue
        }
    } catch {
        return "\(error)"
    }
}
