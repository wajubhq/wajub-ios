import Foundation

/// How the card channel is paid (README §7).
public enum CardFlavour: Equatable, Sendable {
    /// A provider-hosted card session (Paystack, Flutterwave, Adyen): contact fields, then the provider's page.
    case clientSession(fields: [String])
    /// Stripe: your `CardCollector` produces a `pm_…`.
    case stripe(publishableKey: String)
    /// The provider's card page, after its `required_fields`.
    case hostedRedirect(fields: [String])
    /// The sandbox test-card form.
    case sandboxForm
}

/// A channel the method list cannot offer for this amount.
public enum AmountLimit: Equatable, Sendable {
    case minimum(Double)
    case maximum(Double)
}

/// One entry of the method list. All Mobile Money channels share one entry (their operators are the
/// form's choices); card is one entry; each one-tap wallet is its own.
public struct CheckoutMethod: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case mobileMoney
        case card(CardFlavour)
        case wallet
    }

    /// `mobile_money`, `card`, or the wallet's slug.
    public var id: String
    public var kind: Kind
    /// In the sheet's language.
    public var name: String
    public var logo: String?
    /// The session channels behind it, in API order.
    public var channels: [SessionChannel]
    /// Set when the amount is out of the channel's limits: the method is shown disabled.
    public var limit: AmountLimit?

    public var isEnabled: Bool { limit == nil }

    /// `mobile_money`, `card` or `wallet`: the `method` of the callbacks.
    public var family: String {
        switch kind {
        case .mobileMoney: return "mobile_money"
        case .card: return "card"
        case .wallet: return "wallet"
        }
    }
}

/// Which channels the sheet offers, and how (README §1, §5, §7, §8).
enum MethodResolver {
    /// The contact and billing fields a card provider may ask for (`HostedCardField`).
    static let hostedCardFields: Set<String> = ["first_name", "last_name", "email", "phone", "address", "city", "country", "state", "zip_code"]

    /// The card flavour, first match wins; `nil` hides card.
    static func cardFlavour(_ channel: SessionChannel, config: SdkConfigResponse?, sandbox: Bool, hasCardCollector: Bool) -> CardFlavour? {
        guard let entry = config?.channels[channel.slug], entry.available else { return nil }
        let contactFields = entry.requiredFields.filter(hostedCardFields.contains)
        if entry.clientSession { return .clientSession(fields: contactFields) }
        switch entry.sdk {
        case "stripe_elements":
            guard hasCardCollector, let key = entry.publishableKey else { return nil }
            return .stripe(publishableKey: key)
        case "hosted_redirect":
            return .hostedRedirect(fields: contactFields)
        case "form" where sandbox:
            return .sandboxForm
        default:
            return nil
        }
    }

    /// A Mobile Money channel's sdk-config entry, by raw slug: an aggregate uses its members' entries
    /// (`cm.mtn`, not `cm.mobile`). Without one (sandbox), `form` + `phone`.
    static func mobileMoneyConfig(_ channel: SessionChannel, operatorSlug: String? = nil, config: SdkConfigResponse?) -> SdkChannelConfig {
        let fallback = SdkChannelConfig(sdk: "form", requiredFields: ["phone"])
        guard let config else { return fallback }
        if channel.isAggregate {
            let slugs = operatorSlug.map { [$0] } ?? channel.operators.map(\.slug)
            return slugs.lazy.compactMap { config.channels[$0] }.first ?? fallback
        }
        return config.channels[channel.slug] ?? fallback
    }

    /// A one-tap wallet: `type: wallet` whose sdk-config entry is `form` with no `required_fields`.
    static func isOneTapWallet(_ channel: SessionChannel, config: SdkConfigResponse?) -> Bool {
        guard channel.type == "wallet", let entry = config?.channels[channel.slug] else { return false }
        return entry.available && entry.sdk == "form" && entry.requiredFields.isEmpty
    }

    static func limit(_ channel: SessionChannel, amount: Double) -> AmountLimit? {
        if let minimum = channel.minAmount, minimum > amount { return .minimum(minimum) }
        if let maximum = channel.maxAmount, maximum < amount { return .maximum(maximum) }
        return nil
    }

    /// The channels the sheet shows, in API order.
    static func shownChannels(_ session: SessionResponse, config: SdkConfigResponse?, hasCardCollector: Bool) -> [SessionChannel] {
        session.channels.filter { channel in
            if channel.isMobileMoney { return !MobileMoneyForm.availableOperators(channel, config: config).isEmpty }
            if channel.type == "card" {
                return cardFlavour(channel, config: config, sandbox: session.transaction.sandbox, hasCardCollector: hasCardCollector) != nil
            }
            return isOneTapWallet(channel, config: config)
        }
    }

    /// The method list.
    static func methods(_ session: SessionResponse, config: SdkConfigResponse?, language: WajubLanguage,
                        hasCardCollector: Bool) -> [CheckoutMethod] {
        let amount = session.transaction.amountTotal
        let strings = WajubStrings(language)
        let shown = shownChannels(session, config: config, hasCardCollector: hasCardCollector)
        var methods: [CheckoutMethod] = []
        let mobileMoneyChannels = shown.filter(\.isMobileMoney)
        for channel in shown {
            if channel.isMobileMoney {
                guard channel == mobileMoneyChannels.first else { continue }
                let limits = mobileMoneyChannels.map { limit($0, amount: amount) }
                methods.append(CheckoutMethod(id: "mobile_money", kind: .mobileMoney, name: strings.mobileMoney, logo: channel.logo,
                                              channels: mobileMoneyChannels,
                                              limit: limits.contains(where: { $0 == nil }) ? nil : limits.first ?? nil))
            } else if channel.type == "card",
                      let flavour = cardFlavour(channel, config: config, sandbox: session.transaction.sandbox, hasCardCollector: hasCardCollector) {
                methods.append(CheckoutMethod(id: "card", kind: .card(flavour), name: channel.localizedName(language), logo: channel.logo,
                                              channels: [channel], limit: limit(channel, amount: amount)))
            } else {
                methods.append(CheckoutMethod(id: channel.slug, kind: .wallet, name: channel.localizedName(language), logo: channel.logo,
                                              channels: [channel], limit: limit(channel, amount: amount)))
            }
        }
        return methods
    }
}
