# Wajub iOS SDK (Swift)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Native iOS checkout for [Wajub](https://wajub.com). It presents Mobile Money, card and wallet
payments in a SwiftUI sheet — **no WebView** for Wajub's own screens — and calls
`https://api.wajub.com/pay/*` with a payment session `authorization_token` created by your
[server SDK](https://docs.wajub.com/libraries/sdks).

It implements the shared Wajub mobile contract, spec v2 (the same states, callbacks, results,
appearance object and error codes as Wajub.js 1.8 and the Android, Flutter and React Native SDKs).

## Architecture

```
Your backend (server SDK, sk_…)
        │ authorization_token
        ▼
iOS app ── WajubCheckout.present(options) ──► SwiftUI sheet
        │
        ├─ GET /pay/session  ┐ in parallel
        ├─ GET /pay/sdk-config ┘
        ├─ POST /pay/process (Idempotency-Key, data._client)
        │     └─ action → native step screen / Safari / client session
        ├─ POST /pay/{otp,pin,phone,birthday,address}/verify
        └─ watch: Pusher/Reverb private-payment.{id} + GET /pay/status
        ▼
CheckoutResult (complete | processing | failed | cancelled) — confirm server-side
```

| Product | What |
|---|---|
| `WajubMobile` | Foundation only: models, lenient JSON, the API client (timeouts, retries, `Idempotency-Key`), errors, the Mobile Money tables and rules, Altcha, status watching (polling + a Pusher-protocol socket) and `CheckoutController`, the UI-agnostic state machine behind the sheet |
| `WajubMobileUI` | The SwiftUI sheet and its UIKit presenter: `WajubCheckout.present(_:from:)` |

## Requirements

| | |
|---|---|
| iOS | 15.0+ |
| Swift | 5.9+ (Xcode 15 or later) |
| Dependencies | none (Stripe is optional and lives in your app, see [Cards through Stripe](#cards-through-stripe)) |

`WajubMobileUI` presents from your app's windows (`UIApplication.shared`): use it in an app, not in an
app extension.

## Installation

Swift Package Manager — in Xcode, *File › Add Package Dependencies…* with
`https://github.com/wajubhq/wajub-ios`, or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/wajubhq/wajub-ios.git", from: "1.0.0"),
],
targets: [
    .target(name: "App", dependencies: [
        .product(name: "WajubMobileUI", package: "wajub-ios"),
    ]),
]
```

`WajubMobileUI` brings `WajubMobile` with it. Import `WajubMobile` alone to draw your own UI.

## Quick start

Create the payment on your server (`POST /payments` with your secret key) and hand its
`authorization_token` to the app. Then:

```swift
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
            // Paid. Confirm on your server (GET /payments/{id} or the payment.succeeded webhook) before delivering.
            await confirmOnServer(paymentId: payment.id)
        case .processing:
            // The payer left while a payment was running: your server learns the outcome from the webhook.
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

`present` resolves exactly once, when the sheet is gone, with the same value `onComplete` receives:
another `present` can follow at once.

## Options

`PresentOptions` (the contract's `PresentOptions`, with Swift names):

| Option | Default | |
|---|---|---|
| `sessionToken` | — | The payment's `authorization_token` |
| `locale` | the session's, else the device's | `"fr"` or `"en"`; anything else is English |
| `appearance` | `nil` | See [Appearance](#appearance) |
| `loader` | `.skeleton` | `.skeleton` (placeholder blocks, pulsing) or `.spinner` |
| `readyTimeout` | `15000` | Milliseconds before an unready sheet reports `ready_timeout` (with Retry); `0` disables it |
| `returnURL` | `nil` | An `https` universal link back into your app, sent as `return_url` to provider pages. Without it the payer comes back by hand |
| `mobileMoney` | | `MobileMoneyOptions(country:countryLocked:operatorMode:)`: start on a country (ISO-2), hide the country selector, `.choose` (the operator list, default) or `.detect` (the detected operator as a badge in the number field) |
| `realtime` | from the session | `RealtimeOptions(enabled:host:port:tls:)`: another Pusher-protocol host (self-hosted Reverb or Soketi) or `enabled: false` for polling only |
| `cancelOnDismiss` | `true` | Closing the sheet before any attempt cancels the payment (`POST /pay/cancel`). `false` keeps it open so you can present it again. A payment that may still move is never cancelled: not while loading, not when the session loaded `processing`, not once an attempt of the sheet is running or was seen `processing` — closing then resolves `processing` (or `cancelled` with no call) |
| `autoCloseSuccess` | `3000` | Milliseconds before the success screen closes itself; `0` keeps it |
| `callbacks` | | See below |
| `cardCollector` | `nil` | Needed for cards routed to Stripe |

### Callbacks

All optional, all called on the main thread, in this order: `onReady` → `onStateChange`… →
(`onPaymentStarted`, `onRedirect`) → `onSuccess` / `onError` / `onCancel` → `onComplete` (exactly
once). A callback that throws is caught and logged; the sheet carries on.

| Callback | Payload | When |
|---|---|---|
| `onReady` | `ReadyEvent` (`sessionId`, `environment`, `amount`, `currency`, `methods`) | The first screen is drawn (also for a payment that is already paid or ended) |
| `onStateChange` | `StateChangeEvent` (`state`, `method`) | After `onReady`, then on every state change |
| `onLoadError` | `WajubError` | The sheet cannot offer a payment: `session_not_found`, `session_terminal_expired`, `session_terminal_cancelled`, `session_terminal_failed`, `load_error`, `ready_timeout`, `no_payment_method` |
| `onPaymentStarted` | `PaymentStartedEvent` (`method`, `channel`) | The first `2xx` of an attempt: from now on a dismiss resolves `processing` |
| `onRedirect` | `RedirectEvent` (`url`) | Right before a provider page opens in Safari |
| `onSuccess` | `PaymentSuccess` | Paid (`method: "unknown"` when it was already paid at load) |
| `onError` | `WajubError` | A failure the payer sees (field validation excluded) |
| `onCancel` | `CancelEvent` (`reason`, `redirectURL`) | The sheet closes as `cancelled` |
| `onComplete` | `CheckoutResult` | The sheet closes |

### Results

| `CheckoutResult` | When |
|---|---|
| `.complete(payment:transaction:)` | The sheet closed after the success screen |
| `.processing(transaction:)` | The payer closed the sheet while an attempt was running, or the 15-minute watch ended: money may still move |
| `.failed(error:transaction:)` | The sheet closed on a failure, an expiry, a load error, or a payment cancelled elsewhere (`payment_cancelled`) |
| `.cancelled(reason:redirectURL:)` | "Cancel payment" (`.payerCancelled`), a dismiss before any attempt (`.dismissed`), or the presenting screen going away first (`.hostGone`) |

`PaymentSuccess` is Wajub.js's: `id` (Wajub's payment id), `reference` (yours), `amount` (what the
payer paid, fee included), `currency`, `method`, `status` (`"success"`), `timestamp`, `receiptURL`.

## States

`CheckoutController.state` and `onStateChange` use Wajub.js's 17 names:

| State | Screen |
|---|---|
| `INITIATED` | Method list |
| `COLLECTING_DETAILS` | A method's form (Mobile Money, card fields, wallet) |
| `PROCESSING` | The form, Pay busy |
| `APPROVAL_REQUIRED` | "Approve the payment on your phone", with the operator's instruction |
| `USSD_REQUIRED` | "Dial this code" |
| `OTP_REQUIRED`, `PIN_REQUIRED`, `PHONE_REQUIRED`, `BIRTHDAY_REQUIRED`, `ADDRESS_REQUIRED` | A card provider's confirmation step |
| `3DS_REQUIRED` | The sandbox 3-D Secure email code, or 3-D Secure in Safari |
| `VERIFYING` | A step being verified |
| `PENDING` | "Payment in progress" (with "Continue payment" when a provider page can be reopened) |
| `SUCCESS`, `FAILED`, `EXPIRED`, `CANCELLED` | Outcomes ("Try again" on a retryable failure) |

## Payment methods

| Channel | In the sheet |
|---|---|
| Mobile Money (operators and aggregates such as `cm.mobile`) | Country, number with its dial code (formatted as you type), operator picker with logos (or brand badges), detection of the operator from the number, mismatch check, E.164; then the approval screen |
| Card, client session (Paystack, Flutterwave, Adyen) | Contact fields the provider needs, then its page in Safari |
| Card, hosted page (CinetPay, Kkiapay, Mollie…) | The provider's `required_fields`, then its page in Safari |
| Card, Stripe | Your `CardCollector` (see below); hidden without one |
| Card, sandbox | The test-card form (sandbox only; card numbers never leave the device in live) |
| One-tap wallets (Djamo) | One tap; the wallet's page opens its app |

Provider pages open in `SFSafariViewController` (card pages, 3-D Secure, client sessions) or are
handed to iOS (`UIApplication.open`, wallet pages that open the wallet's app). When the payer comes
back — Safari closed, or the app back from the background — the sheet checks the payment at once.

A payment request that gets no answer it can decide on (no connection, a timeout, a server error) is
never shown as a failure: the
sheet shows "Payment in progress" and watches the payment. If 60 s after the last try the payment
still has not started (a refusal left by an earlier try does not count), the request most likely
never reached Wajub: the sheet goes back to the form with a connection error, and the next Pay sends
the same `Idempotency-Key`, so a request that did arrive is answered again instead of charged twice.

When the payment asks for an Altcha proof of work, each submission gets a fresh one (the session is
reloaded for a new challenge after each use); without one, nothing is sent and the sheet asks the
payer to try again.

Operator logos load from `https` URLs; one that is missing or does not load (iOS does not draw SVG
logos) is drawn as the operator's brand badge.

## Appearance

`PresentOptions.appearance` takes Wajub.js 1.8's appearance object, so your web Components and the
native sheet share one style:

```swift
options.appearance = Appearance(
    theme: .stripe,                          // presets: .stripe, .night, .flat, .none
    colorScheme: .auto,                      // .light, .dark, .auto (follows the phone, live)
    variables: AppearanceVariables(colorPrimary: "#0F766E", borderRadius: "12px", fontFamily: "Poppins"),
    buttonTextColor: "#FFFFFF")
```

- The same keys as Wajub.js: `theme`, `colorScheme`, `inherit`, `variables` (`colorPrimary`,
  `colorBackground`, `colorText`, `colorTextSecondary`, `colorTextPlaceholder`, `colorDanger`,
  `colorSuccess`, `fontFamily`, `fontSizeBase`, `fontWeightNormal`, `fontWeightMedium`,
  `fontWeightBold`, `spacingUnit`, `borderRadius`, `spacingGridRow`, `spacingGridColumn`) and the
  top-level keys (`primaryColor`, `backgroundColor`, `buttonTextColor`, `inputBackgroundColor`,
  `inputBorderColor`, `textMutedColor`, `secondaryColor`, `successColor`, `errorColor`, `shadow`,
  `labels`, `disableAnimations`). Colours are `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb()` or `rgba()`;
  lengths `"8px"`, `"8"` or `"0.5rem"`. Values that do not parse are ignored.
- Sharing the web object as JSON: `Appearance(json: try JSONValue.parse(jsonString))`.
- Precedence, per token: `variables` > top-level keys > the preset > your app's theme (`inherit: true`:
  the presenting screen's tint, background and text colours, kept only when they contrast enough) >
  the merchant's branding from the Wajub dashboard > Wajub's default palette.
- Colour scheme: `colorScheme`/`theme` > preset > inherited > the merchant's `appearance_mode` > auto.
- Merchant branding fills what you did not set: colours, radius, font (used only if your app ships
  it), logo and business name in the header; `white_label` hides "Secured by Wajub". A merchant
  primary colour with poor contrast falls back to the default.
- `disableAnimations: true`, or Reduce Motion, stops the skeleton's pulse and the cross-fades.

## Errors

Every failure is a `WajubError` (`Error`, `LocalizedError`) with Wajub.js's fields plus the mobile ones:

| Field | |
|---|---|
| `type` | `api_error`, `authentication_error`, `invalid_request_error`, `payment_error`, `rate_limit_error` |
| `code` | A code of the catalogue (`WajubError.Code`), or the API's own code passed through |
| `message` | For the payer, in the sheet's language (French or English) |
| `declineCode` | On a decline (`402`): the provider's code |
| `retryable` | Whether "Try again" can work |
| `param` | The field at fault |
| `httpStatus`, `correlationId` | The HTTP status and the response's `X-Request-Id`, for support |
| `retryAfterSeconds` | On `rate_limited` |
| `details` | The API's field errors |
| `blockReference` | On `shield_blocked` |
| `apiMessage` | The API's own (English) message, for your logs |

`toJSON()` gives the contract's snake_case shape. Notable codes: `insufficient_funds`,
`payment_declined`, `payment_attempt_ended` (nothing was charged, try again), `payment_failed`,
`shield_blocked`, `merchant_restricted`, `rate_limited`, `session_terminal_expired`,
`unsupported_action`, `redirect_unavailable`, `security_check_failed`.

## Cards through Stripe

When the card channel is routed to Stripe, a Stripe `pm_…` must be created by Stripe's own SDK.
WajubMobile does not depend on `stripe-ios`: implement `CardCollector` in your app, and the sheet
offers "Pay by card" and sends the `pm_…` it returns. Without a collector a Stripe-routed card
channel is not offered (Mobile Money and the other methods still are).

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

Return `nil` when the payer backs out. A thrown error is shown on the card form.

## Your own UI

- `WajubSession` is the low-level client: `session()`, `sdkConfig()`, `status()`,
  `process(channel:data:idempotencyKey:)`, `startClientSession(…)`, `completeClientSession(id:)`,
  `cancel()`, `verify(_:id:fields:)`, `resend(_:id:)`, `send3DSCode(threeDSId:)`,
  `verify3DSCode(threeDSId:code:)`, `broadcastingAuth(socketId:channelName:)`. It sends the
  contract's headers, device signals, timeouts, retries and `Idempotency-Key`, and returns the API's
  shapes and `ProcessOutcome`.
- `CheckoutController` is the sheet's state machine without any UI: create it with
  `CheckoutController(options:browser:)` (a `BrowserOpening` of yours, whose `onClose` you call when
  an in-app browser closes), draw its `screen`, call its
  actions (`selectMethod`, `setPhone`, `pickOperator`, `submitMobileMoney`, `submitCard`,
  `payWallet`, `submitStep`, `submitThreeDSCode`, `tryAgain`, `cancelPayment`, `dismiss`,
  `appWillEnterForeground`, `hostGone`…), and present it with
  `Checkout.present(_:presenter:browser:)` and your own `CheckoutPresenting` (call `dismiss`'s
  `completion` once the sheet is gone). Both callbacks are `@MainActor @Sendable`, so they can go
  into system completion handlers in a Swift 6 app.
- `MobileMoneyData.shared` exposes the Mobile Money rules (national digits, validation, operator
  detection, E.164, formatting).

## Development

```bash
swift test
```

The repository is a Swift package. The core and its tests (the contract tests of
`conformance.md`, named `test_PR_01_…` with the requirement id in a `/// PR-01 …` line above each,
running against the contract's real API fixtures) build on macOS and on Linux. The sheet
(`WajubMobileUI`) needs the iOS SDK: its sources are wrapped in `#if os(iOS)` and compile to an empty
module elsewhere.

- On a Mac with Xcode: `swift test`, then
  `xcodebuild -scheme WajubMobile-Package -destination 'generic/platform=iOS Simulator' build` to
  compile the sheet.
- On Linux, in the Swift container:
  `podman run --rm -v "$PWD":/src:Z -w /src docker.io/library/swift:6.1 swift test`
  (`docker run` works the same). Only the core is compiled and tested there: SwiftUI and UIKit do
  not exist on Linux, so the sheet is compiled by the macOS job of CI.
- `.github/workflows/ci.yml` runs both: a macOS job (`swift test` and the iOS Simulator build) and a
  Linux job (`swift test` in `swift:6.1`, the core in Swift 6 language mode, and `ci/swift6-host`, a
  small Swift 6 package that implements the SDK's protocols the way an app does).
- Timeouts (connect 10 s, then 30 s or 60 s for the whole call) are measured on the SDK's own clock,
  so the tests check them on a virtual clock. `URLSession` reports no connection event: a request
  with a body counts as connected once its body starts flowing; a request without one (the reads,
  `/pay/cancel`) cannot be told apart from a slow answer, so only its whole-call timeout applies.
- `Tests/WajubMobileTests/Fixtures` and `Sources/WajubMobile/Resources/mobile-money.json` are copies
  of the shared contract, written by `sync-spec.sh ios` in the mobile SDKs' monorepo; never edit
  them by hand (`test_SY_01_usesTheSyncedSpecFiles` checks their checksums). Test fixtures are a
  test-target resource and are not shipped; the Mobile Money data file is a resource of
  `WajubMobile` and is.

## Documentation & support

- Mobile SDK docs: [docs.wajub.com/libraries/sdks/mobile](https://docs.wajub.com/libraries/sdks/mobile)
- Server SDKs (create payments): [docs.wajub.com/libraries/sdks](https://docs.wajub.com/libraries/sdks)

## License

MIT — see [LICENSE](LICENSE).
