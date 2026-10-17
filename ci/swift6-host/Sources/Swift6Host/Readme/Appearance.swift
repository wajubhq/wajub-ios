// README › Options, Callbacks and Appearance, verbatim (ReadmeTests compares them). Lines marked `// wrapper` are
// not in the README.
import WajubMobile

func readmeAppearance(_ options: inout PresentOptions) { // wrapper
    options.appearance = Appearance(
        theme: .stripe,                          // presets: .stripe, .night, .flat, .noPreset
        colorScheme: .auto,                      // .light, .dark, .auto (follows the phone, live)
        variables: AppearanceVariables(colorPrimary: "#0F766E", fontFamily: "Poppins", borderRadius: "12px"),
        buttonTextColor: "#FFFFFF")
} // wrapper

func readmeOptions(token: String) -> PresentOptions { // wrapper
    let options = PresentOptions(
        sessionToken: token,
        locale: "fr",
        loader: .spinner,
        returnURL: "https://shop.example.com/app/return",
        mobileMoney: MobileMoneyOptions(country: "CI", countryLocked: true, operatorMode: .detect),
        cancelOnDismiss: false
    )
    return options // wrapper
} // wrapper

func readmeCallbacks(_ options: inout PresentOptions) { // wrapper
    options.callbacks = CheckoutCallbacks(
        onReady: { event in print("ready:", event.environment, event.methods) },
        onPaymentStarted: { event in print("paying with", event.channel) },
        onError: { error in print(error.code, error.correlationId ?? "-") }
    )
} // wrapper

/// The forms the README's text names.
func readmeAppearanceFromJSON(_ jsonString: String) throws -> Appearance {
    Appearance(json: try JSONValue.parse(jsonString))
}

func readmeOptionTable(token: String) -> PresentOptions {
    var options = PresentOptions(sessionToken: token)
    options.locale = "fr"
    options.loader = .spinner
    options.readyTimeout = 0
    options.mobileMoney = MobileMoneyOptions(country: "CM", countryLocked: true, operatorMode: .detect)
    options.cancelOnDismiss = false
    options.autoCloseSuccess = 0
    options.appearance = Appearance(theme: .noPreset, shadow: .noShadow)
    return options
}

/// The helpers the README names.
func readmeHelpers() async throws -> String {
    let data = MobileMoneyData.shared
    let number = "670000000"
    _ = data.isValid(number, country: "CM")
    _ = data.nationalDigits(number, country: "CM")
    _ = data.formatAsYouType(number)
    _ = data.badge(operatorId: data.detectOperator(number, country: "CM") ?? "mtn", fallbackName: "MTN")
    let status = try await WajubSession(sessionToken: "token").status()
    return data.e164(number, country: "CM") + " " + status.transaction.status.rawValue
}
