import Foundation

/// Thrown when a body cannot be read as the model it should be (only `transaction.amount` is required).
public struct WireDecodingError: Error, Equatable, Sendable {
    public let field: String
}

/// A payment status (`TransactionStatus.php`). Unknown values are kept as they are.
public struct TransactionStatus: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let pending = TransactionStatus(rawValue: "pending")
    public static let processing = TransactionStatus(rawValue: "processing")
    public static let partial = TransactionStatus(rawValue: "partial")
    public static let succeeded = TransactionStatus(rawValue: "succeeded")
    public static let failed = TransactionStatus(rawValue: "failed")
    public static let cancelled = TransactionStatus(rawValue: "cancelled")
    public static let expired = TransactionStatus(rawValue: "expired")
    public static let refunded = TransactionStatus(rawValue: "refunded")
    public static let partiallyRefunded = TransactionStatus(rawValue: "partially_refunded")

    /// `succeeded`, `refunded`, `partially_refunded`: the payment was paid.
    public var isPaid: Bool { self == .succeeded || self == .refunded || self == .partiallyRefunded }

    public var description: String { rawValue }
}

/// `transaction.processing_context`: present only while `processing` or `partial`.
public struct ProcessingContext: Equatable, Sendable {
    public var channelSlug: String?
    public var isMobileMoney: Bool
    public var isUSSD: Bool
    public var isBankTransfer: Bool
    /// English; may hold a USSD fallback ("dial *126#").
    public var payerInstruction: String?
    /// A provider page to reopen.
    public var actionURL: String?
    public var threeDSId: String?
    public var threeDSMethod: String?
    public var maskedEmail: String?
    public var threeDSTimeout: Int?

    public init(json: JSONValue) {
        channelSlug = json["channel_slug"]?.nonEmptyString
        isMobileMoney = json["is_mobile_money"]?.bool ?? false
        isUSSD = json["is_ussd"]?.bool ?? false
        isBankTransfer = json["is_bank_transfer"]?.bool ?? false
        payerInstruction = json["payer_instruction"]?.nonEmptyString
        actionURL = json["action_url"]?.nonEmptyString
        threeDSId = json["three_ds_id"]?.nonEmptyString
        threeDSMethod = json["three_ds_method"]?.nonEmptyString
        maskedEmail = json["masked_email"]?.nonEmptyString
        threeDSTimeout = json["three_ds_timeout"]?.int
    }
}

public struct TransactionFee: Equatable, Sendable {
    /// Major units.
    public var amount: Double?
    /// Decimal, e.g. 0.035.
    public var rate: Double?
    public var description: String?

    public init(json: JSONValue) {
        amount = json["amount"]?.double
        rate = json["rate"]?.double
        description = json["description"]?.string
    }
}

public struct Customer: Equatable, Sendable {
    public var name: String?
    public var email: String?

    public init(json: JSONValue) {
        name = json["name"]?.nonEmptyString
        email = json["email"]?.nonEmptyString
    }
}

/// `transaction` of `GET /pay/session` and of the payment answers. Amounts are major units.
public struct SessionTransaction: Equatable, Sendable {
    /// Wajub's payment id (`trx_…`): the realtime channel suffix and `PaymentSuccess.id`.
    public var id: String
    /// The merchant's reference (= `trxref`). Not the `reference` of `GET /pay/status`.
    public var reference: String?
    public var trxref: String?
    public var amount: Double
    /// What the payer pays (fee included when the payer bears it): the amount to show.
    public var amountTotal: Double
    public var amountCollected: Double?
    public var amountPaid: Double?
    public var remainingAmount: Double?
    public var currency: String
    public var bearer: String?
    public var fee: TransactionFee?
    public var status: TransactionStatus
    public var statusLabel: String?
    public var sandbox: Bool
    public var description: String?
    public var customer: Customer?
    public var receiptURL: String?
    public var expiresAt: String?
    public var createdAt: String?
    public var updatedAt: String?
    public var terminalAt: String?
    public var processingContext: ProcessingContext?
    /// A refused try's code, when the payment carries one.
    public var errorCode: String?

    public init(json: JSONValue) throws {
        guard let amount = json["amount"]?.double else { throw WireDecodingError(field: "transaction.amount") }
        id = json["id"]?.string ?? ""
        reference = json["reference"]?.nonEmptyString
        trxref = json["trxref"]?.nonEmptyString
        self.amount = amount
        amountTotal = json["amount_total"]?.double ?? amount
        amountCollected = json["amount_collected"]?.double
        amountPaid = json["amount_paid"]?.double
        remainingAmount = json["remaining_amount"]?.double
        currency = json["currency"]?.string ?? ""
        bearer = json["bearer"]?.nonEmptyString
        fee = json["fee"].flatMap { $0.object == nil ? nil : TransactionFee(json: $0) }
        status = TransactionStatus(rawValue: json["status"]?.string ?? "pending")
        statusLabel = json["status_label"]?.nonEmptyString
        sandbox = json["sandbox"]?.bool ?? false
        description = json["description"]?.nonEmptyString
        customer = json["customer"].flatMap { $0.object == nil ? nil : Customer(json: $0) }
        receiptURL = json["receipt_url"]?.nonEmptyString
        expiresAt = json["expires_at"]?.nonEmptyString
        createdAt = json["created_at"]?.nonEmptyString
        updatedAt = json["updated_at"]?.nonEmptyString
        terminalAt = json["terminal_at"]?.nonEmptyString
        processingContext = json["processing_context"].flatMap { $0.object == nil ? nil : ProcessingContext(json: $0) }
        errorCode = json["error_code"]?.nonEmptyString
    }

    /// A transaction in an optional position: `nil` when absent or unreadable.
    static func optional(_ json: JSONValue?) -> SessionTransaction? {
        guard let json, json.object != nil else { return nil }
        return try? SessionTransaction(json: json)
    }
}

/// One member of an aggregate channel (`cm.mobile`).
public struct ChannelOperator: Equatable, Sendable {
    /// The real operator channel, e.g. `cm.orange`.
    public var slug: String
    /// `mtn`, `orange`.
    public var operatorId: String
    /// In the session's locale.
    public var name: String
    /// Mostly an SVG, which iOS does not draw.
    public var logo: String?
    /// The same logo as a PNG, when the API has one.
    public var logoPNG: String?

    public init(json: JSONValue) {
        slug = json["slug"]?.string ?? ""
        operatorId = json["operator"]?.string ?? ""
        name = json["name"]?.string ?? ""
        logo = json["logo"]?.nonEmptyString
        logoPNG = json["logo_png"]?.nonEmptyString
    }

    /// The logo iOS can draw: the PNG, else a logo that is not an SVG; `nil` otherwise.
    public var drawableLogo: String? { ChannelLogo.drawable(logo: logo, png: logoPNG) }
}

/// A payment channel of the session.
public struct SessionChannel: Equatable, Sendable {
    public var id: String
    public var slug: String
    /// In the session's locale.
    public var name: String
    /// Always French (the literal key `name.fr`).
    public var nameFr: String?
    /// `mobile_money`, `mobile`, `card`, `wallet`, …
    public var type: String
    /// Mostly an SVG, which iOS does not draw.
    public var logo: String?
    /// The same logo as a PNG, when the API has one.
    public var logoPNG: String?
    /// ISO-2, upper case. May be empty (card).
    public var countries: [String]
    public var minAmount: Double?
    public var maxAmount: Double?
    public var currency: String?
    /// Aggregates only.
    public var operators: [ChannelOperator]

    public init(json: JSONValue) {
        slug = json["slug"]?.string ?? json["id"]?.string ?? ""
        id = json["id"]?.string ?? slug
        name = json["name"]?.string ?? slug
        nameFr = json["name.fr"]?.nonEmptyString
        type = json["type"]?.string ?? ""
        logo = json["logo"]?.nonEmptyString
        logoPNG = json["logo_png"]?.nonEmptyString
        countries = json["countries"]?.strings.map { $0.uppercased() } ?? []
        minAmount = json["min_amount"]?.double
        maxAmount = json["max_amount"]?.double
        currency = json["currency"]?.nonEmptyString
        operators = (json["operators"]?.array ?? []).map(ChannelOperator.init(json:))
    }

    /// `mobile_money` or `mobile`.
    public var isMobileMoney: Bool { type == "mobile_money" || type == "mobile" }

    /// An aggregate (`cm.mobile`) folds several operators.
    public var isAggregate: Bool { !operators.isEmpty }

    /// The logo iOS can draw: the PNG, else a logo that is not an SVG; `nil` otherwise.
    public var drawableLogo: String? { ChannelLogo.drawable(logo: logo, png: logoPNG) }

    /// The name for the sheet's language: `name.fr` in French, `name` in English.
    public func localizedName(_ language: WajubLanguage) -> String {
        language == .fr ? (nameFr ?? name) : name
    }
}

/// `branding.white_label`: a boolean, or the web's object form.
public struct WhiteLabel: Equatable, Sendable {
    public var enabled: Bool
    public var brandName: String?
    public var supportEmail: String?
    public var supportPhone: String?

    init?(json: JSONValue?) {
        guard let json, !json.isNull else { return nil }
        if let flag = json.bool {
            enabled = flag
        } else if json.object != nil {
            enabled = json["enabled"]?.bool ?? false
            brandName = json["brand_name"]?.nonEmptyString
            supportEmail = json["support_email"]?.nonEmptyString
            supportPhone = json["support_phone"]?.nonEmptyString
        } else {
            return nil
        }
    }
}

/// The merchant's branding. Every key is optional; colours stay strings and are parsed by the theme.
public struct Branding: Equatable, Sendable {
    public var primaryColor: String?
    public var secondaryColor: String?
    public var backgroundColor: String?
    public var logoURL: String?
    public var logoSquareURL: String?
    public var iconURL: String?
    public var businessName: String?
    public var borderRadius: String?
    public var font: String?
    /// `light`, `dark`, `system` or absent.
    public var appearanceMode: String?
    public var density: String?
    public var locale: String?
    public var whiteLabel: WhiteLabel?
    public var cardBackgroundColor: String?
    public var cardBorderColor: String?
    public var inputBackgroundColor: String?
    public var inputBorderColor: String?
    public var textMutedColor: String?
    public var buttonTextColor: String?
    public var successColor: String?
    public var errorColor: String?
    public var shadow: String?
    /// 0–100.
    public var overlayIntensity: Int?
    /// From an integer, a numeric string, `"normal"` or `"bold"`.
    public var fontWeightHeading: Int?
    public var fontWeightBody: Int?
    public var separatorColor: String?

    public init(json: JSONValue?) {
        let json = json ?? .null
        primaryColor = json["primary_color"]?.nonEmptyString
        secondaryColor = json["secondary_color"]?.nonEmptyString
        backgroundColor = json["background_color"]?.nonEmptyString
        logoURL = json["logo_url"]?.nonEmptyString
        logoSquareURL = json["logo_square_url"]?.nonEmptyString
        iconURL = json["icon_url"]?.nonEmptyString
        businessName = json["business_name"]?.nonEmptyString
        borderRadius = json["border_radius"]?.nonEmptyString
        font = json["font"]?.nonEmptyString
        appearanceMode = json["appearance_mode"]?.nonEmptyString
        density = json["density"]?.nonEmptyString
        locale = json["locale"]?.nonEmptyString
        whiteLabel = WhiteLabel(json: json["white_label"])
        cardBackgroundColor = json["card.background_color"]?.nonEmptyString
        cardBorderColor = json["card.border_color"]?.nonEmptyString
        inputBackgroundColor = json["input_background_color"]?.nonEmptyString
        inputBorderColor = json["input_border_color"]?.nonEmptyString
        textMutedColor = json["text_muted_color"]?.nonEmptyString
        buttonTextColor = json["button_text_color"]?.nonEmptyString
        successColor = json["success_color"]?.nonEmptyString
        errorColor = json["error_color"]?.nonEmptyString
        shadow = json["shadow"]?.nonEmptyString
        overlayIntensity = json["overlay_intensity"]?.int
        fontWeightHeading = AppearanceValue.fontWeight(json["font_weight_heading"]?.string)
        fontWeightBody = AppearanceValue.fontWeight(json["font_weight_body"]?.string)
        separatorColor = json["separator_color"]?.nonEmptyString
    }

    /// `true` hides "Secured by Wajub".
    public var isWhiteLabel: Bool { whiteLabel?.enabled ?? false }

    /// The header logo: `logo_url`, else `logo_square_url`, else `icon_url`.
    public var headerLogoURL: String? { logoURL ?? logoSquareURL ?? iconURL }
}

/// `echo`: where the realtime socket is.
public struct EchoConfig: Equatable, Sendable {
    /// `nil` when broadcasting is not configured: poll only.
    public var key: String?
    /// Scheme included: `wss://ws.wajub.com`.
    public var wsHost: String?
    public var wsPort: Int?
    public var channelPrefix: String
    public var broadcaster: String?

    public init(json: JSONValue) {
        key = json["key"]?.nonEmptyString
        wsHost = json["ws_host"]?.nonEmptyString
        wsPort = json["ws_port"]?.int
        channelPrefix = json["channel_prefix"]?.string ?? "private-payment."
        broadcaster = json["broadcaster"]?.nonEmptyString
    }
}

/// `altcha`: a proof-of-work challenge to solve before paying.
public struct AltchaChallenge: Equatable, Sendable {
    public var algorithm: String
    public var challenge: String
    public var salt: String
    public var signature: String
    public var maxNumber: Int

    public init(algorithm: String, challenge: String, salt: String, signature: String, maxNumber: Int) {
        self.algorithm = algorithm
        self.challenge = challenge
        self.salt = salt
        self.signature = signature
        self.maxNumber = maxNumber
    }

    init?(json: JSONValue?) {
        guard let json, json.object != nil,
              let challenge = json["challenge"]?.nonEmptyString,
              let salt = json["salt"]?.string else { return nil }
        self.algorithm = json["algorithm"]?.string ?? "SHA-256"
        self.challenge = challenge
        self.salt = salt
        self.signature = json["signature"]?.string ?? ""
        self.maxNumber = json["maxnumber"]?.int ?? 1_000_000
    }
}

/// A saved card or Mobile Money number (`saved_methods`).
public struct SavedMethod: Equatable, Sendable {
    public var id: String
    public var type: String
    public var isDefault: Bool
    public var label: String?
    public var brand: String?
    public var provider: String?
    public var last4: String?
    /// Lower-case ISO-2.
    public var phoneCountry: String?

    public init(json: JSONValue) {
        id = json["id"]?.string ?? ""
        type = json["type"]?.string ?? ""
        isDefault = json["is_default"]?.bool ?? false
        label = json["label"]?.nonEmptyString
        brand = json["brand"]?.nonEmptyString
        provider = json["provider"]?.nonEmptyString
        last4 = json["last4"]?.nonEmptyString
        phoneCountry = json["phone_country"]?.nonEmptyString
    }
}

/// `GET /pay/session`.
public struct SessionResponse: Equatable, Sendable {
    public var transaction: SessionTransaction
    public var altcha: AltchaChallenge?
    public var branding: Branding
    public var channels: [SessionChannel]
    /// `fr`, `en` or `nil`.
    public var locale: String?
    public var returnURL: String?
    public var cancelURL: String?
    public var geoCountry: String?
    public var echo: EchoConfig?
    public var savedMethods: [SavedMethod]?
    public var downloadReceipt: Bool

    public init(json: JSONValue) throws {
        guard let transaction = json["transaction"], transaction.object != nil else {
            throw WireDecodingError(field: "transaction")
        }
        self.transaction = try SessionTransaction(json: transaction)
        altcha = AltchaChallenge(json: json["altcha"])
        branding = Branding(json: json["branding"])
        channels = (json["channels"]?.array ?? []).filter { $0.object != nil }.map(SessionChannel.init(json:))
        locale = json["locale"]?.nonEmptyString
        returnURL = json["return_url"]?.nonEmptyString
        cancelURL = json["cancel_url"]?.nonEmptyString
        geoCountry = json["geo_country"]?.nonEmptyString?.uppercased()
        echo = json["echo"].flatMap { $0.object == nil ? nil : EchoConfig(json: $0) }
        savedMethods = json["saved_methods"]?.array.map { $0.map(SavedMethod.init(json:)) }
        downloadReceipt = json["features"]?["download_receipt"]?.bool ?? false
    }
}

/// Which channel or operator logo iOS can draw (it has no SVG decoder).
enum ChannelLogo {
    /// `logo_png` when set, else `logo` when it is not an SVG; `https` only.
    static func drawable(logo: String?, png: String?) -> String? {
        if let png, isHTTPS(png) { return png }
        guard let logo, isHTTPS(logo), !isSVG(logo) else { return nil }
        return logo
    }

    static func isHTTPS(_ url: String) -> Bool {
        url.lowercased().hasPrefix("https://")
    }

    static func isSVG(_ url: String) -> Bool {
        let path = (URL(string: url)?.path ?? url).lowercased()
        return path.hasSuffix(".svg") || path.hasSuffix(".svgz")
    }
}
