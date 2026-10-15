# Wajub iOS SDK (Swift)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Take Mobile Money, card and wallet payments in your iOS app with a ready-made payment sheet from
[Wajub](https://wajub.com).

## Requirements

| | |
|---|---|
| iOS | 15.0 or later |
| Swift | 5.9 or later (Xcode 15 or later) |
| Dependencies | None. Stripe is optional and lives in your app, see [Cards](#cards) |
| Target | An app, not an app extension |

## Installation

Swift Package Manager: in Xcode, *File › Add Package Dependencies…* with
`https://github.com/wajubhq/wajub-ios`, or in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/wajubhq/wajub-ios.git", from: "1.1.0"),
],
targets: [
    .target(name: "App", dependencies: [
        .product(name: "WajubMobileUI", package: "wajub-ios"),
    ]),
]
```

| Product | What it holds |
|---|---|
| `WajubMobile` | The models, the errors, the Mobile Money helpers, and what you need to draw [your own payment screens](#your-own-ui). No UI |
| `WajubMobileUI` | The SwiftUI sheet and `WajubCheckout.present(_:from:)`. It brings `WajubMobile` with it |

## Quick start

Your server creates the payment, the app presents the sheet with its token, and your server
confirms the outcome. The app never holds your secret key.

1. Create the payment on your server with `POST /payments` and your secret key, and hand its
   `authorization_token` to the app.
2. Present the sheet:

```swift
import UIKit
import WajubMobile
import WajubMobileUI

@MainActor
func pay(token: String, from viewController: UIViewController) async {
    var options = PresentOptions(sessionToken: token)
    options.returnURL = "https://shop.example.com/app/return"   // optional, a universal link into your app
    options.callbacks.onStateChange = { event in print("checkout:", event.state.rawValue) }

    do {
        switch try await WajubCheckout.present(options, from: viewController) {
        case .complete(let payment, _):
            // Paid. Confirm on your server before delivering.
            await confirmOnServer(paymentId: payment.id)
        case .processing:
            // Closed while a payment was running: money may still move, your server learns the outcome.
            break
        case .failed(let error, _):
            print(error.code, error.message)
        case .cancelled(let reason, _):
            print("cancelled:", reason.rawValue)
        }
    } catch let error as WajubError {
        // Only `sheet_already_presented`: a sheet is already open.
        print(error.message)
    } catch {}
}
```

3. Confirm on your server before you deliver anything, with `GET /payments/{id}` or the
   `payment.succeeded` webhook. The result in the app is what the payer saw, not a proof of
   payment: a Mobile Money approval can land after the payer closed the sheet.

`present` resolves once, when the sheet is gone, with the same value `onComplete` receives.
`from:` is optional: without it the sheet presents from the top-most view controller of the key
window. It throws `sheet_already_presented` only while another sheet is still open; called from
`onComplete`, it waits for the closing sheet to be gone.

## Options

`PresentOptions` takes every option as a labelled argument of its initializer, with the default
below, and as a `var` property.

| Option | Default | What it does |
|---|---|---|
| `sessionToken` | Required | The payment's `authorization_token` |
| `locale` | `nil` | `"fr"` or `"en"`. Without it, the payment's language, else the device's |
| `appearance` | `nil` | The sheet's look, see [Appearance](#appearance) |
| `loader` | `.skeleton` | `.skeleton`, pulsing placeholder blocks, or `.spinner` |
| `readyTimeout` | `15000` | Milliseconds. Past it, a sheet still loading shows an error with **Retry** and reports `ready_timeout` to `onLoadError`. `0` disables it |
| `returnURL` | `nil` | An `https` universal link that brings the payer back to your app from a provider's page. Without it the payer comes back to the app by hand |
| `mobileMoney` | `MobileMoneyOptions()` | See [Mobile Money](#mobile-money) |
| `cancelOnDismiss` | `true` | Closing the sheet before any attempt cancels the payment. `false` leaves it open so you can present it again |
| `autoCloseSuccess` | `3000` | Milliseconds before the success screen closes itself. `0` keeps it |
| `callbacks` | `CheckoutCallbacks()` | See [Callbacks](#callbacks) |
| `cardCollector` | `nil` | Your Stripe card collector, see [Cards](#cards) |

```swift
let options = PresentOptions(
    sessionToken: token,
    locale: "fr",
    loader: .spinner,
    returnURL: "https://shop.example.com/app/return",
    mobileMoney: MobileMoneyOptions(country: "CI", countryLocked: true, operatorMode: .detect),
    cancelOnDismiss: false
)
```

## Callbacks

Every callback is optional and runs on the main thread, in this order: `onReady`, then
`onStateChange` as the sheet moves, `onPaymentStarted` and `onRedirect`, then `onSuccess`,
`onError` or `onCancel`, and `onComplete` exactly once. A callback that throws does not stop the
sheet.

| Callback | Payload | When |
|---|---|---|
| `onReady` | `ReadyEvent`: `sessionId`, `environment` (`"sandbox"` or `"live"`), `amount`, `currency`, `methods` | The first screen is drawn, also for a payment already paid or ended |
| `onStateChange` | `StateChangeEvent`: `state`, `method` (`mobile_money`, `card`, `wallet` or `unknown`) | After `onReady`, then on every state change |
| `onLoadError` | `WajubError` | The sheet cannot offer a payment |
| `onPaymentStarted` | `PaymentStartedEvent`: `method`, `channel` | The payment request is accepted. From now on, closing the sheet resolves `.processing` |
| `onRedirect` | `RedirectEvent`: `url` | Right before a provider page opens |
| `onSuccess` | `PaymentSuccess` | The payment succeeded, with `method` `"unknown"` when it was already paid when the sheet opened |
| `onError` | `WajubError` | Every failure the payer sees. Field validation is not reported |
| `onCancel` | `CancelEvent`: `reason`, `redirectURL` | The sheet closes as `.cancelled` |
| `onComplete` | `CheckoutResult` | The sheet closes, with what `present` resolves with |

```swift
options.callbacks = CheckoutCallbacks(
    onReady: { event in print("ready:", event.environment, event.methods) },
    onPaymentStarted: { event in print("paying with", event.channel) },
    onError: { error in print(error.code, error.correlationId ?? "-") }
)
```

### States

`CheckoutState` is a `String` enum whose raw values are the state names.

| State | What the payer sees |
|---|---|
| `INITIATED` | The list of payment methods |
| `COLLECTING_DETAILS` | The form of the chosen method |
| `PROCESSING` | The form, its **Pay** button busy |
| `APPROVAL_REQUIRED` | "Approve the payment on your phone" |
| `USSD_REQUIRED` | "Dial this code" |
| `OTP_REQUIRED`, `PIN_REQUIRED`, `PHONE_REQUIRED`, `BIRTHDAY_REQUIRED`, `ADDRESS_REQUIRED` | A [confirmation step](#confirmation-steps) |
| `3DS_REQUIRED` | 3-D Secure in Safari, or in sandbox a code sent by email |
| `VERIFYING` | The step's screen while its answer is checked |
| `PENDING` | "Payment in progress", with **Continue payment** when a payment page can be reopened |
| `SUCCESS`, `FAILED`, `EXPIRED`, `CANCELLED` | The outcome, with **Try again** on a failure that allows it |

## Results

| `CheckoutResult` | When |
|---|---|
| `.complete(payment:transaction:)` | The sheet closed after the success screen, also for a payment already paid when it opened |
| `.processing(transaction:)` | The sheet closed while a payment was under way: money may still move, confirm it on your server |
| `.failed(error:transaction:)` | The sheet closed on a failure, an expiry, a load error, or a payment cancelled elsewhere (`payment_cancelled`) |
| `.cancelled(reason:redirectURL:)` | **Cancel payment** (`.payerCancelled`), a close before any attempt (`.dismissed`), or the presenting screen going away first (`.hostGone`) |

`PaymentSuccess` holds `id` (Wajub's payment id, what `GET /payments/{id}` takes), `reference`
(yours), `amount` (what the payer paid, fee included), `currency`, `method`, `status` (always
`"success"`), `timestamp` and `receiptURL`.

When the screen you presented from goes away while the sheet is open, the sheet resolves
`.cancelled` with `.hostGone` before any attempt, `.processing` once one started and `.complete`
after a success, and it never cancels the payment. If the app's process dies, nothing can resolve:
at the next launch, read the outcome on your server, or with `WajubSession(sessionToken:).status()`.

### Cancelling and closing

The payer closes the sheet with its close button or a swipe down.

| The payer | Result | The payment |
|---|---|---|
| Taps **Cancel payment** | `.cancelled`, `.payerCancelled` | Cancelled |
| Closes the sheet before paying, or back on the form after a refusal | `.cancelled`, `.dismissed` | Cancelled, unless `cancelOnDismiss` is `false` |
| Closes it on the failure screen | `.failed`, with the error the payer saw | Cancelled when it still can be, unless `cancelOnDismiss` is `false` |
| Closes it while a payment is under way: approving on the phone, dialling a code, confirming a step or waiting | `.processing` | Keeps running: confirm on your server |
| Closes it after the success screen | `.complete` | Paid |

The sheet never shows a failure when it cannot be sure of the outcome: it shows "Payment in
progress" and keeps waiting. Closed then, it resolves `.processing`.

## Appearance

`PresentOptions.appearance` sets the sheet's look, with the keys, presets and variables of
[Appearance](https://docs.wajub.com/libraries/components/appearance):

```swift
options.appearance = Appearance(
    theme: .stripe,                          // presets: .stripe, .night, .flat, .noPreset
    colorScheme: .auto,                      // .light, .dark, .auto (follows the phone, live)
    variables: AppearanceVariables(colorPrimary: "#0F766E", fontFamily: "Poppins", borderRadius: "12px"),
    buttonTextColor: "#FFFFFF")
```

- The `"none"` preset is `.noPreset` for `theme`, and no shadow is `.noShadow` for `shadow`.
- `Appearance(json:)` reads an appearance object from JSON.
- `inherit: true` takes the presenting screen's tint, colours and light or dark style.
- What you set wins. The merchant's branding from the Dashboard fills what you leave unset: logo,
  business name, colours, radius and font. A white-label merchant hides "Secured by Wajub".
- A `fontFamily` is used only if your app ships the font.
- `disableAnimations: true`, or Reduce Motion on the phone, stops the animations.

## Mobile Money

The payer picks the country and the operator and types the number, formatted as they type it. The
number's prefix preselects its operator, and a number that belongs to another operator is flagged
before anything is sent. The sheet then asks the payer to approve the payment on their phone.

| `MobileMoneyOptions` | Default | What it does |
|---|---|---|
| `country` | `nil` | The country to start on, ISO-2. Without it, the payer's country when it is offered |
| `countryLocked` | `false` | Hides the country selector, when `country` is offered |
| `operatorMode` | `.choose` | `.choose` lists the operators. `.detect` shows the operator found from the number, and the list only when the number does not tell or the payer opens it |

For your own screens, `MobileMoneyData.shared` checks, formats and reads numbers:
`isValid(_:country:)`, `nationalDigits(_:country:)`, `e164(_:country:)`, `formatAsYouType(_:)`,
`detectOperator(_:country:)`, and `badge(operatorId:fallbackName:)` for an operator's badge. In a
sandbox payment (`SessionTransaction.sandbox`), pass `sandbox: true` to `isValid`, `detectOperator`
and `e164`, or use `sandboxTestNumber(_:country:)`: Wajub's test numbers are then accepted.

## Cards

| The card is paid | What you do |
|---|---|
| With Stripe | Pass a `CardCollector` (below). Without one, Stripe card payments are not offered |
| On the payment provider's secure page | Nothing. The sheet asks for the contact details the provider needs, then opens its page in Safari |
| In sandbox | Nothing. The sheet shows a test card form |

A one-tap wallet opens the wallet's own app. While a page is open, **Continue payment** reopens it.
In live, the card number is typed only into Stripe's form or the provider's page.

### Stripe through your own collector

The package does not depend on Stripe's SDK. Implement `CardCollector` in your app with
`stripe-ios`: the sheet calls it when the payer taps **Pay by card**, and sends the `pm_…` id it
returns.

```swift
import StripePaymentsUI
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

options.cardCollector = StripeCardCollector()
```

`CardCollectionRequest` carries `publishableKey`, the Stripe key to use, `amount`, `currency`,
`customerEmail`, `customerName` and `language`, the sheet's. Return `nil` when the payer backs out:
the sheet stays on the card form and nothing is charged. An error you throw is shown on the card
form: a `WajubError` as it is, any other with its own description when it has one.

## Confirmation steps

Some card payments ask the payer for one more thing after **Pay**, sometimes several in a row.
Each step has its own screen.

| State | The payer enters |
|---|---|
| `OTP_REQUIRED` | The code they received |
| `PIN_REQUIRED` | The card PIN |
| `PHONE_REQUIRED` | A phone number |
| `BIRTHDAY_REQUIRED` | A date of birth |
| `ADDRESS_REQUIRED` | A billing address |
| `3DS_REQUIRED` | 3-D Secure in Safari, or in sandbox the code sent by email |

A wrong answer keeps the screen and shows the attempts left. A step that expires or runs out of
attempts ends on the failure screen, and **Try again** goes back to choosing a method.

## Errors

Every failure is a `WajubError`, a struct conforming to `Error` and `LocalizedError`, whose
`errorDescription` is `message`.

| Field | What it is for |
|---|---|
| `type` | `.apiError`, `.authenticationError`, `.invalidRequestError`, `.paymentError` or `.rateLimitError` |
| `code` | What to branch on. The codes are constants in `WajubError.Code` |
| `message` | For the payer, in the sheet's language. Show it as is |
| `declineCode` | On a decline, the bank's or the operator's code |
| `retryable` | Whether **Try again** can work |
| `param` | The field at fault |
| `correlationId` | The request id to quote to Wajub support |
| `retryAfterSeconds` | On `rate_limited`, the seconds to wait before trying again |
| `blockReference` | On `shield_blocked`, the reference to quote to Wajub support |

| Group | Codes |
|---|---|
| Load (`onLoadError`, then `.failed`) | `session_not_found`, `session_terminal_expired`, `session_terminal_cancelled`, `session_terminal_failed`, `load_error` and `ready_timeout` (retryable), `no_payment_method` |
| Connection | `network_error`, `timeout`, `server_error`, `rate_limited`, `request_failed` |
| Payment | `payment_declined`, `insufficient_funds` and other decline codes (retryable), `payment_attempt_ended` (retryable, nothing was charged), `payment_failed`, `payment_cancelled`, `session_expired`, `limit_exceeded`, `shield_blocked`, `merchant_not_verified`, `merchant_restricted`, `payment_method_restricted`, `country_restricted`, `currency_restricted`, `channel_not_accepted`, `security_check_failed` (retryable), `unsupported_action`, `redirect_unavailable` |
| Confirmation steps | `invalid_otp`, `invalid_pin`, `invalid_phone`, `invalid_birthday`, `invalid_address`, `invalid_code` (the screen stays), `otp_expired`, `pin_expired`, `phone_expired`, `birthday_expired`, `address_expired`, `max_attempts_exceeded`, `3ds_failed`, `3ds_rejected`, `3ds_cancelled`, `3ds_timeout` |
| Your code | `sheet_already_presented` |

A code not listed here, a bank's own decline code for instance, can reach you too: show `message`.
On `rate_limited`, the sheet counts down before **Try again**: do not wrap it in a retry loop of
your own.

## Your own UI

Import `WajubMobile` alone to draw your own payment screens: `CheckoutController` keeps the
sheet's logic, and you draw only its screens.

`Checkout.present(_:presenter:browser:)` runs the whole checkout under your own UI, with the same
rules as `WajubCheckout.present`: one sheet at a time, and the `CheckoutResult` once your sheet is
gone.

- Your `CheckoutPresenting` draws the controller's `screen`, redraws on `onChange`, and wires your
  buttons to the controller's actions, `selectMethod`, `setPhone`, `submitMobileMoney`,
  `submitCard`, `submitStep`, `tryAgain`, `cancelPayment` and the others. Call `dismiss`'s
  `completion` once your sheet is gone, and `controller.hostGone()` if your sheet cannot be shown.
- Your `BrowserOpening` opens provider pages: `.inApp` in an `SFSafariViewController`, calling
  `onClose` once it is closed, and `.external` with `UIApplication.open`. It returns `false` when
  nothing can open the page.
- `completion` and `onClose` are `@MainActor @Sendable`.

```swift
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
```

`WajubSession(sessionToken:)` is the lower-level client of one payment. Its `status()` reads the
payment's status, for example at the next launch after the app was closed during a payment.

## Privacy

When the payer pays, the SDK sends Wajub what the payment needs and, for fraud prevention, basic
information about the device and a random install identifier, which is not the advertising
identifier. When the payer uses Stripe's card form, Stripe's SDK also collects what Stripe documents
for its own fraud checks.

`WajubMobile` ships a privacy manifest, which Xcode includes in your app's privacy report. It
declares no tracking. Under **App Privacy** in App Store Connect, declare what the SDK sends next to
what your app collects on its own: linked to the user, not used for tracking, for App
Functionality, which covers processing the payment and preventing fraud.

| App Store Connect | What the SDK sends |
|---|---|
| Contact Info, Name | First and last name, or the card holder, when the payment method asks for them |
| Contact Info, Email Address | When the card payment asks for it |
| Contact Info, Phone Number | The Mobile Money number, or a phone number a card payment asks for |
| Contact Info, Physical Address | Address, city, ZIP code and country, when the card payment asks for them |
| Financial Info, Payment Info | The Mobile Money account, the Stripe card token, a card PIN when one is asked, and test cards in sandbox |
| Identifiers, Device ID | The random install identifier, for fraud prevention |
| Other Data | A date of birth when one is asked, and basic device information, for fraud prevention |

## Testing

A payment your server creates with a sandbox key puts the whole flow in sandbox, sheet included,
and the sheet shows a "Test mode" badge. Nothing changes in the app. The test numbers and cards are
on [Test scenarios](https://docs.wajub.com/developer-tools/testing/test-scenarios).

## Documentation & support

- iOS SDK docs: [docs.wajub.com/libraries/sdks/ios](https://docs.wajub.com/libraries/sdks/ios)
- Server SDKs (create payments): [docs.wajub.com/libraries/sdks](https://docs.wajub.com/libraries/sdks)

## License

MIT — see [LICENSE](LICENSE).
