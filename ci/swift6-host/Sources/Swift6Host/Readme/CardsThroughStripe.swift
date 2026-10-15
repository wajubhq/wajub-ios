// README › Cards through Stripe, verbatim (ReadmeTests compares them). Lines marked `// wrapper` are not in
// the README. Without stripe-ios, Stripe's types are the stand-ins of StripeStandIns.swift.
#if canImport(StripePaymentsUI) // wrapper
import StripePaymentsUI
#endif // wrapper
import WajubMobile

final class StripeCardCollector: CardCollector {
    @MainActor
    func collectPaymentMethod(_ request: CardCollectionRequest) async throws -> String? {
        STPAPIClient.shared.publishableKey = request.publishableKey
        // Your own screen with an STPPaymentCardTextField, presented over the sheet.
        guard let card = await CardEntryScreen.present(amount: request.amount, currency: request.currency) else {
            return nil // the payer backed out
        }
        let paymentMethod = try await STPAPIClient.shared.createPaymentMethod(with: card.paymentMethodParams)
        return paymentMethod.stripeId
    }
}

func readmeStripe(_ options: inout PresentOptions) { // wrapper
    options.cardCollector = StripeCardCollector()
} // wrapper

/// The app's own card screen.
@MainActor
enum CardEntryScreen {
    struct Card {
        var paymentMethodParams: STPPaymentMethodParams
    }

    static func present(amount: Double, currency: String) async -> Card? { nil }
}
