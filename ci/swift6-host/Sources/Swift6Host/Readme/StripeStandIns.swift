// Stand-ins for the stripe-ios types the README's Stripe sample uses: the package does not depend on
// stripe-ios, and the sample's Wajub side (CardCollector, CardCollectionRequest) is what is checked.
#if !canImport(StripePaymentsUI)
final class STPAPIClient: @unchecked Sendable {
    static let shared = STPAPIClient()
    var publishableKey: String?

    func createPaymentMethod(with paymentMethodParams: STPPaymentMethodParams) async throws -> STPPaymentMethod {
        STPPaymentMethod(stripeId: "pm_123")
    }
}

final class STPPaymentMethodParams: @unchecked Sendable {}

final class STPPaymentMethod: @unchecked Sendable {
    let stripeId: String

    init(stripeId: String) {
        self.stripeId = stripeId
    }
}
#endif
